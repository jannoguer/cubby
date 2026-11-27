# Checks client/alert.ps1 under Windows PowerShell 5.1: Get-Problems on stubbed Mutagen output, then on the
# installed Mutagen in a daemon of its own.
# Leave $ErrorActionPreference alone: under Stop, the 2>&1 in alert.ps1 makes a stopped daemon's stderr terminate it.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test\client.ps1
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$daemon = $false
# alert.ps1 sets this at its top level, outside the function under test.
$env:MUTAGEN_DISABLE_AUTOSTART = '1'

# The function alone: the rest of alert.ps1 posts a toast. Parsing the whole file also catches a syntax error in it.
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$repo\client\alert.ps1", [ref]$null, [ref]$errors)
if ($errors) { throw "FAIL: client\alert.ps1 does not parse: $errors" }
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Problems' }, $true)
if (-not $fn) { throw 'FAIL: client\alert.ps1 has no Get-Problems' }
. ([scriptblock]::Create($fn.Extent.Text))

# Made after the parse above: a throw before the try would leave it behind.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "cubby-client-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory $tmp | Out-Null

# Check <what> <expected>: Get-Problems reports exactly these lines.
function Check($what, $want) {
    $got = @(Get-Problems) -join "`n"
    if ($got -ne $want) { throw "FAIL: $what`n  want: $want`n  got:  $got" }
}
# Stub <exit code> <lines>: what the stand-in mutagen prints. cmd sets $LASTEXITCODE as the real one does.
function Stub($rc, [string[]]$lines) {
    $script:StubRc = $rc
    $script:StubOut = $lines
}
function mutagen {
    cmd /c exit $script:StubRc
    $script:StubOut
}
# Invoke-Mutagen <args>: the real mutagen, failing the test on a non-zero exit.
function Invoke-Mutagen {
    $null = & (Get-Command -CommandType Application mutagen) @args
    if ($LASTEXITCODE -ne 0) { throw "FAIL: mutagen $args exited $LASTEXITCODE" }
}
# Sync-Session <name>: a session between two new folders, synchronized once.
function Sync-Session($name) {
    New-Item -ItemType Directory "$tmp\$name-alpha", "$tmp\$name-beta" | Out-Null
    Invoke-Mutagen sync create "--name=$name" "$tmp\$name-alpha" "$tmp\$name-beta"
    Invoke-Mutagen sync flush $name
}

try {
    $down = 'Error: unable to connect to daemon: connection refused (is the daemon running?)'
    Stub 0 'false "watching" 0 0 0 0 0 ', 'true "disconnected" 0 0 0 0 0 '
    Check 'alert on a healthy or paused session' ''
    Stub 0 'false "connecting-beta" 0 0 0 0 0 dial tcp: i/o timeout', 'false "watching" 2 1 0 0 3 '
    Check 'a server that cannot be reached, and conflicts' "Can't reach the server (dial tcp: i/o timeout).`nConflicts to resolve: 2. Files that could not sync: 4."
    Stub 1 $down
    Check 'a stopped daemon' "Mutagen isn't running."
    Stub 0 'false "halted-on-root-deletion" 0 0 0 0 0 '
    Check 'a deleted root' 'Stopped, the folder was deleted on one side.'
    Stub 0 'false "watching" 1 0 0 0 0 '
    Check 'one conflict' 'Conflicts to resolve: 1.'
    Stub 1 'Error: permission denied'
    Check 'another mutagen error' "Can't check sync (permission denied)."
    # An error line spilling into one that starts with false: neither run as code nor an end to the report.
    Stub 0 'false "connecting-beta" 0 0 0 0 0 dial tcp: reset', ('false "x" 0 $(New-Item -Path ''{0}\pwned'') 0 0 0' -f $tmp), 'false "disconnected" 0 0 0 0 0 '
    Check 'a spilled error line' "Can't reach the server (dial tcp: reset).`nNot connected."
    if (Test-Path "$tmp\pwned") { throw 'FAIL: alert ran a spilled error line as code' }
    Remove-Item Function:\mutagen
    Write-Output 'ok: alert.ps1, stubbed Mutagen'

    # The same function on what Mutagen really prints. A data directory of its own keeps these sessions apart from the machine's.
    $env:MUTAGEN_DATA_DIRECTORY = "$tmp\mutagen"
    # Prints "unable to connect to daemon" to stderr first: it probes for a running one, then starts ours.
    Invoke-Mutagen daemon start
    # Not marked started until it is seen to hold none of the machine's sessions, so cleanup never stops one that is not ours.
    $others = & (Get-Command -CommandType Application mutagen) sync list --template '{{range .}}{{.Name}} {{end}}'
    if ($others) { throw "FAIL: the isolated daemon holds other sessions: $others" }
    $daemon = $true

    Sync-Session ok
    Check 'a healthy real session' ''

    New-Item -ItemType Directory "$tmp\cf-alpha", "$tmp\cf-beta" | Out-Null
    Set-Content "$tmp\cf-alpha\x" one
    Set-Content "$tmp\cf-beta\x" two
    Invoke-Mutagen sync create --name=cf "$tmp\cf-alpha" "$tmp\cf-beta"
    Invoke-Mutagen sync flush cf
    Check 'a conflict' 'Conflicts to resolve: 1.'
    Invoke-Mutagen sync pause cf
    Check 'a paused session' ''

    New-Item -ItemType Directory "$tmp\ro-alpha", "$tmp\ro-beta" | Out-Null
    Set-Content "$tmp\ro-alpha\locked" x
    icacls "$tmp\ro-alpha\locked" /deny "*${sid}:(R)" | Out-Null
    Invoke-Mutagen sync create --name=ro "$tmp\ro-alpha" "$tmp\ro-beta"
    Invoke-Mutagen sync flush ro
    Check 'an unreadable file' 'Files that could not sync: 1.'
    Invoke-Mutagen sync pause ro

    Sync-Session rd
    Remove-Item -Recurse -Force "$tmp\rd-alpha"
    $n = 0
    while ((@(Get-Problems) -join "`n") -notlike '*Stopped, the folder was deleted on one side*') {
        if (++$n -ge 30) { throw 'FAIL: a deleted session folder was never reported' }
        Start-Sleep -Seconds 1
    }
    Invoke-Mutagen sync pause rd

    Invoke-Mutagen daemon stop
    $daemon = $false
    Check 'a stopped daemon, for real' "Mutagen isn't running."
    Write-Output 'ok: alert.ps1, real Mutagen'
}
finally {
    # Only the isolated daemon: the data directory is checked first.
    if ($daemon -and $env:MUTAGEN_DATA_DIRECTORY -eq "$tmp\mutagen") { Invoke-Mutagen daemon stop }
    icacls $tmp /reset /t /c /q | Out-Null
    Remove-Item -Recurse -Force $tmp
}
