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
pwsh). Uses the mutagen CLI from PATH. Requires watch-common.ps1 in the same
directory.

.PARAMETER SessionName
Name (or identifier) of the Mutagen sync session.

.PARAMETER TimeoutSeconds
Maximum time to wait for the Mutagen daemon to answer. Defaults to 30.

.PARAMETER MutagenPath
Full path to the mutagen executable, for scheduled runs under a service
account whose PATH does not include it. Also settable as CUBBY_MUTAGEN_PATH.
Such an account has its own empty daemon, so point the CLI at the right one
with MUTAGEN_DATA_DIRECTORY, or CUBBY_MUTAGEN_DATA_DIR where the scheduler
cannot set mutagen's own variable (e.g. C:\Users\you\.mutagen).

.EXAMPLE
pwsh -NoProfile -File watch-status.ps1 Cubby

.NOTES
Exit codes: 0 = session queried and marker written; 1 = anything else
(status.err is still written when the synced directory is known from a
previous successful run).

Scheduling examples:
  cron:           * * * * * pwsh -NoProfile -File /path/to/watch-status.ps1 Cubby
  Task Scheduler: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\watch-status.ps1 Cubby

On Windows, prefer wrapping the command with run-hidden.vbs (same folder):
  wscript.exe C:\path\to\run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\watch-status.ps1 Cubby
powershell.exe is a console application, so Task Scheduler flashes a console
window on every run during an interactive logon; run-hidden.vbs runs under
wscript (a GUI-subsystem host), executes the command with no visible window,
and forwards its exit code.
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

. (Join-Path $PSScriptRoot 'watch-common.ps1')

# Mutagen 0.18 API model strings; anything else (disconnected, connecting-*,
# halted-*, ...) counts as an error condition.
$OkStatuses = @(
    'watching', 'scanning', 'waiting-for-rescan', 'reconciling',
    'staging-alpha', 'staging-beta', 'transitioning', 'saving'
)

# Remembers the mapped directory so status.err can still be written when the
# daemon is unreachable and cannot report it.
function Get-CachePath {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrEmpty($base)) { $base = [System.IO.Path]::GetTempPath() }
    $cacheDir = Join-Path $base 'cubby-watch'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    return Join-Path $cacheDir "$(Get-SessionSlug $SessionName).dir"
}

# The marker is one key=value per line, so a newline inside a value would
# inject lines that parse as other keys.
function ConvertTo-SingleLine([string]$Text) {
    return ($Text -replace "\r?\n", ' ')
}

# The stale marker goes last, so at least one marker exists at all times.
function Write-StatusMarker([string]$Dir, [bool]$Healthy, [string]$Content) {
    $markerDir = Join-Path $Dir '.cubby'
    if (-not (Test-Path -LiteralPath $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }
    $stage = Join-Path $markerDir '.status.tmp'
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

$MutagenCli = Resolve-MutagenCli -MutagenPath $MutagenPath
if ($null -eq $MutagenCli) {
    Write-Warning 'mutagen was not found on PATH; pass -MutagenPath or set CUBBY_MUTAGEN_PATH.'
    exit 1
}

$now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Overlapping scheduled runs would contend for the same staging file.
$mutex = New-Object System.Threading.Mutex($false, "cubby-watch-status-$(Get-SessionSlug $SessionName)")
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
            $content = @(
                "checkedAt=$now"
                "session=$(ConvertTo-SingleLine $SessionName)"
                "healthy=false"
                "status=unknown"
                "lastError=$(ConvertTo-SingleLine $result.Error)"
            ) -join "`n"
            Write-StatusMarker -Dir $dir -Healthy $false -Content $content
            Write-Output "[$now] status.err written to $dir"
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
    # Best-effort: a failed cache update must not block the marker write.
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
    Write-Output "[$now] $(if ($healthy) { 'status.ok' } else { 'status.err' }) status=$status"
    exit 0
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
