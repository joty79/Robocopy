param(
    [Parameter(Position = 0)]
    [string]$Mode = "rc",
    [Parameter(Position = 1)]
    [string]$AnchorPath
)

[Console]::InputEncoding = [Text.UTF8Encoding]::UTF8
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$script:StageLogPath = Join-Path $PSScriptRoot "stage_log.txt"
$script:SelectionRetryCount = 18
$script:SelectionRetryDelayMs = 85
$script:SelectionStableHits = 3
$script:StageMutexName = "Global\MoveTo_RoboCopy_Stage"
$script:StageStateDir = Join-Path $PSScriptRoot "state"
$script:StageFilesDir = Join-Path $script:StageStateDir "staging"
$script:StageBackendDefault = "file"

function Write-StageLog {
    param([string]$Message)
    try {
        $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
        Add-Content -LiteralPath $script:StageLogPath -Value $line -Encoding UTF8
    }
    catch { }
}

function Resolve-NormalPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    try {
        return (Resolve-Path -LiteralPath $PathValue -ErrorAction Stop).ProviderPath
    }
    catch {
        return $null
    }
}

function Ensure-StageStateDirectories {
    try {
        if (-not (Test-Path -LiteralPath $script:StageStateDir)) {
            New-Item -ItemType Directory -Path $script:StageStateDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:StageFilesDir)) {
            New-Item -ItemType Directory -Path $script:StageFilesDir -Force | Out-Null
        }
    }
    catch { }
}

function Normalize-StageBackend {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -in @("file", "registry")) { return $normalized }
    return $null
}

function Get-StageBackend {
    param([string]$ConfigPath)

    $backend = Normalize-StageBackend -Value $script:StageBackendDefault
    if (-not $backend) { $backend = "file" }

    $envBackend = Normalize-StageBackend -Value $env:RCWM_STAGE_BACKEND
    if ($envBackend) { return $envBackend }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $backend
    }

    try {
        $raw = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $data = $raw | ConvertFrom-Json -ErrorAction Stop
            $cfgBackend = Normalize-StageBackend -Value ([string]$data.stage_backend)
            if ($cfgBackend) {
                return $cfgBackend
            }
        }
    }
    catch { }

    return $backend
}

function Get-StagedJsonPath {
    param([ValidateSet("rc", "mv")][string]$CommandName)

    return (Join-Path $script:StageFilesDir ("{0}.stage.json" -f $CommandName))
}

function Get-AnchorParentPath {
    param([string]$PathValue)

    $resolved = Resolve-NormalPath -PathValue $PathValue
    if (-not $resolved) { return $null }

    try {
        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $parent = Split-Path -Path $resolved -Parent
            if ([string]::IsNullOrWhiteSpace($parent)) { return $resolved }
            return $parent
        }
        return (Split-Path -Path $resolved -Parent)
    }
    catch {
        return $null
    }
}

function Get-ExplorerSelectionFromParent {
    param([string]$ParentPath)

    $parentNormalized = Resolve-NormalPath -PathValue $ParentPath
    if (-not $parentNormalized) { return @() }

    $results = New-Object System.Collections.Generic.List[string]

    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in @($shell.Windows())) {
            try {
                if (-not $window) { continue }
                $doc = $window.Document
                if (-not $doc) { continue }
                $folder = $doc.Folder
                if (-not $folder) { continue }

                $windowFolderPath = [string]$folder.Self.Path
                if ([string]::IsNullOrWhiteSpace($windowFolderPath)) { continue }

                $windowFolderNormalized = Resolve-NormalPath -PathValue $windowFolderPath
                if (-not $windowFolderNormalized) { continue }

                if (-not $windowFolderNormalized.Equals($parentNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                foreach ($entry in @($doc.SelectedItems())) {
                    $entryPath = [string]$entry.Path
                    if (-not [string]::IsNullOrWhiteSpace($entryPath)) {
                        [void]$results.Add($entryPath)
                    }
                }

                if ($results.Count -gt 0) { break }
            }
            catch { }
        }
    }
    catch { }

    return [string[]]$results.ToArray()
}

