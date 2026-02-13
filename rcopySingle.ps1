param(
    [Parameter(Position = 0)]
    [string]$Mode = "rc",
    [Parameter(Position = 1)]
    [string]$AnchorPath
)

[Console]::InputEncoding = [Text.UTF8Encoding]::UTF8
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$script:StageLogPath = Join-Path $PSScriptRoot "stage_log.txt"
$script:SelectionRetryCount = 10
$script:SelectionRetryDelayMs = 45
$script:SelectionStableHits = 2
$script:LargeSelectionTrustThreshold = 1000
$script:LargeSelectionStableHits = 2
$script:StageMutexName = "Global\MoveTo_RoboCopy_Stage"
$script:StageStateDir = Join-Path $PSScriptRoot "state"
$script:StageFilesDir = Join-Path $script:StageStateDir "staging"
$script:StageBackendDefault = "file"
$script:StageDebugMode = $false

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

function Normalize-RawPathValue {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $candidate = $PathValue.Trim()
    if ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    return $candidate
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

function Get-StageDebugMode {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $false
    }

    try {
        $raw = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $data = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($data.PSObject.Properties.Name -contains "debug_mode") {
                try { return [bool]$data.debug_mode } catch { return $false }
            }
        }
    }
    catch { }

    return $false
}

function Write-StageDebugLog {
    param([string]$Message)
    if (-not $script:StageDebugMode) { return }
    Write-StageLog ("DEBUG | {0}" -f $Message)
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
    param(
        [string]$ParentPath,
        [string]$AnchorPath
    )

    $parentNormalized = Resolve-NormalPath -PathValue $ParentPath
    if (-not $parentNormalized) { return @() }
    $anchorNormalized = Resolve-NormalPath -PathValue $AnchorPath

    $fallbackResults = New-Object System.Collections.Generic.List[string]
    $fallbackCount = -1
    $windowsScanned = 0
    $parentMatches = 0
    $totalSelectedItemsRead = 0
    $scanTimer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in @($shell.Windows())) {
            $windowsScanned++
            try {
                if (-not $window) { continue }
                $doc = $window.Document
                if (-not $doc) { continue }
                $folder = $doc.Folder
                if (-not $folder) { continue }

                $windowFolderPath = [string]$folder.Self.Path
                if ([string]::IsNullOrWhiteSpace($windowFolderPath)) { continue }

                $windowMatchesParent = $false
                if ($windowFolderPath.Equals($ParentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $windowMatchesParent = $true
                }
                else {
                    $windowFolderNormalized = Resolve-NormalPath -PathValue $windowFolderPath
                    if (-not $windowFolderNormalized) { continue }
                    if ($windowFolderNormalized.Equals($parentNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $windowMatchesParent = $true
                    }
                }
                if (-not $windowMatchesParent) { continue }

                $parentMatches++
                $scanMs = [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds)

                $current = New-Object System.Collections.Generic.List[string]
                $anchorHit = $false
                $folderItemCount = -1
                $folderCountMs = -1
                if ($script:StageDebugMode) {
                    $folderCountTimer = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $folderItemCount = [int]($folder.Items().Count)
                    }
                    catch {
                        $folderItemCount = -1
                    }
                    $folderCountTimer.Stop()
                    $folderCountMs = [int][Math]::Round($folderCountTimer.Elapsed.TotalMilliseconds)
                }
                $enumTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $rawSelectedItems = @($doc.SelectedItems())
                $enumTimer.Stop()
                $enumMs = [int][Math]::Round($enumTimer.Elapsed.TotalMilliseconds)
                $totalSelectedItemsRead += $rawSelectedItems.Count

                foreach ($entry in $rawSelectedItems) {
                    $entryPath = Normalize-RawPathValue -PathValue ([string]$entry.Path)
                    if (-not $entryPath) { continue }
                    [void]$current.Add($entryPath)
                    if ($anchorNormalized -and $entryPath.Equals($anchorNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $anchorHit = $true
                    }
                }

                $selectAllHint = $false
                if ($folderItemCount -ge 0 -and $current.Count -gt 0 -and $current.Count -eq $folderItemCount) {
                    $selectAllHint = $true
                }
                Write-StageDebugLog ("WindowScan | Scanned={0} | ParentMatches={1} | MatchFoundMs={2} | COM_EnumMs={3} | RawCount={4} | FolderCount={5} | FolderCountMs={6} | SelectAllHint={7} | AnchorHit={8}" -f $windowsScanned, $parentMatches, $scanMs, $enumMs, $current.Count, $folderItemCount, $folderCountMs, $selectAllHint, $anchorHit)

                if ($anchorHit -and $current.Count -gt 0) {
                    $scanTimer.Stop()
                    Write-StageDebugLog ("WindowScanSummary | Scanned={0} | ParentMatches={1} | SelectedItemsRead={2} | TotalMs={3}" -f $windowsScanned, $parentMatches, $totalSelectedItemsRead, [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds))
                    return [string[]]$current.ToArray()
                }

                if ($current.Count -gt $fallbackCount) {
                    $fallbackCount = $current.Count
                    $fallbackResults = $current
                }
            }
            catch { }
        }
    }
    catch { }

    $scanTimer.Stop()
    Write-StageDebugLog ("WindowScanSummary | Scanned={0} | ParentMatches={1} | SelectedItemsRead={2} | TotalMs={3} | FallbackCount={4}" -f $windowsScanned, $parentMatches, $totalSelectedItemsRead, [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds), $fallbackCount)
    return [string[]]$fallbackResults.ToArray()
}

