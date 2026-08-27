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
pwsh -NoProfile -File watch-conflicts.ps1 Cubby

.NOTES
Exit codes: 0 = session queried and conflicts.json updated (or removed);
1 = anything else (the file is left untouched).

Scheduling examples:
  cron:           * * * * * pwsh -NoProfile -File /path/to/watch-conflicts.ps1 Cubby
  Task Scheduler: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\watch-conflicts.ps1 Cubby

On Windows, prefer wrapping the command with run-hidden.vbs (same folder):
  wscript.exe C:\path\to\run-hidden.vbs powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\watch-conflicts.ps1 Cubby
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

$MutagenCli = Resolve-MutagenCli -MutagenPath $MutagenPath
if ($null -eq $MutagenCli) {
    Write-Warning 'mutagen was not found on PATH; pass -MutagenPath or set CUBBY_MUTAGEN_PATH.'
    exit 1
}

$now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Overlapping scheduled runs would contend for the same staging file.
$mutex = New-Object System.Threading.Mutex($false, "cubby-watch-conflicts-$(Get-SessionSlug $SessionName)")
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

    $result = Get-SessionState -SessionName $SessionName -TimeoutSeconds $TimeoutSeconds -MutagenCli $MutagenCli

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
