#!/usr/bin/env pwsh
<#
.SYNOPSIS
Checks a Mutagen sync session once and writes health markers into .cubby/local
under the session's local directory. Schedule it with cron or Task Scheduler.

.DESCRIPTION
Markers, each staged and swapped in so consumers never see a partial file:
  status.ok | status.err  sync health as key=value lines; exactly one exists
                          after each run. Healthy means: not paused, no error,
                          both endpoints connected, status is a normal syncing
                          state.
  conflicts.json          Mutagen's raw conflict array. Removed when there are
                          none; left untouched when the session cannot be
                          queried, since the state is unknown.

The status marker also summarizes the server's backup marker (.cubby/
backup_status.ok or .err, synced from the server): backupStatus=
ok|stale|failed|unknown, backupCount, backupLast, backupLastResult and
backupUpdatedAt. Stale means older than twice the backup interval. Backups
never change healthy=.

The local directory is cached so status.err can still be written when the
daemon is unreachable.

The markers stay on this device: create the session with --ignore=/.cubby/local.
The script reads the session's ignore list and writes nothing when that path is
not ignored, so a forgotten flag cannot leak markers into the sync.

Windows PowerShell 5.1 and PowerShell 7+ (macOS/Linux: pwsh). Self-contained.

.PARAMETER SessionName
Name (or identifier) of the Mutagen sync session.

.PARAMETER TimeoutSeconds
Maximum time to wait for the Mutagen daemon. Defaults to 30.

.PARAMETER MutagenPath
Path to the mutagen executable when PATH lacks it (scheduled runs under a
service account). Also settable as CUBBY_MUTAGEN_PATH. Such an account has its
own empty daemon: point the CLI at the right one with MUTAGEN_DATA_DIRECTORY,
or CUBBY_MUTAGEN_DATA_DIR where the scheduler cannot set it.

.EXAMPLE
pwsh -NoProfile -File watch.ps1 Cubby

.NOTES
Exit codes: 0 = markers written; 1 = anything else (status.err is still written
when the directory is known from a previous run).

Scheduling:
  cron:           * * * * * pwsh -NoProfile -File /path/to/.cubby/client/watch.ps1 Cubby
  Task Scheduler: wscript.exe C:\path\to\.cubby\client\run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\.cubby\client\watch.ps1 Cubby
run-hidden.vbs keeps Task Scheduler from flashing a console window on every run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SessionName,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 30,

    [Parameter()]
    [string]$MutagenPath
)

$ErrorActionPreference = 'Stop'

# Mutagen 0.18 status strings; anything else counts as unhealthy.
$OkStatuses = @(
    'watching', 'scanning', 'waiting-for-rescan', 'reconciling',
    'staging-alpha', 'staging-beta', 'transitioning', 'saving'
)

# Hash suffix: "a/b" and "a_b" would otherwise collapse onto one slug.
function Get-SessionSlug([string]$Name) {
    $safe = $Name -replace '[^\w.-]', '_'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Name))
    }
    finally {
        $sha.Dispose()
    }
    return "$safe-$(([System.BitConverter]::ToString($bytes, 0, 4) -replace '-', '').ToLower())"
}

# Never located by scanning C:\Users: any local user can plant a binary in a
# profile they own (C:\Users\Public needs no privileges) and it would run with
# the scheduled task's rights. CUBBY_MUTAGEN_DATA_DIR exists for schedulers
# that cannot set Mutagen's own MUTAGEN_DATA_DIRECTORY.
function Resolve-MutagenCli {
    param([string]$MutagenPath)

    $dataDir = $env:CUBBY_MUTAGEN_DATA_DIR
    if ([string]::IsNullOrWhiteSpace($dataDir)) { $dataDir = $null }

    if ([string]::IsNullOrWhiteSpace($MutagenPath)) { $MutagenPath = $env:CUBBY_MUTAGEN_PATH }

    if (-not [string]::IsNullOrWhiteSpace($MutagenPath)) {
        if (-not (Test-Path -LiteralPath $MutagenPath -PathType Leaf)) {
            Write-Warning "mutagen was not found at '$MutagenPath'."
            return $null
        }
        return @{ Path = (Resolve-Path -LiteralPath $MutagenPath).ProviderPath; DataDir = $dataDir }
    }

    $cmd = Get-Command mutagen -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return @{ Path = $cmd.Source; DataDir = $dataDir }
    }
    return $null
}

