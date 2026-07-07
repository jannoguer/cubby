#!/usr/bin/env pwsh
<#
.SYNOPSIS
Checks a Mutagen sync session once and drops a health marker into the synced
folder. Schedule it with cron or Task Scheduler.

.DESCRIPTION
Writes a health marker (status.ok or status.err) into the .cubby
subdirectory of the session's local (mapped) directory. The marker is
staged and swapped into place so consumers never see a partial file;
exactly one marker exists after each run. A session is healthy when it is
not paused, reports no error, both endpoints are connected, and its status
is a normal syncing state.

The mapped directory is cached after each successful query so status.err
can still be written when the daemon is unreachable.

.cubby is a reserved directory name in the sync root: the script owns its
contents and overwrites them. Create the sync session with --ignore=/.cubby
(see the project README) so the markers do not propagate to other replicas.

Works on Windows PowerShell 5.1 and PowerShell 7+ (macOS/Linux: run with
pwsh). Uses the mutagen CLI from PATH, falling back to per-user install
locations for scheduled runs under a service account.

.PARAMETER SessionName
Name (or identifier) of the Mutagen sync session.

.PARAMETER TimeoutSeconds
Maximum time to wait for the Mutagen daemon to answer. Defaults to 30.

.EXAMPLE
pwsh -NoProfile -File watch-status.ps1 cubby

.NOTES
Exit codes: 0 = session queried and marker written; 1 = anything else
(status.err is still written when the synced directory is known from a
previous successful run).

Scheduling examples:
  cron:           * * * * * pwsh -NoProfile -File /path/to/watch-status.ps1 cubby
  Task Scheduler: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\watch-status.ps1 cubby
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SessionName,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

# Normal syncing statuses (mutagen 0.18 API model strings); anything else
# (disconnected, connecting-*, halted-*, ...) is an error condition.
$OkStatuses = @(
    'watching', 'scanning', 'waiting-for-rescan', 'reconciling',
    'staging-alpha', 'staging-beta', 'transitioning', 'saving'
)

# Mutex/file-safe identifier; the hash suffix keeps names distinct when they
# differ only in stripped characters ("a/b" vs "a_b").
function Get-SessionSlug {
    $safe = $SessionName -replace '[^\w.-]', '_'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SessionName))
    }
    finally {
        $sha.Dispose()
    }
    return "$safe-$(([System.BitConverter]::ToString($bytes, 0, 4) -replace '-', '').ToLower())"
}

# Remembers the mapped directory between runs so status.err can still be
# written when the daemon is unreachable.
function Get-CachePath {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrEmpty($base)) { $base = [System.IO.Path]::GetTempPath() }
    $cacheDir = Join-Path $base 'mutagen-watch'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    return Join-Path $cacheDir "$(Get-SessionSlug).dir"
}

# Service accounts (e.g. LocalSystem) lack per-user PATH entries, so when
# the PATH lookup fails, probe each profile's install locations (official
# installer and scoop). The fallback also returns that profile's .mutagen
# data directory; without it the CLI would talk to the service account's
# own (empty) daemon.
function Resolve-MutagenCli {
    $cmd = Get-Command mutagen -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return @{ Path = $cmd.Source; DataDir = $null }
    }
    $usersRoot = Join-Path "$env:SystemDrive\" 'Users'
    if (Test-Path -LiteralPath $usersRoot) {
        foreach ($userDir in Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($rel in @('AppData\Local\Programs\mutagen\mutagen.exe', 'scoop\shims\mutagen.exe')) {
                $exe = Join-Path $userDir.FullName $rel
                if (Test-Path -LiteralPath $exe) {
                    return @{ Path = $exe; DataDir = Join-Path $userDir.FullName '.mutagen' }
                }
            }
        }
    }
    return $null
}

