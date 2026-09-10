#!/usr/bin/env pwsh
<#
.SYNOPSIS
Checks a Mutagen sync session once and writes health markers into .cubby/local
under the session's local directory. Schedule it with cron or Task Scheduler.

.DESCRIPTION
Markers, each staged and swapped in so consumers never see a partial file:
  status.ok | status.err  sync health as key=value lines; exactly one exists
                          after each run. Healthy means: not paused, no error,
                          both endpoints connected, no per-file problems
                          (problems=0), status is a normal syncing state.
  conflicts.json          Mutagen's raw conflict array. Removed when there are
                          none; left untouched when the session cannot be
                          queried, since the state is unknown.

The status marker also summarizes the server's backup marker (.cubby/backup/
status.ok or .err, synced from the server): backupStatus=
ok|partial|stale|failed|unknown, backupCount, backupLast, backupLastResult,
backupSkipped, backupUpdatedAt and backupOffsite (off|ok|rsync-N). Partial means
the last snapshot skipped backupSkipped unreadable paths (listed in the server
log); stale means older than twice the backup interval. Backups never change healthy=.

The local directory is cached so status.err can still be written when the
daemon is unreachable. Each run appends its summary line to
.cubby/local/logs/watch.log (rotated at 1 MB, five files kept).

Notifications: when the server marker carries ntfyUrl (NTFY_URL in the server's
.env) or CUBBY_NTFY_URL is set, changes since the previous run are pushed to that
ntfy topic: sync unhealthy or healthy again, conflicts appearing or resolved,
backups stale or running again. Backup failures are pushed by the server itself.
Nothing is sent without a URL or on the first run. The marker is a synced file
any client can rewrite, so its URL is used only when it is https on ntfy.sh, and
the first one seen is pinned per device next to the cache; a later change is
reported to the pinned topic once and ignored until the .ntfy pin file is
deleted. CUBBY_NTFY_URL is trusted as given.

The markers stay on this device: create the session with --ignore=/.cubby/local.
The script reads the session's ignore list and writes nothing when that path is
not ignored, so a forgotten flag cannot leak markers into the sync.

Windows PowerShell 5.1 and PowerShell 7+ (macOS/Linux: pwsh). Needs common.ps1 next to it.

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
Exit codes: 0 = status.ok written; 2 = status.err written; 1 = no status marker written.

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
. (Join-Path $PSScriptRoot 'common.ps1')

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

