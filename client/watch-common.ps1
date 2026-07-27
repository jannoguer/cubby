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

# Service accounts (e.g. LocalSystem) lack per-user PATH entries, so fall back
# to probing each profile. The .mutagen path comes back too, or the CLI would
# talk to the service account's own empty daemon.
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

# Runs in a background job so a wedged daemon cannot hang the probe.
function Get-SessionState {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][hashtable]$MutagenCli
    )
    $job = Start-Job -ScriptBlock {
        param($Name, $Exe, $DataDir)
        # Do not override an explicitly configured data directory.
        if ($DataDir -and -not $env:MUTAGEN_DATA_DIRECTORY) {
            $env:MUTAGEN_DATA_DIRECTORY = $DataDir
        }
        # Split back out of the merged stream: a warning printed alongside a
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
                catch [System.PlatformNotSupportedException] {
                    # No replace support on this filesystem; Move-Item handles it.
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