# Runs in a background job so a wedged daemon cannot hang the probe.
function Get-SessionState {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][hashtable]$MutagenCli
    )
    # Windows PowerShell 5.1 cannot dereference members through $using:.
    $exe = $MutagenCli.Path
    $dataDir = $MutagenCli.DataDir
    $job = Start-Job -ScriptBlock {
        $exe = $using:exe
        $dataDir = $using:dataDir
        $name = $using:SessionName
        if ($dataDir -and -not $env:MUTAGEN_DATA_DIRECTORY) {
            $env:MUTAGEN_DATA_DIRECTORY = $dataDir
        }
        # A warning on stderr must not corrupt the JSON on stdout.
        $stdout = @(); $stderr = @()
        & $exe sync list --template '{{ json . }}' $name 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr += "$_" }
            else { $stdout += "$_" }
        }
        [pscustomobject]@{
            Lines    = $stdout
            ErrLines = $stderr
            ExitCode = $LASTEXITCODE
        }
    }

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
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        return @{ Ok = $false; Error = "could not parse mutagen output as JSON: $text" }
    }
    # Windows PowerShell 5.1 emits a JSON array as one object; @() alone would nest it.
    $sessions = @($parsed | Where-Object { $null -ne $_ })
    if ($sessions.Count -ne 1) {
        return @{ Ok = $false; Error = "'$SessionName' matched $($sessions.Count) sessions, expected exactly 1" }
    }
    return @{ Ok = $true; Session = $sessions[0] }
}

function Resolve-MappedDir($Session) {
    foreach ($endpoint in @($Session.alpha, $Session.beta)) {
        if ($null -ne $endpoint -and $endpoint.protocol -eq 'local' -and $endpoint.path) {
            return $endpoint.path
        }
    }
    return $null
}

