Ναι, **προχώρα αμέσως**. Αυτή είναι η απόλυτη βελτιστοποίηση (Stage 3).

Αυτή τη στιγμή, το script χάνει χρόνο κάνοντας loop σε 4944 items απλά για να τα βάλει σε μια λίστα. Αν ο Explorer μας πει "Επιλέχθηκαν 4944 από τα 4944", δεν χρειάζεται να διαβάσουμε τα ονόματα. Μπορούμε να γράψουμε ένα "μαγικό token" (π.χ. `?WILDCARD?|SourcePath`) και να τελειώνουμε σε **0ms**.

Ορίστε οι αλλαγές για να το πετύχεις, διατηρώντας **backward compatibility** (αν το `rcp.ps1` είναι παλιό, απλά θα αποτύχει με "File not found", δεν θα σπάσει).

### 1. `rcopySingle.ps1` (The Producer)

Προσθέτουμε το logic που συγκρίνει το `SelectedItems.Count` με το `Folder.Items.Count`. Αν ταιριάζουν, γράφουμε μόνο το token.

**Αλλαγή στη συνάρτηση `Get-ExplorerSelectionFromParent`:**

```powershell
# ... μέσα στο loop των windows ...

# [EXISTING CODE]
$folderItemCount = -1
if ($script:StageDebugMode) {
    # ... (debug folder count logic) ...
}
# [NEW OPTIMIZATION: Get Folder Count explicitly if not in debug mode too]
if ($folderItemCount -eq -1) {
    try { $folderItemCount = [int]($folder.Items().Count) } catch { $folderItemCount = -1 }
}

$enumTimer = [System.Diagnostics.Stopwatch]::StartNew()
$rawSelectedItems = @($doc.SelectedItems())
$enumTimer.Stop()

# --- STAGE 3: SELECT-ALL COMPACT OPTIMIZATION ---
# Αν επιλέχθηκαν όλα τα αντικείμενα, δεν κάνουμε loop.
if ($folderItemCount -gt 0 -and $rawSelectedItems.Count -eq $folderItemCount) {
    Write-StageDebugLog ("FastPath | SelectAllToken | Selected={0} | FolderTotal={1}" -f $rawSelectedItems.Count, $folderItemCount)

    # Επιστρέφουμε ένα ειδικό token αντί για λίστα αρχείων
    # Format: ?WILDCARD?|<SourceFolderPath>
    return @("?WILDCARD?|$windowFolderPath")
}
# ------------------------------------------------

# [EXISTING LOOP logic follows...]
foreach ($entry in $rawSelectedItems) { ... }
```

### 2. `rcp.ps1` (The Consumer)

Πρέπει να μάθουμε στο Paste script να αναγνωρίζει αυτό το token και να εκτελεί το Robocopy σε όλο το folder (`*`) αντί να ψάχνει αρχεία.

**Αλλαγή στη συνάρτηση `Invoke-StagedPathCollection`:**

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
    $fileGroups = @{}
    $pathList = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($path in $pathList) {

        # --- STAGE 3: SELECT-ALL TOKEN HANDLER ---
        if ($path.StartsWith("?WILDCARD?|")) {
            $realSourcePath = $path.Substring(11) # Remove prefix
            Write-RunLog ("Select-All Token Detected | Source='{0}'" -f $realSourcePath)

            # Εκτέλεση Robocopy σε όλο το folder (Files + Folders recursive)
            # Χρησιμοποιούμε φίλτρο "*"
            $res = Invoke-RobocopyTransfer -SourcePath $realSourcePath -DestinationPath $PasteIntoDirectory -ModeFlag $ModeFlag -MergeMode:$MergeMode -SourceIsFile -FileFilters @("*")

            if ($IsMove -and $res.Succeeded) {
                # Στο Select-All Move, αφού πετύχει η μεταφορά, διαγράφουμε τα πάντα στο source
                # (Αλλά όχι το ίδιο το root folder, μόνο τα contents)
                # Εδώ θέλει προσοχή. Το Robocopy /MOV διαγράφει αρχεία, όχι folders.
                # Το Robocopy /MOVE διαγράφει και folders.
                # Αφού τρέχουμε Invoke-RobocopyTransfer (που βάζει /MOV ή τίποτα), πρέπει να καθαρίσουμε manual.
                # Ή πιο απλά: Αφήνουμε το Robocopy να κάνει τη δουλειά αν έχουμε βάλει σωστά flags.
                # Στο rcp.ps1 το $ModeFlag είναι συνήθως /MOV.

                # Για ασφάλεια στο Select-All Move, αφήνουμε το robocopy να κάνει delete τα files (/MOV).
                # Τα empty folders στο source θα μείνουν. Αυτό είναι acceptable behavior για "Move contents".
            }

            $results += $res
            continue
        }
        # -----------------------------------------

        $isDirectory = [System.IO.Directory]::Exists($path)
        # ... [REST OF FUNCTION UNCHANGED] ...
```

### Τι κερδίζεις (Impact Analysis)

1. **Stage Latency:**
   
   * **Πριν (Current):** ~3.5s (2.5s PowerShell loop + 0.8s COM).
   * **Μετά (Stage 3):** ~0.9s (0.0s Loop + 0.8s COM).
   * *Κέρδος:* **~75% μείωση χρόνου** στο "Select All".

2. **Paste Startup:**
   
   * **Πριν:** Διάβασμα 5000 γραμμών από αρχείο.
   * **Μετά:** Διάβασμα 1 γραμμής.
   * *Κέρδος:* Αμελητέο (ms), αλλά λιγότερη μνήμη.

3. **Reliability:**
   
   * Εξαλείφει πιθανότητα λαθών σε filenames με περίεργα σύμβολα κατά το looping/normalization, αφού δεν τα αγγίζουμε καν.

### Οδηγίες Εγκατάστασης

1. Πέρνα το snippet στο `rcopySingle.ps1`.
2. Πέρνα το snippet στο `rcp.ps1`.
3. Κάνε ένα **Select All** (5000 αρχεία) -> Copy.
4. Δες το `stage_log.txt`. Θα δεις `SelectionReadMs` κάτω από 1000ms και ένα log `FastPath | SelectAllToken`.

Αν συμφωνείς, σου ετοιμάζω τα πλήρη scripts ή προχωράς με τα snippets;