function Get-UniqueRawPaths {
    param([string[]]$Candidates)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in @($Candidates)) {
        $normalized = Normalize-RawPathValue -PathValue $candidate
        if (-not $normalized) { continue }
        if ($seen.Add($normalized)) {
            [void]$out.Add($normalized)
        }
    }

    return [string[]]$out.ToArray()
}

function Get-BestSelectionFromParent {
    param(
        [string]$ParentPath,
        [string]$AnchorPath
    )

    if ([string]::IsNullOrWhiteSpace($ParentPath)) { return @() }

    $bestPaths = @()
    $bestSignature = ""
    $stableHits = 0
    $normalizedAnchor = Normalize-RawPathValue -PathValue $AnchorPath
    $attemptsUsed = 0
    $selectionLoopTimer = [System.Diagnostics.Stopwatch]::StartNew()

    for ($attempt = 1; $attempt -le $script:SelectionRetryCount; $attempt++) {
        $attemptsUsed = $attempt
        $attemptTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $selectionCandidates = Get-ExplorerSelectionFromParent -ParentPath $ParentPath -AnchorPath $AnchorPath
        $currentPaths = @(Get-UniqueRawPaths -Candidates $selectionCandidates)
        $currentSignature = [string]::Join("`n", $currentPaths)
        $anchorHitCurrent = $false
        if (-not [string]::IsNullOrWhiteSpace($normalizedAnchor) -and $currentPaths.Count -gt 0) {
            foreach ($pathValue in $currentPaths) {
                if ([string]::Equals($pathValue, $normalizedAnchor, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $anchorHitCurrent = $true
                    break
                }
            }
        }
        $attemptTimer.Stop()
        $attemptMs = [int][Math]::Round($attemptTimer.Elapsed.TotalMilliseconds)

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

        Write-StageDebugLog ("SelectionAttempt | Attempt={0} | CandidateCount={1} | UniqueCount={2} | BestCount={3} | StableHits={4} | AnchorHit={5} | DurationMs={6}" -f $attempt, @($selectionCandidates).Count, $currentPaths.Count, $bestPaths.Count, $stableHits, $anchorHitCurrent, $attemptMs)

        if ($attempt -eq 1 -and $currentPaths.Count -ge $script:LargeSelectionTrustThreshold -and $anchorHitCurrent) {
            Write-StageDebugLog ("FastPath | LargeSelectionTrustedFirstScan | Count={0} | Threshold={1}" -f $currentPaths.Count, $script:LargeSelectionTrustThreshold)
            break
        }

        if ($bestPaths.Count -ge $script:LargeSelectionTrustThreshold -and $anchorHitCurrent -and $stableHits -ge $script:LargeSelectionStableHits) {
            Write-StageDebugLog ("FastPath | LargeSelectionTrusted | Count={0} | StableHits={1} | Threshold={2}" -f $bestPaths.Count, $stableHits, $script:LargeSelectionTrustThreshold)
            break
        }

        if ($bestPaths.Count -gt 1 -and $stableHits -ge $script:SelectionStableHits) {
            break
        }

        if ($attempt -lt $script:SelectionRetryCount) {
            Start-Sleep -Milliseconds $script:SelectionRetryDelayMs
        }
    }

    $selectionLoopTimer.Stop()
    Write-StageDebugLog ("SelectionSummary | Attempts={0} | FinalCount={1} | StableHits={2} | TotalLoopMs={3}" -f $attemptsUsed, $bestPaths.Count, $stableHits, [int][Math]::Round($selectionLoopTimer.Elapsed.TotalMilliseconds))
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
        [int]$ExpectedCount,
        [switch]$IncludeItems
    )

    $regPath = "Registry::HKEY_CURRENT_USER\RCWM\$CommandName"
    $uniquePaths = @($Paths)

    Clear-StagedRegistryKey -RegistryPath $regPath

    New-ItemProperty -LiteralPath $regPath -Name "__ready" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name "__expected_count" -PropertyType DWord -Value $ExpectedCount -Force | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name "__session_id" -PropertyType String -Value $SessionId -Force | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name "__last_stage_utc" -PropertyType String -Value $LastStageUtc -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($AnchorParentNormalized)) {
        New-ItemProperty -LiteralPath $regPath -Name "__anchor_parent" -PropertyType String -Value ($AnchorParentNormalized.ToLowerInvariant()) -Force | Out-Null
    }

    if ($IncludeItems) {
        for ($i = 0; $i -lt $ExpectedCount; $i++) {
            $valueName = "item_{0:D6}" -f ($i + 1)
            New-ItemProperty -LiteralPath $regPath -Name $valueName -PropertyType String -Value $uniquePaths[$i] -Force | Out-Null
        }
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
    $anchorValue = if ([string]::IsNullOrWhiteSpace($AnchorParentNormalized)) { "" } else { $AnchorParentNormalized.ToLowerInvariant() }
    $header = "V2|{0}|{1}|{2}|{3}|{4}" -f $CommandName, $SessionId, $LastStageUtc, $ExpectedCount, $anchorValue
    $lineCount = 1

    $stream = $null
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $stream = [System.IO.StreamWriter]::new($tempFile, $false, $utf8NoBom)
        $stream.WriteLine($header)
        foreach ($path in @($Paths)) {
            $normalized = Normalize-RawPathValue -PathValue $path
            if (-not $normalized) { continue }
            $stream.WriteLine($normalized)
            $lineCount++
        }
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }

    $tempBytes = 0
    try { $tempBytes = [int64](Get-Item -LiteralPath $tempFile -ErrorAction Stop).Length } catch { $tempBytes = 0 }
    $moveTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Move-Item -LiteralPath $tempFile -Destination $stagedFile -Force
    $moveTimer.Stop()
    $finalBytes = 0
    try { $finalBytes = [int64](Get-Item -LiteralPath $stagedFile -ErrorAction Stop).Length } catch { $finalBytes = 0 }
    Write-StageDebugLog ("StageWriteSummary | Command={0} | Lines={1} | TempBytes={2} | FinalBytes={3} | AtomicMoveMs={4}" -f $CommandName, $lineCount, $tempBytes, $finalBytes, [int][Math]::Round($moveTimer.Elapsed.TotalMilliseconds))
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
    $dedupeTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $uniquePaths = @(Get-UniqueRawPaths -Candidates ([string[]]$pathList))
    $dedupeTimer.Stop()

    $sessionId = [Guid]::NewGuid().ToString("N")
    $expectedCount = @($uniquePaths).Count
    $lastStageUtc = (Get-Date).ToUniversalTime().ToString("o")
    $anchorParentNormalized = Resolve-NormalPath -PathValue $AnchorParentPath

    $persistFileMs = 0
    $persistRegistryMs = 0

    if ($Backend -eq "registry") {
        $registryTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Save-StagedPathsToRegistry -CommandName $CommandName -Paths $uniquePaths -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $expectedCount -IncludeItems
        $registryTimer.Stop()
        $persistRegistryMs = [int][Math]::Round($registryTimer.Elapsed.TotalMilliseconds)
    }
    else {
        $fileTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Save-StagedPathsToFile -CommandName $CommandName -Paths $uniquePaths -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $expectedCount
        $fileTimer.Stop()
        $persistFileMs = [int][Math]::Round($fileTimer.Elapsed.TotalMilliseconds)

        # Keep registry metadata in sync for VBS burst-suppression checks.
        $registryTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Save-StagedPathsToRegistry -CommandName $CommandName -Paths @() -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $expectedCount
        $registryTimer.Stop()
        $persistRegistryMs = [int][Math]::Round($registryTimer.Elapsed.TotalMilliseconds)
    }

    return [pscustomobject]@{
        Backend          = $Backend
        SessionId        = $sessionId
        TotalItems       = $expectedCount
        LastStageUtc     = $lastStageUtc
        DedupeMs         = [int][Math]::Round($dedupeTimer.Elapsed.TotalMilliseconds)
        PersistFileMs    = $persistFileMs
        PersistRegistryMs = $persistRegistryMs
    }
}

