Ακριβώς. Το Codex έχει απόλυτο δίκιο.
Η προηγούμενη υλοποίηση (answer5) έκανε το λάθος να τραβάει τα δεδομένα (`@($doc.SelectedItems())`) **πριν** αποφασίσει αν θα τα αγνοήσει, ακυρώνοντας το κέρδος σε μνήμη/χρόνο.

Πάμε για την **Safe Stage 3** υλοποίηση.

### Τι αλλάζουμε:

1. **Stage (`rcopySingle.ps1`)**: Ελέγχουμε τα Counts (`Folder.Items.Count` vs `SelectedItems.Count`) **χωρίς** να διαβάσουμε τα filenames. Αν ταιριάζουν, στέλνουμε το Token και φεύγουμε αμέσως.
2. **Paste (`rcp.ps1`)**: Αναγνωρίζουμε το Token και εκτελούμε **ένα** Robocopy job για όλο το φάκελο (`*`), αντί να σπάμε σε batches.

Ορίστε οι αλλαγές για τα δύο scripts.

---

### 1. `rcopySingle.ps1` (Hardened FastPath)

Αντικατέστησε τη συνάρτηση `Get-ExplorerSelectionFromParent` με αυτήν.

* **Hardening:** Χρησιμοποιεί το `Count` κατευθείαν από το COM Object (χωρίς `@(...)` array conversion) για μηδενικό overhead.

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

                # Parent Path Match Check
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

                # --- SAFE STAGE 3: FAST COUNT CHECK ---
                # Check counts directly via COM (no array overhead)
                try {
                    $comFolderItems = $folder.Items()
                    $comSelectedItems = $doc.SelectedItems()

                    $totalCount = $comFolderItems.Count
                    $selectedCount = $comSelectedItems.Count

                    # Guard: Only trust if counts match, are > 0, and anchor exists in window path
                    # (Simple heuristic: if window path is parent of anchor, we are safe)
                    if ($totalCount -gt 0 -and $selectedCount -eq $totalCount) {
                        $anchorCheck = $false
                        if ($anchorNormalized.StartsWith($windowFolderPath, [System.StringComparison]::OrdinalIgnoreCase) -or 
                            $anchorNormalized.StartsWith($windowFolderNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $anchorCheck = $true
                        }

                        if ($anchorCheck) {
                            $scanTimer.Stop()
                            Write-StageDebugLog ("FastPath | SelectAllToken | Selected={0} | FolderTotal={1} | Window={2}" -f $selectedCount, $totalCount, $windowFolderPath)
                            # Return the Safe Token
                            return @("?WILDCARD?|$windowFolderPath")
                        }
                    }
                }
                catch {
                    Write-StageDebugLog ("WARN | FastPath Check Failed | {0}" -f $_.Exception.Message)
                }
                # --------------------------------------

                # Fallback to standard enumeration if not Select-All
                $current = New-Object System.Collections.Generic.List[string]
                $anchorHit = $false

                $enumTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $rawSelectedItems = @($doc.SelectedItems()) # Explicit enumeration
                $enumTimer.Stop()

                $totalSelectedItemsRead += $rawSelectedItems.Count

                foreach ($entry in $rawSelectedItems) {
                    $entryPath = Normalize-RawPathValue -PathValue ([string]$entry.Path)
                    if (-not $entryPath) { continue }
                    [void]$current.Add($entryPath)
                    if ($anchorNormalized -and $entryPath.Equals($anchorNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $anchorHit = $true
                    }
                }

                if ($anchorHit -and $current.Count -gt 0) {
                    $scanTimer.Stop()
                    # Debug log unchanged...
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
    return [string[]]$fallbackResults.ToArray()
}
```

---

### 2. `rcp.ps1` (Token Consumer)

Αντικατέστησε τη συνάρτηση `Invoke-StagedPathCollection`.

* **Logic:** Αν βρει το Token, τρέχει Robocopy με `*` και `/E`. Αν είναι Move mode, προσθέτει `/MOVE` (Files AND Dirs), που είναι πιο γρήγορο από το `/MOV` + `Remove-Item` loop.

```powershell
function Invoke-StagedPathCollection {
    param(
        [string[]]$Paths,
        [string]$PasteIntoDirectory,
        [string]$ModeFlag,
        [bool]$IsMove,
        [switch]$MergeMode,
        [string]$ActionLabel
    )

    $results = @()

    # --- SAFE STAGE 3: TOKEN HANDLER ---
    # Check if the first path is our special wildcard token
    $firstPath = if ($Paths.Count -gt 0) { $Paths[0] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($firstPath) -and $firstPath.StartsWith("?WILDCARD?|")) {
        $sourceDir = $firstPath.Substring(11) # Strip prefix

        Write-RunLog ("Select-All Token Detected | Source='{0}' | PasteInto='{1}' | IsMove={2}" -f $sourceDir, $PasteIntoDirectory, $IsMove)

        if (-not (Test-Path -LiteralPath $sourceDir)) {
             Write-Host "Source directory from token not found: $sourceDir" -ForegroundColor Red
             return @()
        }

        # Strategy: Use Robocopy * /E to copy everything.
        # If Move mode, use /MOVE (Move files AND dirs) to let Robocopy handle cleanup efficiently.
        $tokenModeFlag = $ModeFlag
        if ($IsMove) {
            # Replace /MOV (files only) with /MOVE (files and dirs) for full folder move
            if ($tokenModeFlag -match "/MOV") {
                $tokenModeFlag = $tokenModeFlag -replace "/MOV", "/MOVE"
            } elseif ($tokenModeFlag -notmatch "/MOVE") {
                $tokenModeFlag += " /MOVE"
            }
        }

        $res = Invoke-RobocopyTransfer -SourcePath $sourceDir -DestinationPath $PasteIntoDirectory -ModeFlag $tokenModeFlag -MergeMode:$MergeMode -SourceIsFile -FileFilters @("*")

        if ($res) { $results += $res }
        if ($ActionLabel) {
            Write-Output ("Finished {0} all items from '{1}'" -f $ActionLabel, (Split-Path $sourceDir -Leaf))
        }
        return @($results)
    }
    # -----------------------------------

    # [EXISTING LOGIC FOR NORMAL SELECTIONS]
    $fileGroups = @{}
    $pathList = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($path in $pathList) {
        $isDirectory = [System.IO.Directory]::Exists($path)
        $isFile = $false
        if (-not $isDirectory) {
            $isFile = [System.IO.File]::Exists($path)
        }

        if (-not $isDirectory -and -not $isFile) {
            Write-Host "Source item '$path' does not exist." -ForegroundColor Yellow
            continue
        }

        if ($isDirectory) {
            $transfer = Invoke-StagedTransfer -SourcePath $path -PasteIntoDirectory $PasteIntoDirectory -ModeFlag $ModeFlag -IsMove:$IsMove -MergeMode:$MergeMode
            if ($transfer.Result) {
                $results += $transfer.Result
            }
            if ($ActionLabel) {
                Write-Output ("Finished {0} {1}" -f $ActionLabel, $transfer.ItemName)
            }
            continue
        }

        $sourceDirectory = Split-Path -Path $path -Parent
        if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
            Write-Host "Cannot resolve source directory for file '$path'." -ForegroundColor Red
            continue
        }

        if (-not $fileGroups.ContainsKey($sourceDirectory)) {
            $fileGroups[$sourceDirectory] = New-Object System.Collections.Generic.List[string]
        }
        [void]$fileGroups[$sourceDirectory].Add($path)
    }

    foreach ($sourceDirectory in @($fileGroups.Keys | Sort-Object)) {
        $fileBatch = Invoke-StagedFileBatchTransfer -FilePaths ([string[]]$fileGroups[$sourceDirectory].ToArray()) -PasteIntoDirectory $PasteIntoDirectory -ModeFlag $ModeFlag -IsMove:$IsMove -MergeMode:$MergeMode
        if ($fileBatch -and $fileBatch.Results) {
            $results += @($fileBatch.Results)
        }
        if ($ActionLabel -and $fileBatch.ItemName) {
            Write-Output ("Finished {0} {1}" -f $ActionLabel, $fileBatch.ItemName)
        }
    }

    return @($results)
}
```

### Verification (Τι να περιμένεις)

1. **Select All** (5000 items) -> Right Click -> Copy.
2. **Stage Log:** Θα πρέπει να δεις `FastPath | SelectAllToken` και `TotalStageMs` < 1000ms.
3. **Paste Log:** Θα πρέπει να δεις `Select-All Token Detected`.
4. **Robocopy:** Θα τρέξει **μία** φορά με arguments `* /E` (ή `* /E /MOVE` στο Cut).

Αυτό είναι το πιο ασφαλές και γρήγορο μονοπάτι για μαζική επιλογή.