# Windows command-line quoting for ProcessStartInfo.Arguments; PowerShell 5.1 has no ArgumentList.
function ConvertTo-ArgumentToken([string]$Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $slashes++ }
        elseif ($ch -eq '"') { [void]$sb.Append([char]'\', $slashes * 2 + 1).Append('"'); $slashes = 0 }
        else { [void]$sb.Append([char]'\', $slashes).Append($ch); $slashes = 0 }
    }
    return $sb.Append([char]'\', $slashes * 2).Append('"').ToString()
}

function Get-SessionState {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][hashtable]$MutagenCli
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MutagenCli.Path
    $psi.Arguments = (@('sync', 'list', '--template', '{{ json . }}', $SessionName) | ForEach-Object { ConvertTo-ArgumentToken $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Otherwise the CLI starts its own daemon when none answers, racing daemon.ps1 and hiding a crash.
    $psi.EnvironmentVariables['MUTAGEN_DISABLE_AUTOSTART'] = '1'
    if ($MutagenCli.DataDir -and -not $env:MUTAGEN_DATA_DIRECTORY) {
        $psi.EnvironmentVariables['MUTAGEN_DATA_DIRECTORY'] = $MutagenCli.DataDir
    }

    $proc = $null
    try {
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        }
        catch {
            return @{ Ok = $false; Error = "failed to run mutagen: $($_.Exception.Message)" }
        }
        # Both streams drained concurrently; a full pipe would block mutagen.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $proc.Kill()
            }
            catch [System.InvalidOperationException] {
                Write-Verbose 'mutagen exited between the deadline and the kill'
            }
            return @{ Ok = $false; Error = "mutagen did not answer within $TimeoutSeconds seconds" }
        }
        $text = $outTask.Result.Trim()
        $errText = ConvertTo-SingleLine $errTask.Result.Trim()
        $exitCode = $proc.ExitCode
    }
    finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }

    if ($exitCode -ne 0) {
        $detail = (@($errText, $text) | Where-Object { $_ }) -join ' | '
        return @{ Ok = $false; Error = "mutagen exited with code ${exitCode}: $detail" }
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

# Files Mutagen cannot scan or write (permissions, names invalid on one side)
# are reported per endpoint while the session status stays normal.
function Get-ProblemCount($Session) {
    $n = 0
    foreach ($endpoint in @($Session.alpha, $Session.beta)) {
        if ($null -eq $endpoint) { continue }
        $n += @($endpoint.scanProblems | Where-Object { $null -ne $_ }).Count
        $n += @($endpoint.transitionProblems | Where-Object { $null -ne $_ }).Count
        $n += [int]($endpoint.excludedScanProblems + 0)
        $n += [int]($endpoint.excludedTransitionProblems + 0)
    }
    return $n
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
    Initialize-Directory $cacheDir
    return Join-Path $cacheDir "$(Get-SessionSlug $SessionName).dir"
}

# A line break inside a value would inject extra key=value lines; Mutagen's
# progress output carries bare carriage returns.
function ConvertTo-SingleLine([string]$Text) {
    return ($Text -replace "[\r\n]+", ' ')
}

function Read-KeyValueFile([string]$Path) {
    $fields = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $fields[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    return $fields
}

function ConvertTo-Flag([bool]$Value) {
    if ($Value) { return 'true' } else { return 'false' }
}

# Reads the server's marker; .err wins over .ok, and a missing or malformed
# marker is unknown rather than an error of this probe.
function Get-BackupSummary([string]$Dir) {
    $summary = @{ Status = 'unknown'; Count = ''; Last = ''; LastResult = ''; Skipped = ''; UpdatedAt = ''; NtfyUrl = ''; Offsite = '' }
    $markerDir = Join-Path (Join-Path $Dir '.cubby') 'backup'
    $err = Join-Path $markerDir 'status.err'
    $ok = Join-Path $markerDir 'status.ok'
    if (Test-Path -LiteralPath $err) { $file = $err; $summary.Status = 'failed' }
    elseif (Test-Path -LiteralPath $ok) { $file = $ok; $summary.Status = 'ok' }
    else { return $summary }

    $fields = Read-KeyValueFile $file
    $summary.Count = "$($fields['snapshots'])"
    $summary.Last = "$($fields['lastSnapshot'])"
    $summary.LastResult = "$($fields['lastResult'])"
    $summary.Skipped = "$($fields['skipped'])"
    $summary.UpdatedAt = "$($fields['updatedAt'])"
    $summary.NtfyUrl = "$($fields['ntfyUrl'])"
    $summary.Offsite = "$($fields['offsite'])"
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
    elseif ($summary.LastResult -eq 'partial') {
        $summary.Status = 'partial'
    }
    return $summary
}

function Write-RunLog([string]$Dir, [string]$Text) {
    Add-LogLine -Path (Get-LocalLogPath $Dir 'watch.log') -Line $Text
}

# The marker this run is about to replace, as key=value fields; $null on the first run.
function Read-PreviousMarker([string]$Dir) {
    foreach ($name in @('status.ok', 'status.err')) {
        $path = Join-Path (Get-MarkerDir $Dir) $name
        if (Test-Path -LiteralPath $path) { return Read-KeyValueFile $path }
    }
    return $null
}

# A failed push is a warning in the log, never a failed run.
function Send-Notification([string]$Dir, [string]$Url, [string]$Priority, [string]$Text) {
    try {
        Invoke-RestMethod -Method Post -Uri $Url -Body $Text -ContentType 'text/plain' -TimeoutSec 10 `
            -Headers @{ Title = 'Cubby'; Priority = $Priority } | Out-Null
        Write-RunLog $Dir "[$now] notified: $Text"
    }
    catch {
        $msg = "[$now] could not notify ${Url}: $($_.Exception.Message)"
        Write-RunLog $Dir $msg
        Write-Warning $msg
    }
}

function Test-TrustedNtfyUrl([string]$Url) {
    $uri = $null
    return [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and $uri.Host -eq 'ntfy.sh'
}

function Resolve-NtfyUrl([hashtable]$Backup) {
    $result = @{ Url = $null; Ignored = ''; Pin = [System.IO.Path]::ChangeExtension($cachePath, '.ntfy') }
    if (-not [string]::IsNullOrWhiteSpace($env:CUBBY_NTFY_URL)) {
        $result.Url = $env:CUBBY_NTFY_URL
        return $result
    }
    $offered = "$($Backup.NtfyUrl)".Trim()
    if (Test-Path -LiteralPath $result.Pin) {
        $result.Url = ([System.IO.File]::ReadAllText($result.Pin)).Trim()
        if ($offered -and $offered -ne $result.Url) { $result.Ignored = $offered }
        return $result
    }
    if (Test-TrustedNtfyUrl $offered) {
        try {
            [System.IO.File]::WriteAllText($result.Pin, $offered)
        }
        catch {
            Write-Warning "[$now] could not pin the ntfy URL in '$($result.Pin)': $($_.Exception.Message)"
        }
        $result.Url = $offered
    }
    return $result
}

# Edge-triggered against the previous marker. Conflicts -1 = unknown this run.
function Send-TransitionNotification([string]$Dir, [hashtable]$Previous, [bool]$Healthy, [string]$Detail, [int]$Conflicts, [hashtable]$Backup, [hashtable]$Ntfy) {
    $url = $Ntfy.Url
    if ([string]::IsNullOrWhiteSpace($url) -or $null -eq $Previous) { return }
    $tag = "$SessionName on $([Environment]::MachineName)"

    if ($Ntfy.Ignored -and "$($Previous['ntfyIgnored'])" -ne $Ntfy.Ignored) {
        Send-Notification $Dir $url 'high' "$tag ignores a changed ntfy URL in the server marker; delete $($Ntfy.Pin) on that device to accept it."
    }

    $wasHealthy = ("$($Previous['healthy'])" -eq 'true')
    if ($wasHealthy -and -not $Healthy) { Send-Notification $Dir $url 'high' "$tag is not syncing: $Detail" }
    elseif (-not $wasHealthy -and $Healthy) { Send-Notification $Dir $url 'default' "$tag is syncing again." }

    $hadConflicts = 0
    if ($Conflicts -ge 0 -and [int]::TryParse("$($Previous['conflicts'])", [ref]$hadConflicts)) {
        if ($hadConflicts -eq 0 -and $Conflicts -gt 0) { Send-Notification $Dir $url 'high' "$tag has $Conflicts conflict(s); see .cubby/local/conflicts.json." }
        elseif ($hadConflicts -gt 0 -and $Conflicts -eq 0) { Send-Notification $Dir $url 'default' "$tag conflicts resolved." }
    }

    # Failures and partial snapshots are the server's to report.
    $wasBackup = "$($Previous['backupStatus'])"
    if ($wasBackup -ne $Backup.Status) {
        if ($Backup.Status -eq 'stale') { Send-Notification $Dir $url 'high' "$tag sees no server backup since $($Backup.UpdatedAt)." }
        elseif ($wasBackup -eq 'stale' -and $Backup.Status -eq 'ok') { Send-Notification $Dir $url 'default' "$tag sees server backups running again." }
    }
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

# The status marker's lines: the run header, the sync fields of this path, then
# the backup summary and the ntfy pin state.
function Format-StatusMarker([string[]]$SyncFields, [hashtable]$Backup, [hashtable]$Ntfy) {
    return @(
        "checkedAt=$now"
        "session=$(ConvertTo-SingleLine $SessionName)"
    ) + $SyncFields + @(
        "backupStatus=$($Backup.Status)"
        "backupCount=$($Backup.Count)"
        "backupLast=$($Backup.Last)"
        "backupLastResult=$($Backup.LastResult)"
        "backupSkipped=$($Backup.Skipped)"
        "backupUpdatedAt=$($Backup.UpdatedAt)"
        "backupOffsite=$($Backup.Offsite)"
        "ntfyIgnored=$($Ntfy.Ignored)"
    )
}

# Staged in the marker directory and swapped in, so a reader never sees a partial file.
function Write-MarkerFile([string]$Dir, [string]$Name, [string]$Stage, [string]$Content) {
    $markerDir = Get-MarkerDir $Dir
    Initialize-Directory $markerDir
    $stagePath = Join-Path $markerDir $Stage
    try {
        [System.IO.File]::WriteAllText($stagePath, $Content)
        Move-IntoPlace -Stage $stagePath -Destination (Join-Path $markerDir $Name)
    }
    catch {
        if (Test-Path -LiteralPath $stagePath) {
            Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

# The stale marker goes last, so at least one marker exists at all times.
function Write-StatusMarker([string]$Dir, [bool]$Healthy, [string[]]$Lines) {
    if ($Healthy) { $target = 'status.ok'; $stale = 'status.err' } else { $target = 'status.err'; $stale = 'status.ok' }
    Write-MarkerFile -Dir $Dir -Name $target -Stage '.status.tmp' -Content (($Lines -join "`n") + "`n")
    $stalePath = Join-Path (Get-MarkerDir $Dir) $stale
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

# Removed when there are no conflicts, so its presence alone is the signal.
function Write-ConflictsMarker([string]$Dir, [object[]]$Conflicts, $Session) {
    $path = Join-Path (Get-MarkerDir $Dir) 'conflicts.json'
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
    $json = ConvertTo-Json -InputObject $Conflicts -Depth 32
    Write-MarkerFile -Dir $Dir -Name 'conflicts.json' -Stage 'conflicts.json.tmp' -Content ($json + "`n")
}

$MutagenCli = Resolve-MutagenCli -MutagenPath $MutagenPath
if ($null -eq $MutagenCli) {
    Write-Warning 'mutagen was not found on PATH; pass -MutagenPath or set CUBBY_MUTAGEN_PATH.'
    exit 1
}

$now = Get-Timestamp

# Overlapping scheduled runs would contend for the same staging file. A lock file
# in the per-user cache dir spans logon sessions, cannot be squatted by another
# local account like a Global\ mutex, and is released by the OS if a run dies.
$cachePath = Get-CachePath
$lock = $null
try {
    try {
        $lock = [System.IO.File]::Open("$cachePath.lock", [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        Write-Warning "[$now] another instance is already running for '$SessionName'"
        exit 1
    }

    $result = Get-SessionState -SessionName $SessionName -TimeoutSeconds $TimeoutSeconds -MutagenCli $MutagenCli

    if (-not $result.Ok) {
        Write-Warning "[$now] $($result.Error)"
        $dir = $null
        if (Test-Path -LiteralPath $cachePath) {
            $dir = ([System.IO.File]::ReadAllText($cachePath)).Trim()
        }
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $backup = Get-BackupSummary $dir
            $ntfy = Resolve-NtfyUrl $backup
            $previous = Read-PreviousMarker $dir
            $lines = Format-StatusMarker -Backup $backup -Ntfy $ntfy -SyncFields @(
                "healthy=false"
                "status=unknown"
                "lastError=$(ConvertTo-SingleLine $result.Error)"
            )
            Write-StatusMarker -Dir $dir -Healthy $false -Lines $lines
            Send-TransitionNotification -Dir $dir -Previous $previous -Healthy $false -Detail (ConvertTo-SingleLine $result.Error) -Conflicts -1 -Backup $backup -Ntfy $ntfy
            $summary = "[$now] status.err lastError=$(ConvertTo-SingleLine $result.Error) backups=$($backup.Status)"
            Write-RunLog $dir $summary
            Write-Output $summary
            exit 2
        }
        Write-Warning "[$now] synced directory unknown; no marker written"
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
    $problems = Get-ProblemCount $session

    $healthy = ($OkStatuses -contains $status) -and
        (-not $paused) -and
        ($lastError -eq '') -and
        $alphaConnected -and
        $betaConnected -and
        ($problems -eq 0)

    $backup = Get-BackupSummary $dir
    $ntfy = Resolve-NtfyUrl $backup
    $previous = Read-PreviousMarker $dir
    $lines = Format-StatusMarker -Backup $backup -Ntfy $ntfy -SyncFields @(
        "healthy=$(ConvertTo-Flag $healthy)"
        "status=$status"
        "paused=$(ConvertTo-Flag $paused)"
        "alphaConnected=$(ConvertTo-Flag $alphaConnected)"
        "betaConnected=$(ConvertTo-Flag $betaConnected)"
        "conflicts=$($conflicts.Count)"
        "problems=$problems"
        "lastError=$lastError"
    )
    # Before the status marker, so exit 1 still means no status marker was written.
    try {
        Write-ConflictsMarker -Dir $dir -Conflicts $conflicts -Session $session
    }
    catch {
        Write-Warning "[$now] failed to update conflicts.json: $($_.Exception.Message)"
        exit 1
    }
    Write-StatusMarker -Dir $dir -Healthy $healthy -Lines $lines
    $detail = "status=$status paused=$paused alpha=$alphaConnected beta=$betaConnected problems=$problems lastError=$lastError"
    Send-TransitionNotification -Dir $dir -Previous $previous -Healthy $healthy -Detail $detail -Conflicts $conflicts.Count -Backup $backup -Ntfy $ntfy

    $marker = if ($healthy) { 'status.ok' } else { 'status.err' }
    $summary = "[$now] $marker status=$status conflicts=$($conflicts.Count) problems=$problems lastError=$lastError backups=$($backup.Status) count=$($backup.Count) last=$($backup.Last)"
    Write-RunLog $dir $summary
    Write-Output $summary
    exit $(if ($healthy) { 0 } else { 2 })
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
