# Installs the newest Mutagen into <Dir>, checked against the release's SHA256SUMS.
# On a GitHub runner <Dir> is also put on the PATH of the later steps.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File .github\install-mutagen.ps1 -Dir <folder>
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'

# The redirect names the release without an API call, so there is no rate limit to hit.
$v = (Invoke-WebRequest https://github.com/mutagen-io/mutagen/releases/latest -UseBasicParsing -Method Head).BaseResponse.ResponseUri.Segments[-1]
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$f = "mutagen_windows_${arch}_$v.zip"
$base = "https://github.com/mutagen-io/mutagen/releases/download/$v"
$t = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
$null = New-Item -ItemType Directory $t
try {
    Invoke-WebRequest "$base/$f" -OutFile "$t\$f" -UseBasicParsing
    Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$t\SHA256SUMS" -UseBasicParsing
    $want = (Select-String -Path "$t\SHA256SUMS" -Pattern "  $([regex]::Escape($f))$").Line.Split(' ')[0]
    if ((Get-FileHash "$t\$f" -Algorithm SHA256).Hash -ne $want) { throw "checksum mismatch for $f" }
    Expand-Archive "$t\$f" -DestinationPath $Dir -Force
} finally {
    Remove-Item $t -Recurse -Force
}
if ($env:GITHUB_PATH) { Add-Content $env:GITHUB_PATH $Dir }
"Installed Mutagen $v ($arch) in $Dir"