# File.Replace swaps in place so the destination is never missing; a reader
# holding it open fails either call, hence the retry.
function Move-IntoPlace([string]$Stage, [string]$Destination) {
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            if (Test-Path -LiteralPath $Destination) {
                try {
                    # PowerShell would coerce $null to "", which File.Replace rejects.
                    [System.IO.File]::Replace($Stage, $Destination, [NullString]::Value)
                    return
                }
                catch [System.PlatformNotSupportedException], [System.IO.IOException] {
                    Write-Verbose "File.Replace failed ($($_.Exception.GetType().Name)); falling back to Move-Item"
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

function Get-CachePath {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrEmpty($base)) { $base = [System.IO.Path]::GetTempPath() }
    $cacheDir = Join-Path $base 'cubby-watch'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    return Join-Path $cacheDir "$(Get-SessionSlug $SessionName).dir"
}

# A newline inside a value would inject extra key=value lines.
function ConvertTo-SingleLine([string]$Text) {
    return ($Text -replace "\r?\n", ' ')
}

# Reads the server's marker; .err wins over .ok, and a missing or malformed
# marker is unknown rather than an error of this probe.
function Get-BackupSummary([string]$Dir) {
    $summary = @{ Status = 'unknown'; Count = ''; Last = ''; LastResult = ''; UpdatedAt = '' }
    $markerDir = Join-Path $Dir '.cubby'
    $err = Join-Path $markerDir 'backup_status.err'
    $ok = Join-Path $markerDir 'backup_status.ok'
    if (Test-Path -LiteralPath $err) { $file = $err; $summary.Status = 'failed' }
    elseif (Test-Path -LiteralPath $ok) { $file = $ok; $summary.Status = 'ok' }
    else { return $summary }

    $fields = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $fields[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    $summary.Count = "$($fields['snapshots'])"
    $summary.Last = "$($fields['lastSnapshot'])"
    $summary.LastResult = "$($fields['lastResult'])"
    $summary.UpdatedAt = "$($fields['updatedAt'])"
    if ($summary.Status -ne 'ok') { return $summary }

    $updated = [DateTime]::MinValue
    $interval = 0
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParseExact($summary.UpdatedAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture, $styles, [ref]$updated) -or
        -not [int]::TryParse("$($fields['interval'])", [ref]$interval)) {
        $summary.Status = 'unknown'
        return $summary
    }
    # Same rule as the server healthcheck: one interval would flap on a slow rsync.
    if (([DateTime]::UtcNow - $updated).TotalSeconds -gt 2 * $interval) {
        $summary.Status = 'stale'
    }
    return $summary
}

function Get-MarkerDir([string]$Dir) {
    return Join-Path (Join-Path $Dir '.cubby') 'local'
}

# Without the ignore, every device would sync its markers into the same files.
function Test-MarkersIgnored($Session) {
    # Session-wide list plus the per-endpoint overrides.
    $ignores = @(
        @($Session.ignore.paths) + @($Session.alpha.ignore.paths) + @($Session.beta.ignore.paths) |
            Where-Object { $null -ne $_ } | ForEach-Object { "$_" -replace '/$', '' }
    )
    return ($ignores -contains '/.cubby/local') -or ($ignores -contains '.cubby/local')
}

function Format-BackupSummary([hashtable]$Backup) {
    return @(
        "backupStatus=$($Backup.Status)"
        "backupCount=$($Backup.Count)"
        "backupLast=$($Backup.Last)"
        "backupLastResult=$($Backup.LastResult)"
        "backupUpdatedAt=$($Backup.UpdatedAt)"
    )
}

# The stale marker goes last, so at least one marker exists at all times.
function Write-StatusMarker([string]$Dir, [bool]$Healthy, [string[]]$Lines) {
    $markerDir = Get-MarkerDir $Dir
    if (-not (Test-Path -LiteralPath $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }
    $stage = Join-Path $markerDir '.status.tmp'
    $ok = Join-Path $markerDir 'status.ok'
    $err = Join-Path $markerDir 'status.err'
    if ($Healthy) { $target = $ok; $stale = $err } else { $target = $err; $stale = $ok }

    try {
        [System.IO.File]::WriteAllText($stage, ($Lines -join "`n") + "`n")
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

# Removed when there are no conflicts, so its presence alone is the signal.
function Write-ConflictsMarker([string]$Dir, [object[]]$Conflicts, $Session) {
    $markerDir = Get-MarkerDir $Dir
    $path = Join-Path $markerDir 'conflicts.json'
    if ($Conflicts.Count -eq 0) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
        return
    }
    # Mutagen caps the number of conflicts it reports per session.
    if ($Session.excludedConflicts -gt 0) {
        Write-Warning "[$now] $($Session.excludedConflicts) additional conflicts were not reported by mutagen"
    }
    if (-not (Test-Path -LiteralPath $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }
    $stage = Join-Path $markerDir 'conflicts.json.tmp'
    $json = ConvertTo-Json -InputObject $Conflicts -Depth 32
    try {
        [System.IO.File]::WriteAllText($stage, $json + "`n")
        Move-IntoPlace -Stage $stage -Destination $path
    }
    catch {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

$MutagenCli = Resolve-MutagenCli -MutagenPath $MutagenPath
if ($null -eq $MutagenCli) {
    Write-Warning 'mutagen was not found on PATH; pass -MutagenPath or set CUBBY_MUTAGEN_PATH.'
    exit 1
}

$now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Overlapping scheduled runs would contend for the same staging file. Global\
# spans logon sessions, so an interactive run and a scheduled one exclude each other.
$mutex = New-Object System.Threading.Mutex($false, "Global\cubby-watch-$(Get-SessionSlug $SessionName)")
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
    $result = Get-SessionState -SessionName $SessionName -TimeoutSeconds $TimeoutSeconds -MutagenCli $MutagenCli

    if (-not $result.Ok) {
        Write-Warning "[$now] $($result.Error)"
        $dir = $null
        if (Test-Path -LiteralPath $cachePath) {
            $dir = ([System.IO.File]::ReadAllText($cachePath)).Trim()
        }
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $backup = Get-BackupSummary $dir
            $lines = @(
                "checkedAt=$now"
                "session=$(ConvertTo-SingleLine $SessionName)"
                "healthy=false"
                "status=unknown"
                "lastError=$(ConvertTo-SingleLine $result.Error)"
            ) + (Format-BackupSummary $backup)
            Write-StatusMarker -Dir $dir -Healthy $false -Lines $lines
            Write-Output "[$now] status.err written to $dir backups=$($backup.Status)"
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
    if (-not (Test-MarkersIgnored $session)) {
        Write-Warning "[$now] session '$SessionName' does not ignore /.cubby/local; recreate it with --ignore=/.cubby/local. No marker written."
        exit 1
    }
    # Only verified sessions are cached, so the daemon-down path stays safe too.
    # A failed cache update must not block the marker write.
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
    $conflicts = @($session.conflicts | Where-Object { $null -ne $_ })

    $healthy = ($OkStatuses -contains $status) -and
    (-not $paused) -and
    ($lastError -eq '') -and
    $alphaConnected -and
    $betaConnected

    $backup = Get-BackupSummary $dir
    $lines = @(
        "checkedAt=$now"
        "session=$(ConvertTo-SingleLine $SessionName)"
        "healthy=$(if ($healthy) { 'true' } else { 'false' })"
        "status=$status"
        "paused=$(if ($paused) { 'true' } else { 'false' })"
        "alphaConnected=$(if ($alphaConnected) { 'true' } else { 'false' })"
        "betaConnected=$(if ($betaConnected) { 'true' } else { 'false' })"
        "conflicts=$($conflicts.Count)"
        "lastError=$lastError"
    ) + (Format-BackupSummary $backup)
    Write-StatusMarker -Dir $dir -Healthy $healthy -Lines $lines

    try {
        Write-ConflictsMarker -Dir $dir -Conflicts $conflicts -Session $session
    }
    catch {
        Write-Warning "[$now] failed to update conflicts.json: $($_.Exception.Message)"
        exit 1
    }

    $marker = if ($healthy) { 'status.ok' } else { 'status.err' }
    Write-Output "[$now] $marker status=$status conflicts=$($conflicts.Count) backups=$($backup.Status) count=$($backup.Count) last=$($backup.Last)"
    exit 0
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
