#!/usr/bin/env pwsh
<#
.SYNOPSIS
Shared helpers for the watch-*.ps1 probe scripts. Not a standalone script.

.DESCRIPTION
Dot-source from a script in the same directory:

    . (Join-Path $PSScriptRoot 'watch-common.ps1')

Keep this file next to watch-status.ps1 and watch-conflicts.ps1; they fail
at startup without it.
#>

# The hash suffix keeps names that differ only in stripped characters
# ("a/b" vs "a_b") from collapsing onto the same slug.
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

# Service accounts (e.g. LocalSystem) lack per-user PATH entries, so a scheduled
# run needs the location spelled out. It is never guessed by scanning C:\Users:
# the first match there wins regardless of which install is legitimate, and any
# local user can plant one in a profile they already own (C:\Users\Public needs
# no privileges at all), which would run with the scheduled task's rights.
#
# The daemon's data directory must be named just as explicitly, or the CLI talks
# to the service account's own empty daemon. Mutagen's own MUTAGEN_DATA_DIRECTORY
# works if the scheduler can set it; CUBBY_MUTAGEN_DATA_DIR covers the rest.
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
        # Do not override an explicitly configured data directory.
        if ($dataDir -and -not $env:MUTAGEN_DATA_DIRECTORY) {
            $env:MUTAGEN_DATA_DIRECTORY = $dataDir
        }
        # Split back out of the merged stream: a warning printed alongside a
        # successful listing must not corrupt the JSON on stdout.
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
    # Windows PowerShell 5.1 emits a JSON array as one object; wrapping the
    # pipeline directly in @() would nest it and the count check could never fire.
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

# File.Replace swaps in place, so consumers never observe the destination
# missing. A reader or scanner holding it open fails both calls, hence the retry.
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
                catch [System.PlatformNotSupportedException], [System.IO.IOException] {
                    # No replace support on this filesystem, or the destination
                    # is busy: Move-Item below handles both, retried on failure.
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
