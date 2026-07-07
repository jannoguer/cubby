#!/usr/bin/env pwsh
<#
.SYNOPSIS
Checks a Mutagen sync session once and maintains a .cubby/conflicts.json in
the synced folder. Schedule it with cron or Task Scheduler.

.DESCRIPTION
Writes the raw conflict array reported by Mutagen (root path plus the
alpha/beta changes with their entry metadata) as conflicts.json in the
.cubby subdirectory of the session's local (mapped) directory. The file is
staged and swapped into place, so consumers never see a partial file.

When the session reports no conflicts, conflicts.json is removed if present.
When the daemon or session cannot be queried, the file is left untouched
since the current conflict state is unknown.

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
pwsh -NoProfile -File watch-conflicts.ps1 cubby

.NOTES
Exit codes: 0 = session queried and conflicts.json updated (or removed);
1 = anything else (the file is left untouched).

Scheduling examples:
  cron:           * * * * * pwsh -NoProfile -File /path/to/watch-conflicts.ps1 cubby
  Task Scheduler: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\watch-conflicts.ps1 cubby
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

$MutagenCli = Resolve-MutagenCli
if ($null -eq $MutagenCli) {
    Write-Warning 'mutagen was not found on PATH or in a per-user install location.'
    exit 1
}

$now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Overlapping scheduled runs would contend for the same staging file. exit
# inside try still runs the finally block, so the mutex is always released;
# the AbandonedMutexException catch covers holders that were hard-killed.
$mutex = New-Object System.Threading.Mutex($false, "cubby-watch-conflicts-$(Get-SessionSlug)")
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

    $result = Get-SessionState

    if (-not $result.Ok) {
        Write-Warning "[$now] $($result.Error)"
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

    $conflicts = @($session.conflicts | Where-Object { $null -ne $_ })
    $markerDir = Join-Path $dir '.cubby'
    $path = Join-Path $markerDir 'conflicts.json'

    if ($conflicts.Count -eq 0) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    else {
        # Mutagen caps the number of conflicts it reports per session.
        if ($session.excludedConflicts -gt 0) {
            Write-Warning "[$now] $($session.excludedConflicts) additional conflicts were not reported by mutagen"
        }
        if (-not (Test-Path -LiteralPath $markerDir)) {
            New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        }
        $stage = Join-Path $markerDir 'conflicts.json.tmp'
        $json = ConvertTo-Json -InputObject $conflicts -Depth 32
        try {
            [System.IO.File]::WriteAllText($stage, $json + "`n")
            Move-IntoPlace -Stage $stage -Destination $path
        }
        catch {
            if (Test-Path -LiteralPath $stage) {
                Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
            }
            Write-Warning "[$now] failed to update conflicts.json: $($_.Exception.Message)"
            exit 1
        }
    }

    Write-Host "[$now] conflicts=$($conflicts.Count)"
    exit 0
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