# Queries the session in a background job so a wedged daemon cannot hang the
# probe. Returns @{ Ok = $true; Session = ... } or @{ Ok = $false; Error = ... }.
function Get-SessionState {
    $job = Start-Job -ScriptBlock {
        param($Name, $Exe, $DataDir)
        # Do not override an explicitly configured data directory.
        if ($DataDir -and -not $env:MUTAGEN_DATA_DIRECTORY) {
            $env:MUTAGEN_DATA_DIRECTORY = $DataDir
        }
        # Stderr is collected separately: a warning printed alongside a
        # successful listing must not corrupt the JSON on stdout.
        $stdout = @(); $stderr = @()
        & $Exe sync list --template '{{ json . }}' $Name 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr += "$_" }
            else { $stdout += "$_" }
        }
        [pscustomobject]@{
            Lines    = $stdout
            ErrLines = $stderr
            ExitCode = $LASTEXITCODE
        }
    } -ArgumentList $SessionName, $MutagenCli.Path, $MutagenCli.DataDir

    try {
        if ($null -eq (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            return @{ Ok = $false; Error = "mutagen did not answer within $TimeoutSeconds seconds" }
        }
        $completed = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    if ($null -eq $completed) {
        $detail = if ($jobErrors) { (@($jobErrors) | ForEach-Object { "$_" }) -join '; ' } else { 'no output' }
        return @{ Ok = $false; Error = "failed to run mutagen: $detail" }
    }

    $text = (@($completed.Lines) | ForEach-Object { "$_" }) -join "`n"
    $errText = (@($completed.ErrLines) | ForEach-Object { "$_" }) -join '; '
    if ($completed.ExitCode -ne 0) {
        $detail = (@($errText, $text) | Where-Object { $_ }) -join ' | '
        return @{ Ok = $false; Error = "mutagen exited with code $($completed.ExitCode): $detail" }
    }

    try {
        $sessions = @($text | ConvertFrom-Json)
    }
    catch {
        return @{ Ok = $false; Error = "could not parse mutagen output as JSON: $text" }
    }
    if ($sessions.Count -ne 1) {
        return @{ Ok = $false; Error = "'$SessionName' matched $($sessions.Count) sessions, expected exactly 1" }
    }
    return @{ Ok = $true; Session = $sessions[0] }
}

# The mapped directory is the endpoint that lives on this machine.
function Resolve-MappedDir($Session) {
    foreach ($endpoint in @($Session.alpha, $Session.beta)) {
        if ($null -ne $endpoint -and $endpoint.protocol -eq 'local' -and $endpoint.path) {
            return $endpoint.path
        }
    }
    return $null
}

# Marker format is one key=value pair per line; embedded newlines in a value
# would inject lines that parse as other keys.
function ConvertTo-SingleLine([string]$Text) {
    return ($Text -replace "\r?\n", ' ')
}

# Renames the staged file onto the destination. File.Replace swaps in place
# when the destination exists, so consumers never observe it missing.
# Transient locks (a reader or scanner holding the destination open without
# share-delete) fail both Replace and Move-Item, so retry briefly.
function Move-IntoPlace([string]$Stage, [string]$Destination) {
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            if (Test-Path -LiteralPath $Destination) {
                try {
                    # NullString: PowerShell would coerce $null to "" for the
                    # [string] backup parameter, which File.Replace rejects.
                    [System.IO.File]::Replace($Stage, $Destination, [NullString]::Value)
                    return
                }
                catch [System.PlatformNotSupportedException] {
                    # Filesystem without replace support; fall through to Move-Item.
                }
                catch [System.IO.IOException] {
                    # Destination busy; Move-Item below decides, retried on failure.
                }
            }
            Move-Item -LiteralPath $Stage -Destination $Destination -Force
            return
        }
        catch [System.IO.IOException] {
            if ($i -eq $attempts) { throw }
            Start-Sleep -Milliseconds 150
        }
    }
}

