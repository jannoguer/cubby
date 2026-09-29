# Notifies when an unpaused Mutagen session stays disconnected, halted,
# conflicted or failing for over a minute; again only when that changes.
# Run as the logged-on user under Windows PowerShell 5.1: pwsh cannot load
# the WinRT notification types.
$state = "$HOME\.local\state\cubby\alert"
# A missing daemon is the failure itself; autostarting one would hide it.
$env:MUTAGEN_DISABLE_AUTOSTART = '1'

function Get-Problems {
    if (-not (Get-Command mutagen -ErrorAction Ignore)) {
        return "Can't find mutagen on PATH."
    }
    # No double quotes: Windows PowerShell 5.1 mangles them in native arguments.
    $out = mutagen sync list --template '{{range .}}{{.Paused}} {{json .Status}} {{with .SessionState}}{{len .Conflicts}}{{else}}0{{end}} {{with .Alpha.EndpointState}}{{len .ScanProblems}} {{len .TransitionProblems}}{{else}}0 0{{end}} {{with .Beta.EndpointState}}{{len .ScanProblems}} {{len .TransitionProblems}}{{else}}0 0{{end}} {{with .SessionState}}{{.LastError}}{{end}}{{println}}{{end}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        $err = "$(@($out)[0])".Trim()
        if ($err.EndsWith('(is the daemon running?)')) { return "Mutagen isn't running." }
        return "Can't check sync ($($err -replace '^Error: '))."
    }
    # The error comes last as it has spaces; any lines it spills onto are
    # skipped as they do not start with false.
    foreach ($line in $out) {
        $paused, $status, $conflicts, $a1, $a2, $b1, $b2, $err = "$line" -split ' '
        if ($paused -ne 'false') { continue }
        $err = "$err".Trim()
        $n = [int]$a1 + [int]$a2 + [int]$b1 + [int]$b2
        $msg = switch ($status.Trim('"')) {
            'connecting-alpha' { "Can't reach this device" }
            'connecting-beta' { "Can't reach the server" }
            'disconnected' { 'Not connected' }
            'halted-on-root-emptied' { 'Stopped, the folder was emptied on one side' }
            'halted-on-root-deletion' { 'Stopped, the folder was deleted on one side' }
            'halted-on-root-type-change' { 'Stopped, the folder was replaced by a file on one side' }
        }
        if ($msg -and $err) { $msg += " ($err)" }
        if ($msg) { $msg += '.' }
        if ($conflicts -ne '0') { $msg = "$msg Conflicts to resolve: $conflicts.".Trim() }
        if ($n) { $msg = "$msg Files that could not sync: $n.".Trim() }
        if ($msg) { $msg }
    }
}

$p = @(Get-Problems)
if ($p.Count) {
    # Rides out reconnects and brief scans.
    Start-Sleep -Seconds 60
    $p = @(Get-Problems)
}
$p = ($p -join "`n").Trim()
if (-not $p) {
    if (Test-Path $state) { Remove-Item $state }
    exit 0
}
if ((Test-Path $state) -and (Get-Content -Raw $state).Trim() -eq $p) { exit 0 }

# Loads the WinRT assembly; the bare type names below resolve only after it.
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$text = $xml.GetElementsByTagName('text')
# Text nodes, not string-built XML, so the report needs no escaping.
$null = $text.Item(0).AppendChild($xml.CreateTextNode('cubby'))
$null = $text.Item(1).AppendChild($xml.CreateTextNode($p))
# Windows drops notifications from unregistered app IDs, so borrow PowerShell's.
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
$null = New-Item -ItemType Directory -Force (Split-Path $state)
Set-Content -Path $state -Value $p -Encoding utf8
