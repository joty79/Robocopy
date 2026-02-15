param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SourceFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$stateDir = Join-Path $scriptRoot "state"
$logsDir = Join-Path $scriptRoot "logs"
$stageFile = Join-Path $stateDir "folder_bench_stage.json"
$logFile = Join-Path $logsDir "folder_bench.log"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Normalize-ContextPathValue {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $candidate = $PathValue.Trim()

    if ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

    if ($candidate -match '^[A-Za-z]:$') { return ($candidate + "\") }
    if ($candidate -match '^[A-Za-z]:\\\.$') { return ($candidate.Substring(0, 2) + "\") }
    if ($candidate.EndsWith("\.")) { return $candidate.Substring(0, $candidate.Length - 1) }
    return $candidate
}

function Write-BenchLog {
    param([Parameter(Mandatory = $true)][string]$Line)
    Ensure-Directory -Path $logsDir
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logFile -Value ("{0} | {1}" -f $ts, $Line) -Encoding UTF8
}

Ensure-Directory -Path $stateDir
Ensure-Directory -Path $logsDir

$source = Normalize-ContextPathValue -PathValue $SourceFolder
if ([string]::IsNullOrWhiteSpace($source)) {
    Write-BenchLog -Line "STAGE_FAIL | Source path is empty"
    exit 1
}

try {
    $source = (Resolve-Path -LiteralPath $source -ErrorAction Stop).ProviderPath
}
catch {
    Write-BenchLog -Line ("STAGE_FAIL | Resolve failed | Source='{0}' | Error='{1}'" -f $source, $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    Write-BenchLog -Line ("STAGE_FAIL | Source is not folder | Source='{0}'" -f $source)
    exit 1
}

$payload = [ordered]@{
    source     = $source
    staged_utc = [DateTime]::UtcNow.ToString("o")
}

$json = $payload | ConvertTo-Json -Compress
Set-Content -LiteralPath $stageFile -Value $json -Encoding UTF8

Write-BenchLog -Line ("STAGE_OK | Source='{0}' | StageFile='{1}'" -f $source, $stageFile)
exit 0