$command = if ($Mode -and $Mode.ToLowerInvariant() -eq "mv") { "mv" } else { "rc" }
$configPath = Join-Path $PSScriptRoot "RoboTune.json"
$script:StageBackend = Get-StageBackend -ConfigPath $configPath
$script:StageDebugMode = Get-StageDebugMode -ConfigPath $configPath
$anchorResolved = Resolve-NormalPath -PathValue $AnchorPath
if (-not $anchorResolved) {
    Write-StageLog ("ERROR | mode={0} | unresolved anchor='{1}'" -f $command, $AnchorPath)
    exit 1
}

$stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
$mutex = New-Object System.Threading.Mutex($false, $script:StageMutexName)
$hasLock = $false
try {
    $hasLock = $mutex.WaitOne(5000)
    if (-not $hasLock) {
        Write-StageLog ("WARN | mode={0} | mutex timeout for anchor='{1}'" -f $command, $anchorResolved)
        exit 1
    }

    $parentPath = Get-AnchorParentPath -PathValue $anchorResolved
    $selectionTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $selectedPaths = @(Get-BestSelectionFromParent -ParentPath $parentPath -AnchorPath $anchorResolved)
    if ($selectedPaths.Count -eq 0) {
        $selectedPaths = @($anchorResolved)
    }
    $selectionTimer.Stop()

    $saveResult = Save-StagedPaths -CommandName $command -Paths $selectedPaths -AnchorParentPath $parentPath -Backend $script:StageBackend
    $stageTimer.Stop()
    $selectionReadMs = [int][Math]::Round($selectionTimer.Elapsed.TotalMilliseconds)
    $totalStageMs = [int][Math]::Round($stageTimer.Elapsed.TotalMilliseconds)
    Write-StageLog ("OK | mode={0} | backend={1} | anchor='{2}' | selected={3} | total={4} | expected={5} | session={6} | SelectionReadMs={7} | DedupeMs={8} | PersistFileMs={9} | PersistRegistryMs={10} | TotalStageMs={11}" -f $command, $saveResult.Backend, $anchorResolved, $selectedPaths.Count, $saveResult.TotalItems, $saveResult.TotalItems, $saveResult.SessionId, $selectionReadMs, $saveResult.DedupeMs, $saveResult.PersistFileMs, $saveResult.PersistRegistryMs, $totalStageMs)

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
