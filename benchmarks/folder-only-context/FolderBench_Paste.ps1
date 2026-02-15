param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$DestinationFolder
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

function Pause-End {
    Write-Host ""
    Write-Host "Press Enter to close..."
    [void](Read-Host)
}

Ensure-Directory -Path $stateDir
Ensure-Directory -Path $logsDir

$destination = Normalize-ContextPathValue -PathValue $DestinationFolder
if ([string]::IsNullOrWhiteSpace($destination)) {
    Write-Host "Destination path is empty." -ForegroundColor Red
    Write-BenchLog -Line "PASTE_FAIL | Destination path is empty"
    Pause-End
    exit 1
}

if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
    Write-Host ("Destination folder not found: {0}" -f $destination) -ForegroundColor Red
    Write-BenchLog -Line ("PASTE_FAIL | Destination not found | Dest='{0}'" -f $destination)
    Pause-End
    exit 1
}

if (-not (Test-Path -LiteralPath $stageFile -PathType Leaf)) {
    Write-Host "No staged folder. Use 'Robo-Folder-Copy (Temp)' first." -ForegroundColor Yellow
    Write-BenchLog -Line "PASTE_FAIL | No stage file"
    Pause-End
    exit 1
}

$raw = Get-Content -LiteralPath $stageFile -Raw -ErrorAction Stop
$data = $raw | ConvertFrom-Json -ErrorAction Stop
$source = Normalize-ContextPathValue -PathValue ([string]$data.source)

if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Container)) {
    Write-Host ("Staged source folder is invalid: {0}" -f $source) -ForegroundColor Red
    Write-BenchLog -Line ("PASTE_FAIL | Invalid staged source | Source='{0}'" -f $source)
    Pause-End
    exit 1
}

$leafName = Split-Path -Leaf ($source.TrimEnd('\'))
if ([string]::IsNullOrWhiteSpace($leafName)) {
    Write-Host ("Cannot derive source folder name from: {0}" -f $source) -ForegroundColor Red
    Write-BenchLog -Line ("PASTE_FAIL | Cannot derive leaf | Source='{0}'" -f $source)
    Pause-End
    exit 1
}

$target = Join-Path $destination $leafName

$sourceNorm = ($source.TrimEnd('\')).ToLowerInvariant()
$targetNorm = ($target.TrimEnd('\')).ToLowerInvariant()
if ($sourceNorm -eq $targetNorm) {
    Write-Host "Source and target are the same path. Aborting." -ForegroundColor Yellow
    Write-BenchLog -Line ("PASTE_FAIL | SamePath | Source='{0}' | Target='{1}'" -f $source, $target)
    Pause-End
    exit 1
}

Write-Host "Temp folder benchmark mode"
Write-Host ("Source:      {0}" -f $source) -ForegroundColor Gray
Write-Host ("Destination: {0}" -f $target) -ForegroundColor Gray
Write-Host ""

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$robocopyArgs = @(
    $source,
    $target,
    "/E",
    "/R:1",
    "/W:1",
    "/MT:48",
    "/NP"
)

Write-BenchLog -Line ("PASTE_START | Source='{0}' | Target='{1}'" -f $source, $target)
$null = (& C:\Windows\System32\robocopy.exe @robocopyArgs | Out-Null)
$exitCode = $LASTEXITCODE
$sw.Stop()

$ok = ($exitCode -lt 8)
if ($ok) {
    Remove-Item -LiteralPath $stageFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($ok) {
    Write-Host ("Result: OK (ExitCode={0}) | Time={1}s" -f $exitCode, [Math]::Round($sw.Elapsed.TotalSeconds, 3)) -ForegroundColor Green
} else {
    Write-Host ("Result: FAIL (ExitCode={0}) | Time={1}s" -f $exitCode, [Math]::Round($sw.Elapsed.TotalSeconds, 3)) -ForegroundColor Red
}

Write-BenchLog -Line ("PASTE_END | ExitCode={0} | ElapsedMs={1} | Source='{2}' | Target='{3}'" -f $exitCode, [int]$sw.Elapsed.TotalMilliseconds, $source, $target)
Pause-End
exit $exitCode
