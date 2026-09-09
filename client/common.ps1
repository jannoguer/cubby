# Shared by watch.ps1 and daemon.ps1; dot-sourced, not run.

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

# Appends one line; at MaxBytes the file rotates to .1 .. .Keep.
function Add-LogLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
        [long]$MaxBytes = 1MB,
        [int]$Keep = 5
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge $MaxBytes) {
        for ($i = $Keep - 1; $i -ge 1; $i--) {
            if (Test-Path -LiteralPath "$Path.$i") {
                Move-Item -LiteralPath "$Path.$i" -Destination "$Path.$($i + 1)" -Force
            }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
    [System.IO.File]::AppendAllText($Path, $Line + "`n")
}

function Get-Timestamp { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

# This device's markers and logs; the session must ignore /.cubby/local.
function Get-MarkerDir([string]$Dir) {
    return Join-Path (Join-Path $Dir '.cubby') 'local'
}

function Get-LocalLogPath([string]$Dir, [string]$Name) {
    return Join-Path (Join-Path (Get-MarkerDir $Dir) 'logs') $Name
}
