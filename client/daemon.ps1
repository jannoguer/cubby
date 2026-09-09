#!/usr/bin/env pwsh
<#
.SYNOPSIS
Runs the Mutagen daemon in the foreground and writes its output to rotating
log files under .cubby/local/logs in the given sync root. Restarts it when it
dies; exits when it stops cleanly (mutagen daemon stop).

.DESCRIPTION
Logs: .cubby/local/logs/mutagen.log, rotated at MaxLogBytes into .1 .. .KeepLogs.
The daemon is per user, so pick the sync root whose .cubby/local should hold
the log.

Windows: -Register makes this script the login task instead of Mutagen's own
(mutagen daemon register), hidden through run-hidden.vbs; Mutagen's entry is
removed so two daemons never race. Takes effect at the next login; to switch
now, run "mutagen daemon stop" and start this script once by hand.

macOS: run it from a LaunchAgent, for example ~/Library/LaunchAgents/io.cubby.mutagen.plist
with ProgramArguments [pwsh, -NoProfile, -File, /path/.cubby/client/daemon.ps1, /path]
and RunAtLoad true, after "mutagen daemon unregister". Not exercised by the author.

Linux: keep client/linux/mutagen.service; journald already keeps its log
(journalctl --user -u mutagen).

Needs common.ps1 next to it.

.PARAMETER LocalDir
The local side of the sync session (the folder given to mutagen sync create).

.PARAMETER Register
Windows only: write the login entry and exit.

.PARAMETER MutagenPath
Path to the mutagen executable when PATH lacks it. Also settable as CUBBY_MUTAGEN_PATH.

.EXAMPLE
pwsh -NoProfile -File daemon.ps1 -Register C:\Users\me\Cubby
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$LocalDir,

    [Parameter()]
    [switch]$Register,

    [Parameter()]
    [string]$MutagenPath,

    [Parameter()]
    [ValidateRange(64KB, 1GB)]
    [long]$MaxLogBytes = 1MB,

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$KeepLogs = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
    Write-Warning "'$LocalDir' is not a directory."
    exit 1
}
$LocalDir = (Resolve-Path -LiteralPath $LocalDir).ProviderPath
$logFile = Join-Path (Join-Path (Join-Path (Join-Path $LocalDir '.cubby') 'local') 'logs') 'mutagen.log'

function Get-Timestamp { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

if ($Register) {
    if ($env:OS -ne 'Windows_NT') {
        Write-Warning '-Register is Windows only; see the header for macOS and Linux.'
        exit 1
    }
    $vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
    # The edition running now is the one known to exist at login.
    $host_exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $cmd = "wscript.exe `"$vbs`" $host_exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" `"$LocalDir`""
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Set-ItemProperty -Path $key -Name 'Cubby' -Value $cmd
    Write-Output "Login entry written: $cmd"
    if ($null -ne (Get-ItemProperty -Path $key -Name 'Mutagen' -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $key -Name 'Mutagen'
        Write-Output "Removed Mutagen's own login entry."
    }
    exit 0
}

$cli = Resolve-MutagenCli -MutagenPath $MutagenPath
if ($null -eq $cli) {
    Write-Warning 'mutagen was not found on PATH; pass -MutagenPath or set CUBBY_MUTAGEN_PATH.'
    exit 1
}
if ($cli.DataDir -and -not $env:MUTAGEN_DATA_DIRECTORY) {
    $env:MUTAGEN_DATA_DIRECTORY = $cli.DataDir
}

# Three exits within seconds of each other: another daemon owns the socket, or
# mutagen is broken; restarting forever would only fill the log.
$quickExits = 0
while ($true) {
    Add-LogLine -Path $logFile -Line "$(Get-Timestamp) [cubby] starting $($cli.Path) daemon run" -MaxBytes $MaxLogBytes -Keep $KeepLogs
    $started = [DateTime]::UtcNow
    # Windows PowerShell 5.1 turns the first redirected stderr line into a terminating error under Stop.
    $ErrorActionPreference = 'Continue'
    & $cli.Path daemon run 2>&1 | ForEach-Object {
        Add-LogLine -Path $logFile -Line "$_" -MaxBytes $MaxLogBytes -Keep $KeepLogs
    }
    $rc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Add-LogLine -Path $logFile -Line "$(Get-Timestamp) [cubby] mutagen daemon exited with code $rc" -MaxBytes $MaxLogBytes -Keep $KeepLogs
    if ($rc -eq 0) { exit 0 }
    if (([DateTime]::UtcNow - $started).TotalSeconds -lt 10) { $quickExits++ } else { $quickExits = 0 }
    if ($quickExits -ge 3) {
        Add-LogLine -Path $logFile -Line "$(Get-Timestamp) [cubby] giving up after 3 immediate exits; is another daemon running?" -MaxBytes $MaxLogBytes -Keep $KeepLogs
        exit 1
    }
    Start-Sleep -Seconds 5
}
