# Desktop Multi-Select Bug — Root Cause & Fix

## The Bug

Όταν κάνεις **multi-select** σε αρχεία **απευθείας στο Desktop** και δεξί κλικ → Robo-Copy/Robo-Cut, το script κάνει stage **μόνο 1 αρχείο** (το anchor). Σε κανονικούς φακέλους (ακόμα και μέσα σε `Desktop\subfolder`) δουλεύει σωστά.

---

## Root Cause Analysis

### Πώς δουλεύει η selection capture

Το `rcopySingle.ps1` χρησιμοποιεί αυτό το flow:

```
VBS wrapper → rcopySingle.ps1 → Get-BestSelectionFromParent()
  → Get-ExplorerSelectionFromParent()
    → Get-ExplorerSelectionFromParentEnumerated()
      → Shell.Application.Windows() ← ΕΔΏΣ ΕΙΝΑΙ ΤΟ ΠΡΟΒΛΗΜΑ
```

### Τι κάνει ο κώδικας

1. Παίρνει το **anchor path** (το αρχείο που πάτησες δεξί κλικ)
2. Βρίσκει τον **parent folder** (`D:\Users\joty79\Desktop`)
3. Καλεί `Shell.Application.Windows()` για να πάρει τη λίστα ανοιχτών παραθύρων
4. Ψάχνει ποιο παράθυρο έχει `Folder.Self.Path == parent folder`
5. Από αυτό τραβάει τα `SelectedItems()`

### Γιατί αποτυγχάνει στο Desktop

**`Shell.Application.Windows()` ΔΕΝ περιλαμβάνει τo Desktop.**

Τo Desktop στα Windows δεν είναι ένα κανονικό Explorer window. Είναι hosted στο **`Progman.exe`** (Program Manager) — ένα ειδικό shell window που δεν εγγράφεται στη `ShellWindows` collection.

**Diagnostic απόδειξη:**
```
Shell.Application.Windows() returned:
  [0] Name='Robocopy'        | FolderPath='D:\Users\joty79\scripts\Robocopy'
  [1] Name='RoboCopyContext'  | FolderPath='C:\Users\joty79\AppData\Local\RoboCopyContext'
  [2] Name='Linux (L:)'      | FolderPath='L:\'
  [3] Name='logs'             | FolderPath='...\RoboCopyContext\logs'

  → Desktop: NOWHERE TO BE FOUND
```

**Αποτέλεσμα:** `parentMatches = 0`, `selectedItems = 0`, fallback στο anchor μόνο → **1 αρχείο**.

### Γιατί ο Codex fix (Anchor Hunt) δεν δούλεψε

Ο Codex πρόσθεσε ένα "Pass 2" που σκάναρε **ΟΛΑ** τα `Shell.Application.Windows()` ψάχνοντας τo anchor. Αλλά αφού τo Desktop ΔΕΝ είναι στα `Windows()`, σκάναρε τα ίδια 3-4 windows ξανά, με αποτέλεσμα `SelectedItemsRead = 0` πάλι.

**Τo πρόβλημα δεν ήταν algorithmic — ήταν API-level.** Δεν υπάρχει τρόπος να βρεις τo Desktop μέσω `Shell.Application.Windows()`.

---

## The Fix

### Τι API χρειάζεται

Τo Desktop shell view είναι προσβάσιμο **μόνο** μέσω:

```powershell
# ShellWindows COM CLSID + FindWindowSW(SWC_DESKTOP=8)
$sw = [Activator]::CreateInstance(
    [Type]::GetTypeFromCLSID([guid]"9BA05972-F6A8-11CF-A442-00A0C90A8F39"))
$hwnd = [int]0
$desktop = $sw.FindWindowSW(0, $null, 8, [ref]$hwnd, 1)
# $desktop.Document.SelectedItems() → ΤΑ SELECTED ΑΡΧΕΙΑ ΤΟΥ DESKTOP!
```

**Παράμετροι:**
- CLSID `9BA05972-F6A8-11CF-A442-00A0C90A8F39` = `ShellWindows` COM class
- `FindWindowSW(pvarloc=0, pvarlocRoot=$null, swClass=8, phwnd=[ref], swfwOptions=1)`
  - `pvarloc=0` → CSIDL_DESKTOP
  - `swClass=8` → SWC_DESKTOP (ψάξε ειδικά τo Desktop window)
  - `swfwOptions=1` → SWFO_NEEDDISPATCH (γύρνα IDispatch object)

