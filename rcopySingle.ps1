param(
    [Parameter(Position = 0)]
    [string]$Mode = "rc",
    [Parameter(Position = 1)]
    [string]$AnchorPath
)

[Console]::InputEncoding = [Text.UTF8Encoding]::UTF8
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$script:LogsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path -LiteralPath $script:LogsDir)) {
    New-Item -ItemType Directory -Path $script:LogsDir -Force | Out-Null
}
$script:StageLogPath = Join-Path $script:LogsDir "stage_log.txt"
$script:SelectionRetryCount = 10
$script:SelectionRetryDelayMs = 45
$script:SelectionStableHits = 2
$script:LargeSelectionTrustThreshold = 1000
$script:LargeSelectionStableHits = 2
$script:SelectAllTokenPrefix = "?WILDCARD?|"
$script:SelectAllTokenThreshold = 1000
$script:StageMutexName = "Global\MoveTo_RoboCopy_Stage"
$script:StageStateDir = Join-Path $PSScriptRoot "state"
$script:StageFilesDir = Join-Path $script:StageStateDir "staging"
$script:StageBackendDefault = "file"
$script:StageDebugMode = $false
$script:DesktopDirectEnterLogged = $false
$script:DesktopDirectNoSelectionLogged = $false

function Write-StageLog {
    param([string]$Message)
    try {
        $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
        Add-Content -LiteralPath $script:StageLogPath -Value $line -Encoding UTF8
    }
    catch { }
}