function Get-UniqueExistingPaths {
    param([string[]]$Candidates)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in @($Candidates)) {
        $resolved = Resolve-NormalPath -PathValue $candidate
        if (-not $resolved) { continue }
        if ($seen.Add($resolved)) {
            [void]$out.Add($resolved)
        }
    }

    return [string[]]$out.ToArray()
}

function Get-BestSelectionFromParent {
    param([string]$ParentPath)

    if ([string]::IsNullOrWhiteSpace($ParentPath)) { return @() }

    $bestPaths = @()
    $bestSignature = ""
    $stableHits = 0

    for ($attempt = 1; $attempt -le $script:SelectionRetryCount; $attempt++) {
        $selectionCandidates = Get-ExplorerSelectionFromParent -ParentPath $ParentPath
        $currentPaths = @(Get-UniqueExistingPaths -Candidates $selectionCandidates)
        $currentSignature = [string]::Join("`n", $currentPaths)

        if ($currentPaths.Count -gt $bestPaths.Count) {
            $bestPaths = $currentPaths
            $bestSignature = $currentSignature
            $stableHits = 1
        }
        elseif ($currentPaths.Count -eq $bestPaths.Count -and $currentPaths.Count -gt 0) {
            if ($currentSignature -eq $bestSignature) {
                $stableHits++
            }
            else {
                $bestPaths = $currentPaths
                $bestSignature = $currentSignature
                $stableHits = 1
            }
        }

        if ($bestPaths.Count -gt 1 -and $stableHits -ge $script:SelectionStableHits) {
            break
        }

        if ($attempt -lt $script:SelectionRetryCount) {
            Start-Sleep -Milliseconds $script:SelectionRetryDelayMs
        }
    }

    return @($bestPaths)
}

function Clear-StagedRegistryKey {
    param([string]$RegistryPath)

    try {
        if (Test-Path -LiteralPath $RegistryPath) {
            Remove-Item -LiteralPath $RegistryPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $RegistryPath -Force | Out-Null
    }
    catch { }
}

function Save-StagedPathsToRegistry {
    param(
        [ValidateSet("rc", "mv")]
        [string]$CommandName,
        [string[]]$Paths,
        [string]$AnchorParentNormalized,
        [string]$SessionId,
        [string]$LastStageUtc,
        [int]$ExpectedCount
    )

    $regPath = "Registry::HKEY_CURRENT_USER\RCWM\$CommandName"
    $uniquePaths = @($Paths)

    Clear-StagedRegistryKey -RegistryPath $regPath

    New-ItemProperty -LiteralPath $regPath -Name "__ready" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name "__expected_count" -PropertyType DWord -Value $ExpectedCount -Force | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name "__session_id" -PropertyType String -Value $SessionId -Force | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name "__last_stage_utc" -PropertyType String -Value $LastStageUtc -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($anchorParentNormalized)) {
        New-ItemProperty -LiteralPath $regPath -Name "__anchor_parent" -PropertyType String -Value ($anchorParentNormalized.ToLowerInvariant()) -Force | Out-Null
    }

    for ($i = 0; $i -lt $ExpectedCount; $i++) {
        $valueName = "item_{0:D6}" -f ($i + 1)
        New-ItemProperty -LiteralPath $regPath -Name $valueName -PropertyType String -Value $uniquePaths[$i] -Force | Out-Null
    }

    New-ItemProperty -LiteralPath $regPath -Name "__ready" -PropertyType DWord -Value 1 -Force | Out-Null
}