### Τι άλλαξε στο `rcopySingle.ps1`

**2 αλλαγές:**

#### Αλλαγή 1: Αφαίρεση early-return guard (line ~203)

**Πριν:**
```powershell
$parentNormalized = Resolve-NormalPath -PathValue $ParentPath
if (-not $parentNormalized) {
    $parentNormalized = $ParentNormalized
}
if (-not $parentNormalized) { return @() }  # ← ΑΥΤΟ ΣΚΟΤΩΝΕ ΤΑ ΠΑΝΤΑ
```

**Μετά:**
```powershell
$parentNormalized = Resolve-NormalPath -PathValue $ParentPath
if (-not $parentNormalized) {
    $parentNormalized = $ParentNormalized
}
# Allow null parentNormalized — Pass 2 handles Desktop/virtual paths
```

Χωρίς αυτό, η function έκανε return πριν φτάσει στο Pass 2.

#### Αλλαγή 2: Pass 2 — Desktop Direct Access (μετά τo Pass 1 loop)

Προστέθηκε μετά τo Pass 1 `foreach` loop, μέσα στο `Get-ExplorerSelectionFromParentEnumerated`:

```powershell
# Pass 2: Desktop Direct Access via FindWindowSW (SWC_DESKTOP=8)
# Shell.Application.Windows() does NOT include the Desktop (Progman.exe).
# We use ShellWindows COM CLSID + FindWindowSW to access it directly.
if ($parentMatches -eq 0 -and -not [string]::IsNullOrWhiteSpace($anchorNormalized)) {
    Write-StageDebugLog "WindowScan | Entering Desktop Direct Access (FindWindowSW SWC_DESKTOP=8)"
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
                    }
                }
            }
        }
    }
    catch {
        Write-StageDebugLog ("WindowScan | DesktopDirect | ERROR: {0}" -f $_.Exception.Message)
    }
}
```

### Safety Guards

1. **`$parentMatches -eq 0`** — Pass 2 τρέχει **ΜΟΝΟ** αν κανένα κανονικό window δεν κάνει match (Desktop case). Κανονικοί φάκελοι δεν επηρεάζονται.

2. **Anchor validation** — Τo anchor file (αυτό που πάτησε δεξί κλικ ο χρήστης) πρέπει να υπάρχει μέσα στα selected items.

3. **Same-parent check** — ΟΛΑ τα selected items πρέπει να μοιράζονται τον ίδιο parent directory. Αποτρέπει "pollution" από τυχαίες selections σε άλλα windows.

### Performance Impact

- **Κανονικοί φάκελοι:** Pass 1 βρίσκει match → return αμέσως. Pass 2 **ΔΕΝ εκτελείται**.
- **Desktop:** Pass 1 fails (0 matches) → Pass 2 κάνει **1 COM call** (~10-30ms). Πριν τo fix, αποτύγχανε μετά από 10 retries × 45ms delay = **~700ms** waste.

---

## Test Results

### Desktop Multi-Select (THE BUG — FIXED)
```
DesktopDirectSuccess | Count=3 | HWND=262444 | TotalMs=28
selected=3 | total=3 | expected=3
```

### Normal Folder (Regression Check — NO ISSUES)
Κανονικοί φάκελοι συνεχίζουν να δουλεύουν μέσω Pass 1 χωρίς αλλαγή.

---

## Why Codex Couldn't Fix This

1. **Wrong assumption:** Ο Codex νόμιζε ότι τo Desktop υπάρχει στα `Shell.Application.Windows()` αλλά με λάθος path. Στην πραγματικότητα **δεν υπάρχει καθόλου**.

2. **API limitation, not algorithm:** Τo fix του Codex (Anchor Hunt σε όλα τα windows) ψέχνε στα ίδια 3-4 windows ξανά και ξανά. Τo Desktop απλά δεν ήταν εκεί.

3. **Χρειαζόταν εντελώς διαφορετικό API:** `ShellWindows.FindWindowSW(SWC_DESKTOP=8)` — ένα COM call που δεν είναι exposed μέσω `Shell.Application` αλλά μόνο μέσω τον `ShellWindows` CLSID `9BA05972-F6A8-11CF-A442-00A0C90A8F39`.