function Normalize-ContextPathValue {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $candidate = $PathValue.Trim()
    if ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

    if ($candidate -match '^[A-Za-z]:$') {
        return ($candidate + '\')
    }
    if ($candidate -match '^[A-Za-z]:\\\.$') {
        return ($candidate.Substring(0, 2) + '\')
    }
    if ($candidate.EndsWith('\.')) {
        return $candidate.Substring(0, $candidate.Length - 1)
    }
    return $candidate
}

function Resolve-NormalPath {
    param([string]$PathValue)

    $candidate = Normalize-ContextPathValue -PathValue $PathValue
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    try {
        return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
    }
    catch {
        return $null
    }
}

function Normalize-RawPathValue {
    param([string]$PathValue)

    return (Normalize-ContextPathValue -PathValue $PathValue)
}

function Test-IsSelectAllToken {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    return $PathValue.StartsWith($script:SelectAllTokenPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-SelectAllToken {
    param(
        [string]$SourceDirectory,
        [int]$SelectedCount = 0
    )

    if ([string]::IsNullOrWhiteSpace($SourceDirectory)) { return $null }
    if ($SelectedCount -gt 0) {
        return ("{0}{1}|{2}" -f $script:SelectAllTokenPrefix, $SelectedCount, $SourceDirectory)
    }
    return ("{0}{1}" -f $script:SelectAllTokenPrefix, $SourceDirectory)
}

function Get-SelectAllTokenPayload {
    param([string]$TokenPath)

    if (-not (Test-IsSelectAllToken -PathValue $TokenPath)) { return $null }
    $payload = $TokenPath.Substring($script:SelectAllTokenPrefix.Length)
    if ([string]::IsNullOrWhiteSpace($payload)) { return $null }

    $selectedCount = 0
    $sourceDirectory = $payload
    $parts = $payload.Split('|', 2)
    if ($parts.Count -eq 2 -and $parts[0] -match '^\d+$' -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
        try { $selectedCount = [int]$parts[0] } catch { $selectedCount = 0 }
        $sourceDirectory = $parts[1]
    }

    if ([string]::IsNullOrWhiteSpace($sourceDirectory)) { return $null }
    return [pscustomobject]@{
        SelectedCount   = $selectedCount
        SourceDirectory = $sourceDirectory
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

function Get-StageBackend {
    param([string]$ConfigPath)
    # Safety lock: stage backend is fixed to file.
    return "file"
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

function Get-ExplorerSelectionFromParentEnumerated {
    param(
        [string]$ParentPath,
        [string]$ParentNormalized,
        [string]$AnchorPath
    )

    $parentNormalized = Resolve-NormalPath -PathValue $ParentPath
    if (-not $parentNormalized) {
        $parentNormalized = $ParentNormalized
    }
    # Allow null parentNormalized — Pass 2 (Anchor Hunt) handles Desktop/virtual paths
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
                Write-StageDebugLog ("WindowScan | Scanned={0} | ParentMatches={1} | MatchFoundMs={2} | COM_EnumMs={3} | RawCount={4} | FolderCount={5} | FolderCountMs={6} | SelectAllHint={7} | AnchorHit={8} | CountOnlyMode={9}" -f $windowsScanned, $parentMatches, $scanMs, $enumMs, $current.Count, $folderItemCount, $folderCountMs, $selectAllHint, $anchorHit, $false)

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

        # Pass 2: Desktop Direct Access via FindWindowSW (SWC_DESKTOP=8)
        # Shell.Application.Windows() does NOT include the Desktop (Progman.exe).
        # We use ShellWindows COM CLSID + FindWindowSW to access it directly.
        # Trigger: no usable selection found (not just parentMatches=0), covers
        # edge case where Explorer window IS open at Desktop path but selection
        # is on the wallpaper Desktop (Progman), not in the Explorer window.
        if ($fallbackCount -le 0 -and -not [string]::IsNullOrWhiteSpace($anchorNormalized)) {
            if (-not $script:DesktopDirectEnterLogged) {
                Write-StageDebugLog "WindowScan | Entering Desktop Direct Access (FindWindowSW SWC_DESKTOP=8)"
                $script:DesktopDirectEnterLogged = $true
            }
            try {
                $desktopShellWindows = [Activator]::CreateInstance(
                    [Type]::GetTypeFromCLSID([guid]"9BA05972-F6A8-11CF-A442-00A0C90A8F39"))
                $desktopHwnd = [int]0
                $desktopBrowser = $desktopShellWindows.FindWindowSW(0, $null, 8, [ref]$desktopHwnd, 1)

                if ($desktopBrowser) {
                    $desktopDoc = $desktopBrowser.Document
                    if ($desktopDoc) {
                        $rawSelectedItems = @($desktopDoc.SelectedItems())
                        if ($rawSelectedItems.Count -gt 0) {
                            $current = New-Object System.Collections.Generic.List[string]
                            $anchorHit = $false
                            foreach ($entry in $rawSelectedItems) {
                                $entryPath = Normalize-RawPathValue -PathValue ([string]$entry.Path)
                                if (-not $entryPath) { continue }
                                [void]$current.Add($entryPath)
                                if ($entryPath.Equals($anchorNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                                    $anchorHit = $true
                                }
                            }

                            # Safety: anchor must be in selection AND all items share the same parent
                            if ($anchorHit -and $current.Count -gt 0) {
                                $anchorParentCheck = Split-Path -Path $anchorNormalized -Parent
                                $allSameParent = $true
                                foreach ($p in $current) {
                                    $itemParent = $null
                                    try { $itemParent = Split-Path -Path $p -Parent } catch { }
                                    if (-not $itemParent -or -not $itemParent.Equals($anchorParentCheck, [System.StringComparison]::OrdinalIgnoreCase)) {
                                        $allSameParent = $false
                                        break
                                    }
                                }
                                if ($allSameParent) {
                                    $scanTimer.Stop()
                                    Write-StageDebugLog ("WindowScanSummary | DesktopDirectSuccess | Count={0} | HWND={1} | TotalMs={2}" -f $current.Count, $desktopHwnd, [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds))
                                    return [string[]]$current.ToArray()
                                }
                                else {
                                    Write-StageDebugLog ("WindowScan | DesktopDirect | AnchorHit but mixed parents, rejected | Count={0}" -f $current.Count)
                                }
                            }
                            else {
                                Write-StageDebugLog ("WindowScan | DesktopDirect | AnchorMiss | Count={0} | AnchorHit={1}" -f $current.Count, $anchorHit)
                            }
                        }
                        else {
                            if (-not $script:DesktopDirectNoSelectionLogged) {
                                Write-StageDebugLog "WindowScan | DesktopDirect | No items selected on Desktop"
                                $script:DesktopDirectNoSelectionLogged = $true
                            }
                        }
                    }
                }
            }
            catch {
                Write-StageDebugLog ("WindowScan | DesktopDirect | ERROR: {0}" -f $_.Exception.Message)
            }
        }
    }
    catch { }

    $scanTimer.Stop()
    Write-StageDebugLog ("WindowScanSummary | Scanned={0} | ParentMatches={1} | SelectedItemsRead={2} | TotalMs={3} | FallbackCount={4}" -f $windowsScanned, $parentMatches, $totalSelectedItemsRead, [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds), $fallbackCount)
    return [string[]]$fallbackResults.ToArray()
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
    $matchingWindows = New-Object System.Collections.Generic.List[object]

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
                [void]$matchingWindows.Add([pscustomobject]@{
                    Document         = $doc
                    Folder           = $folder
                    WindowFolderPath = $windowFolderPath
                })
            }
            catch { }
        }
    }
    catch { }

    if ($matchingWindows.Count -eq 1) {
        $singleMatch = $matchingWindows[0]
        $scanMs = [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds)
        $folderItemCount = -1
        $selectedCount = -1
        $folderCountMs = -1
        $selectedCountMs = -1

        $folderCountTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try { $folderItemCount = [int]($singleMatch.Folder.Items().Count) } catch { $folderItemCount = -1 }
        $folderCountTimer.Stop()
        $folderCountMs = [int][Math]::Round($folderCountTimer.Elapsed.TotalMilliseconds)

        $selectedCountTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try { $selectedCount = [int]($singleMatch.Document.SelectedItems().Count) } catch { $selectedCount = -1 }
        $selectedCountTimer.Stop()
        $selectedCountMs = [int][Math]::Round($selectedCountTimer.Elapsed.TotalMilliseconds)

        $selectAllHint = ($folderItemCount -gt 0 -and $selectedCount -eq $folderItemCount)
        Write-StageDebugLog ("WindowScan | Scanned={0} | ParentMatches={1} | MatchFoundMs={2} | COM_EnumMs={3} | RawCount={4} | FolderCount={5} | FolderCountMs={6} | SelectedCountMs={7} | SelectAllHint={8} | AnchorHit={9} | CountOnlyMode={10}" -f $windowsScanned, $parentMatches, $scanMs, 0, $selectedCount, $folderItemCount, $folderCountMs, $selectedCountMs, $selectAllHint, "n/a", $true)

        if ($selectAllHint -and $selectedCount -ge $script:SelectAllTokenThreshold) {
            $sourcePath = Resolve-NormalPath -PathValue $singleMatch.WindowFolderPath
            if (-not $sourcePath) { $sourcePath = $singleMatch.WindowFolderPath }
                $token = New-SelectAllToken -SourceDirectory $sourcePath -SelectedCount $selectedCount
                if ($token) {
                    $scanTimer.Stop()
                    Write-StageDebugLog ("FastPath | SelectAllToken | Count={0} | Threshold={1} | Source='{2}'" -f $selectedCount, $script:SelectAllTokenThreshold, $sourcePath)
                    Write-StageDebugLog ("WindowScanSummary | Scanned={0} | ParentMatches={1} | SelectedItemsRead={2} | TotalMs={3} | Tokenized={4}" -f $windowsScanned, $parentMatches, 0, [int][Math]::Round($scanTimer.Elapsed.TotalMilliseconds), $true)
                    return @($token)
            }
        }
    }

    # Non-select-all path falls back to stable full enumeration logic.
    return @(Get-ExplorerSelectionFromParentEnumerated -ParentPath $ParentPath -ParentNormalized $parentNormalized -AnchorPath $AnchorPath)
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
        $hasSelectAllToken = ($currentPaths.Count -eq 1 -and (Test-IsSelectAllToken -PathValue $currentPaths[0]))
        $anchorHitCurrent = $false
        if ($hasSelectAllToken) {
            $anchorHitCurrent = $true
        }
        elseif (-not [string]::IsNullOrWhiteSpace($normalizedAnchor) -and $currentPaths.Count -gt 0) {
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

        if ($hasSelectAllToken) {
            Write-StageDebugLog ("FastPath | SelectAllTokenTrusted | Attempt={0} | Token='{1}'" -f $attempt, $currentPaths[0])
            break
        }

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

function Get-ExistingStageHeader {
    param(
        [ValidateSet("rc", "mv")][string]$CommandName
    )

    try {
        $stagedFile = Get-StagedJsonPath -CommandName $CommandName
        if (-not (Test-Path -LiteralPath $stagedFile)) { return $null }
        $reader = $null
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $reader = [System.IO.StreamReader]::new($stagedFile, $utf8NoBom)
            $headerLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($headerLine)) { return $null }
            if (-not $headerLine.StartsWith("V2|")) { return $null }
            $parts = $headerLine.Split("|")
            if ($parts.Count -lt 5) { return $null }
            $existExpected = 0
            try { $existExpected = [int]$parts[4] } catch { $existExpected = 0 }
            $existStageUtc = $null
            try { $existStageUtc = [DateTime]::Parse($parts[3], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
            return [pscustomobject]@{
                ExpectedCount = $existExpected
                SessionId     = $parts[2]
                LastStageUtc  = $existStageUtc
            }
        }
        finally {
            if ($reader) { $reader.Dispose() }
        }
    }
    catch { return $null }
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
        $registryExpectedCount = $expectedCount
        if ($expectedCount -eq 1 -and $uniquePaths.Count -eq 1 -and (Test-IsSelectAllToken -PathValue $uniquePaths[0])) {
            $tokenPayload = Get-SelectAllTokenPayload -TokenPath $uniquePaths[0]
            if ($tokenPayload -and $tokenPayload.SelectedCount -gt 1) {
                $registryExpectedCount = [int]$tokenPayload.SelectedCount
            }
        }
        $registryTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Save-StagedPathsToRegistry -CommandName $CommandName -Paths @() -AnchorParentNormalized $anchorParentNormalized -SessionId $sessionId -LastStageUtc $lastStageUtc -ExpectedCount $registryExpectedCount
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
        # Guard: if a valid multi-item stage already exists (recent), do NOT overwrite it.
        # This prevents late-arriving burst calls (after normal Ctrl+C deselects everything)
        # from clobbering a good multi-item stage with a single anchor fallback.
        $existingHeader = Get-ExistingStageHeader -CommandName $command
        if ($existingHeader -and $existingHeader.ExpectedCount -gt 1) {
            $stageAgeSec = -1
            if ($existingHeader.LastStageUtc) {
                $stageAgeSec = [int][Math]::Round(((Get-Date).ToUniversalTime() - $existingHeader.LastStageUtc).TotalSeconds)
            }
            if ($stageAgeSec -ge 0 -and $stageAgeSec -le 5) {
                $selectionTimer.Stop()
                $stageTimer.Stop()
                Write-StageDebugLog ("EmptySelectionGuard | ExistingExpected={0} | ExistingSession={1} | AgeSec={2} | Action='PreserveExisting'" -f $existingHeader.ExpectedCount, $existingHeader.SessionId, $stageAgeSec)
                Write-StageLog ("SKIP | mode={0} | anchor='{1}' | reason='empty-selection-guard' | existingExpected={2} | ageSec={3}" -f $command, $anchorResolved, $existingHeader.ExpectedCount, $stageAgeSec)
                exit 0
            }
        }
        $selectedPaths = @($anchorResolved)
    }
    elseif ($selectedPaths.Count -eq 1 -and -not (Test-IsSelectAllToken -PathValue $selectedPaths[0])) {
        $singleSelectedResolved = Resolve-NormalPath -PathValue $selectedPaths[0]
        if ([string]::IsNullOrWhiteSpace($singleSelectedResolved) -or -not [string]::Equals($singleSelectedResolved, $anchorResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-StageDebugLog ("SingleAnchorGuard | MismatchDetected=True | Anchor='{0}' | Selected='{1}' | Action='UseAnchor'" -f $anchorResolved, $selectedPaths[0])
            Write-StageLog ("WARN | mode={0} | single-selection mismatch | anchor='{1}' | selected='{2}' | action='use-anchor'" -f $command, $anchorResolved, $selectedPaths[0])
            $selectedPaths = @($anchorResolved)
        }
    }
    $selectionTimer.Stop()

    $saveResult = Save-StagedPaths -CommandName $command -Paths $selectedPaths -AnchorParentPath $parentPath -Backend $script:StageBackend
    $stageTimer.Stop()
    $selectionReadMs = [int][Math]::Round($selectionTimer.Elapsed.TotalMilliseconds)
    $totalStageMs = [int][Math]::Round($stageTimer.Elapsed.TotalMilliseconds)
    Write-StageLog ("OK | mode={0} | backend={1} | anchor='{2}' | selected={3} | total={4} | expected={5} | session={6} | SelectionReadMs={7} | DedupeMs={8} | PersistFileMs={9} | PersistRegistryMs={10} | TotalStageMs={11}" -f $command, $saveResult.Backend, $anchorResolved, $selectedPaths.Count, $saveResult.TotalItems, $saveResult.TotalItems, $saveResult.SessionId, $selectionReadMs, $saveResult.DedupeMs, $saveResult.PersistFileMs, $saveResult.PersistRegistryMs, $totalStageMs)

    $tokenizedMulti = $false
    if ($selectedPaths.Count -eq 1 -and (Test-IsSelectAllToken -PathValue $selectedPaths[0])) {
        $tokenPayload = Get-SelectAllTokenPayload -TokenPath $selectedPaths[0]
        if ($tokenPayload -and $tokenPayload.SelectedCount -gt 1) {
            $tokenizedMulti = $true
        }
    }

    if ($selectedPaths.Count -gt 1 -or $tokenizedMulti) {
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