function Save-StagedPathsToFile {
    param(
        [ValidateSet("rc", "mv")]
        [string]$CommandName,
        [string[]]$Paths,
        [string]$AnchorParentNormalized,
        [string]$SessionId,
        [string]$LastStageUtc,
        [int]$ExpectedCount
    )

    Ensure-StageStateDirectories

    $stagedFile = Get-StagedJsonPath -CommandName $CommandName
    $tempFile = "{0}.{1}.tmp" -f $stagedFile, ([Guid]::NewGuid().ToString("N"))
    $payload = [ordered]@{
        version        = 1
        backend        = "file"
        command        = $CommandName
        ready          = $true
        expected_count = $ExpectedCount
        session_id     = $SessionId
        last_stage_utc = $LastStageUtc
        anchor_parent  = if ([string]::IsNullOrWhiteSpace($AnchorParentNormalized)) { $null } else { $AnchorParentNormalized.ToLowerInvariant() }
        items          = @($Paths)
    }

    $json = $payload | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $tempFile -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tempFile -Destination $stagedFile -Force
}

function Save-StagedPaths {
    param(
        [ValidateSet("rc", "mv")]
        [string]$CommandName,
        [string[]]$Paths,
        [string]$AnchorParentPath,
        [ValidateSet("file", "registry")]
        [string]$Backend = "file"
    )

    $pathList = if ($null -eq $Paths) { @() } elseif ($Paths -is [string]) { @($Paths) } else { @($Paths) }
    $uniquePaths = @(Get-UniqueExistingPaths -Candidates ([string[]]$pathList))
    $sessionId = [Guid]::NewGuid().ToString("N")
    $expectedCount = @($uniquePaths).Count
    $lastStageUtc = (Get-Date).ToUniversalTime().ToString("o")
    $anchorParentNormalized = Resolve-NormalPath -PathValue $AnchorParentPath

    if ($Backend -eq "registry") {
        Save-StagedPathsToRegistry -CommandName $CommandName -Paths $uniquePaths -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $expectedCount
    }
    else {
        Save-StagedPathsToFile -CommandName $CommandName -Paths $uniquePaths -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $expectedCount
        # Keep registry metadata in sync for VBS burst-suppression checks.
        Save-StagedPathsToRegistry -CommandName $CommandName -Paths $uniquePaths -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $expectedCount
    }

    return [pscustomobject]@{
        Backend       = $Backend
        SessionId     = $sessionId
        TotalItems    = $expectedCount
        LastStageUtc  = $lastStageUtc
    }
}

$command = if ($Mode -and $Mode.ToLowerInvariant() -eq "mv") { "mv" } else { "rc" }
$script:StageBackend = Get-StageBackend -ConfigPath (Join-Path $PSScriptRoot "RoboTune.json")
$anchorResolved = Resolve-NormalPath -PathValue $AnchorPath
if (-not $anchorResolved) {
    Write-StageLog ("ERROR | mode={0} | unresolved anchor='{1}'" -f $command, $AnchorPath)
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, $script:StageMutexName)
$hasLock = $false
try {
    $hasLock = $mutex.WaitOne(5000)
    if (-not $hasLock) {
        Write-StageLog ("WARN | mode={0} | mutex timeout for anchor='{1}'" -f $command, $anchorResolved)
        exit 1
    }

    $parentPath = Get-AnchorParentPath -PathValue $anchorResolved
    $selectedPaths = @(Get-BestSelectionFromParent -ParentPath $parentPath)

    if ($selectedPaths.Count -eq 0) {
        $selectedPaths = @($anchorResolved)
    }

    $saveResult = Save-StagedPaths -CommandName $command -Paths $selectedPaths -AnchorParentPath $parentPath -Backend $script:StageBackend
    Write-StageLog ("OK | mode={0} | backend={1} | anchor='{2}' | selected={3} | total={4} | expected={5} | session={6}" -f $command, $saveResult.Backend, $anchorResolved, $selectedPaths.Count, $saveResult.TotalItems, $saveResult.TotalItems, $saveResult.SessionId)

    if ($selectedPaths.Count -gt 1) {
        exit 10
    }
    exit 0
}
finally {
    if ($hasLock) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
