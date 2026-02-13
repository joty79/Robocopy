Yes, those markers are **exactly** what you need. They will tell you if the 6.7 seconds is spent *finding* the window or *extracting* the list from the window.

I would add **one specific extra marker**:

* **Raw COM Enumeration Time:** Inside the loop where we touch `$doc.SelectedItems()`. This is usually the specific API call that hangs when Explorer is busy.

Here is the updated code for `rcopySingle.ps1` with the requested telemetry added.

### 1. Update `Get-ExplorerSelectionFromParent`

*Adds timing for finding the window vs. reading the items.*

```powershell
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
    $scanTimer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = @($shell.Windows())

        foreach ($window in $windows) {
            $windowsScanned++
            try {
                if (-not $window) { continue }
                $doc = $window.Document
                if (-not $doc) { continue }
                $folder = $doc.Folder
                if (-not $folder) { continue }

                $windowFolderPath = [string]$folder.Self.Path
                if ([string]::IsNullOrWhiteSpace($windowFolderPath)) { continue }

                # Optimization: Simple string check before expensive resolve
                if (-not $windowFolderPath.Equals($ParentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    # If strings don't match, check resolved path just in case
                    $windowFolderNormalized = Resolve-NormalPath -PathValue $windowFolderPath
                    if (-not $windowFolderNormalized) { continue }
                    if (-not $windowFolderNormalized.Equals($parentNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                }

                # --- HIT FOUND ---
                $scanMs = $scanTimer.ElapsedMilliseconds

                # Measure the raw COM enumeration cost
                $enumTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $current = New-Object System.Collections.Generic.List[string]
                $anchorHit = $false
                $rawItems = @($doc.SelectedItems()) # <--- This is the heavy COM call

                foreach ($entry in $rawItems) {
                    $entryPath = Normalize-RawPathValue -PathValue ([string]$entry.Path)
                    if (-not $entryPath) { continue }
                    [void]$current.Add($entryPath)
                    if ($anchorNormalized -and $entryPath.Equals($anchorNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $anchorHit = $true
                    }
                }
                $enumTimer.Stop()

                Write-StageLog ("DEBUG | WindowScan | Scanned={0} | MatchFoundMs={1} | COM_EnumMs={2} | RawCount={3} | AnchorHit={4}" -f $windowsScanned, $scanMs, $enumTimer.ElapsedMilliseconds, $current.Count, $anchorHit)

                if ($anchorHit -and $current.Count -gt 0) {
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

    return [string[]]$fallbackResults.ToArray()
}
```

### 2. Update `Get-BestSelectionFromParent`

*Adds retry attemp logging and the "Trust Threshold" optimization.*

```powershell
function Get-BestSelectionFromParent {
    param(
        [string]$ParentPath,
        [string]$AnchorPath
    )

    if ([string]::IsNullOrWhiteSpace($ParentPath)) { return @() }

    $bestPaths = @()
    $bestSignature = ""
    $stableHits = 0
    $trustThreshold = 500 # If we see this many files, trust it immediately (skip retries)

    $loopTimer = [System.Diagnostics.Stopwatch]::StartNew()

    for ($attempt = 1; $attempt -le $script:SelectionRetryCount; $attempt++) {
        $attemptTimer = [System.Diagnostics.Stopwatch]::StartNew()

        $selectionCandidates = Get-ExplorerSelectionFromParent -ParentPath $ParentPath -AnchorPath $AnchorPath
        $currentPaths = @(Get-UniqueRawPaths -Candidates $selectionCandidates)
        $currentSignature = [string]::Join("`n", $currentPaths)

        $attemptTimer.Stop()
        $attemptMs = $attemptTimer.ElapsedMilliseconds

        # Logic to determine best fit
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

        Write-StageLog ("DEBUG | SelectionAttempt | Attempt={0} | Count={1} | StableHits={2} | DurationMs={3}" -f $attempt, $currentPaths.Count, $stableHits, $attemptMs)

        # OPTIMIZATION: Trust large selections immediately
        if ($bestPaths.Count -ge $trustThreshold) {
            Write-StageLog ("DEBUG | FastPath | Large selection detected ({0} items). Skipping stability checks." -f $bestPaths.Count)
            break
        }

        if ($bestPaths.Count -gt 1 -and $stableHits -ge $script:SelectionStableHits) {
            break
        }

        if ($attempt -lt $script:SelectionRetryCount) {
            Start-Sleep -Milliseconds $script:SelectionRetryDelayMs
        }
    }

    $loopTimer.Stop()
    Write-StageLog ("DEBUG | SelectionSummary | TotalAttempts={0} | FinalCount={1} | TotalLoopMs={2}" -f $attempt, $bestPaths.Count, $loopTimer.ElapsedMilliseconds)

    return @($bestPaths)
}
```

### What to look for in the new logs:

1. **COM_EnumMs**: If this is ~2000ms, then Explorer is just slow at handing over the list. We cannot fix Explorer, but the "Trust Threshold" ($bestPaths.Count -ge 500) will ensure we only pay that penalty **once** instead of 3 times.
2. **MatchFoundMs**: If this is high, it means iterating through open windows is slow (rare, unless you have 50+ folders open).
3. **TotalLoopMs**: This should drop significantly with the new code.