# Stages the content, swaps it onto status.ok or status.err, and only then
# removes the opposite marker, so at least one marker exists at all times.
function Write-StatusMarker([string]$Dir, [bool]$Healthy, [string]$Content) {
    $markerDir = Join-Path $Dir '.cubby'
    if (-not (Test-Path -LiteralPath $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }
    $stage = Join-Path $markerDir 'status'
    $ok = Join-Path $markerDir 'status.ok'
    $err = Join-Path $markerDir 'status.err'
    if ($Healthy) { $target = $ok; $stale = $err } else { $target = $err; $stale = $ok }

    try {
        [System.IO.File]::WriteAllText($stage, $Content + "`n")
        Move-IntoPlace -Stage $stage -Destination $target
    }
    catch {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    if (Test-Path -LiteralPath $stale) {
        Remove-Item -LiteralPath $stale -Force
    }
}

$MutagenCli = Resolve-MutagenCli
if ($null -eq $MutagenCli) {
    Write-Warning 'mutagen was not found on PATH or in a per-user install location.'
    exit 1
}

$now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Overlapping scheduled runs would contend for the same staging file. exit
# inside try still runs the finally block, so the mutex is always released;
# the AbandonedMutexException catch covers holders that were hard-killed.
$mutex = New-Object System.Threading.Mutex($false, "cubby-watch-status-$(Get-SessionSlug)")
$acquired = $false
try {
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # A previous holder died without releasing; the mutex is ours now.
        $acquired = $true
    }
    if (-not $acquired) {
        Write-Warning "[$now] another instance is already running for '$SessionName'"
        exit 1
    }

    $cachePath = Get-CachePath
    $result = Get-SessionState

    if (-not $result.Ok) {
        # Daemon or session unreachable: fall back to the cached directory.
        Write-Warning "[$now] $($result.Error)"
        $dir = $null
        if (Test-Path -LiteralPath $cachePath) {
            $dir = ([System.IO.File]::ReadAllText($cachePath)).Trim()
        }
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $content = @(
                "checkedAt=$now"
                "session=$(ConvertTo-SingleLine $SessionName)"
                "healthy=false"
                "status=unknown"
                "lastError=$(ConvertTo-SingleLine $result.Error)"
            ) -join "`n"
            Write-StatusMarker -Dir $dir -Healthy $false -Content $content
            Write-Host "[$now] status.err written to $dir"
        }
        else {
            Write-Warning "[$now] synced directory unknown; no marker written"
        }
        exit 1
    }

    $session = $result.Session
    $dir = Resolve-MappedDir $session
    if ($null -eq $dir) {
        Write-Warning "[$now] session '$SessionName' has no local endpoint; nothing to write"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Warning "[$now] mapped directory '$dir' does not exist"
        exit 1
    }
    # The cache is best-effort; a failed update must not block the marker write.
    try {
        [System.IO.File]::WriteAllText($cachePath, $dir)
    }
    catch {
        Write-Warning "[$now] could not update cache '$cachePath': $($_.Exception.Message)"
    }

    $status = "$($session.status)"
    $lastError = ConvertTo-SingleLine "$($session.lastError)"
    $paused = ($session.paused -eq $true)
    $alphaConnected = ($session.alpha.connected -eq $true)
    $betaConnected = ($session.beta.connected -eq $true)
    $conflictCount = @($session.conflicts | Where-Object { $null -ne $_ }).Count

    $healthy = ($OkStatuses -contains $status) -and
    (-not $paused) -and
    ($lastError -eq '') -and
    $alphaConnected -and
    $betaConnected

    $content = @(
        "checkedAt=$now"
        "session=$(ConvertTo-SingleLine $SessionName)"
        "healthy=$(if ($healthy) { 'true' } else { 'false' })"
        "status=$status"
        "paused=$(if ($paused) { 'true' } else { 'false' })"
        "alphaConnected=$(if ($alphaConnected) { 'true' } else { 'false' })"
        "betaConnected=$(if ($betaConnected) { 'true' } else { 'false' })"
        "conflicts=$conflictCount"
        "lastError=$lastError"
    ) -join "`n"

    Write-StatusMarker -Dir $dir -Healthy $healthy -Content $content
    Write-Host "[$now] $(if ($healthy) { 'status.ok' } else { 'status.err' }) status=$status"
    exit 0
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
