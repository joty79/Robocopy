# PROJECT_RULES (Robocopy)

## Scope
- Standalone `Robocopy` context-menu workflow στο `D:\Users\joty79\scripts\Robocopy`.
- Core execution split:
  - `rcopySingle.ps1` = stage
  - `rcp.ps1` = paste engine
  - `RoboCopy_Silent.vbs` / `RoboPaste_Admin.vbs` = wrappers

## Critical Decisions

### 2026-02-13 - Stage bottleneck optimization (large multi-selection)
- Problem:
  - Μεγάλο stage latency σε 1000+ items πριν ξεκινήσει το paste/robocopy.
- Root cause:
  - Heavy per-item filesystem checks (`Resolve-Path`/`Test-Path`) στο stage.
  - `ConvertTo-Json` serialization cost για μεγάλα payloads.
  - Duplicate full registry item writes ενώ backend είναι `file`.
- Guardrail / Rule:
  - Stage γράφει raw deduped paths γρήγορα (lazy validation).
  - Deep existence/type checks γίνονται στο paste phase.
  - `file` backend κάνει metadata-only registry sync.
  - Paste reader είναι dual-format (`V2` flat + legacy JSON fallback) για compatibility.
- Files affected:
  - `rcopySingle.ps1`
  - `rcp.ps1`
  - `README.md`
- Validation/tests run:
  - Parse validation για `rcopySingle.ps1` και `rcp.ps1` μέσω `scriptblock` compile check.
  - Full runtime matrix tests: pending.

### 2026-02-13 - Selection debug telemetry + safe large-selection fastpath
- Problem:
  - Μετά το Stage 1, bottleneck παρέμεινε στο `SelectionReadMs` (Explorer COM selection enumeration).
- Root cause:
  - Το κόστος είναι κυρίως στο COM `SelectedItems()` και στα retry attempts του selection loop.
- Guardrail / Rule:
  - Debug markers γράφονται μόνο όταν `debug_mode=true` από `RoboTune.json`.
  - Large-selection fastpath ενεργοποιείται με safety gate (threshold + stable hits), όχι blind one-shot trust.
- Files affected:
  - `rcopySingle.ps1`
- Validation/tests run:
  - Parse validation `rcopySingle.ps1` μέσω `scriptblock` compile check.
  - Runtime verification pending (με νέα debug logs σε real selection tests).

### 2026-02-13 - Stage 2 trust-first-scan for large selections
- Problem:
  - Σε very large selections (~5000) το 2nd stability scan διπλασιάζει το `SelectionReadMs`.
- Root cause:
  - Selection loop έκανε δεύτερο full COM pass για stability confirmation.
- Guardrail / Rule:
  - Αν `Attempt=1` και `Count >= threshold` και `AnchorHit=true`, γίνεται immediate trust/break.
  - Για μη-large ή μη-anchor-hit cases, διατηρείται το υπάρχον stability logic.
- Files affected:
  - `rcopySingle.ps1`
- Validation/tests run:
  - Parse validation `rcopySingle.ps1` μέσω `scriptblock` compile check.
  - Runtime verification pending (με νέα `FastPath | LargeSelectionTrustedFirstScan` logs).

### 2026-02-13 - Trust threshold tuning + select-all telemetry
- Problem:
  - Χρειαζόμαστε πιο conservative fastpath για reliability και data για πιθανό future select-all shortcut.
- Root cause:
  - Threshold `500` ήταν πιο επιθετικό από το target usage.
  - Δεν υπήρχε telemetry για `SelectedCount vs FolderCount`.
- Guardrail / Rule:
  - `LargeSelectionTrustThreshold` αυξήθηκε σε `1000`.
  - Νέα `WindowScan` debug fields: `FolderCount`, `FolderCountMs`, `SelectAllHint`.
  - Το επιπλέον count telemetry τρέχει μόνο όταν `debug_mode=true`.
- Files affected:
  - `rcopySingle.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcopySingle.ps1` μέσω `scriptblock` compile check.
  - Runtime verification pending με νέο debug run.

### 2026-02-13 - Safe Stage 3 select-all token path
- Problem:
  - Ακόμα και με Stage 2, το full item enumeration στο `SelectedItems()` παραμένει bottleneck για very large `Select All` selections.
- Root cause:
  - Materialization χιλιάδων selected paths πριν το stage write.
- Guardrail / Rule:
  - `rcopySingle.ps1` κάνει count-only fast check (`Folder.Items().Count` vs `SelectedItems().Count`) και tokenizes μόνο σε:
    - single parent-match window
    - select-all hint true
    - count >= `SelectAllTokenThreshold`
  - Token format: `?WILDCARD?|<selectedCount>|<sourceDir>`.
  - `rcp.ps1` καταναλώνει token μέσω dedicated path (full-folder transfer, όχι file-filter path).
  - Move token path αναβαθμίζει `/MOV` -> `/MOVE` για να καθαρίζονται και folders.
  - Για file backend, registry metadata mirror κρατά `expected_count` από token selectedCount για burst suppression compatibility.
  - Stage multi-exit (`10`) παραμένει ενεργό και για tokenized multi-selections.
- Files affected:
  - `rcopySingle.ps1`
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation για `rcopySingle.ps1` και `rcp.ps1` μέσω `scriptblock` compile check.
  - Runtime verification pending (token path telemetry σε stage/run logs).

### 2026-02-13 - Token move flag canonicalization fix
- Problem:
  - Στο tokenized move εμφανίστηκε invalid robocopy args: `"/MOV /MOVE"` (ExitCode 16).
- Root cause:
  - Mode flag replacement στο token path δεν canonicalized σωστά τα move tokens.
- Guardrail / Rule:
  - Στο token consumer γίνεται tokenization των flags και αφαιρούνται πάντα `/MOV` και `/MOVE` πριν compose.
  - Για move token path προστίθεται μόνο ένα canonical `/MOVE`.
- Files affected:
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` μέσω `scriptblock` compile check.
  - Runtime verification pending (Robo-Cut select-all token path).

### 2026-02-13 - Stage 3 non-select-all fallback fix
- Problem:
  - Μετά το Stage 3, non-select-all multi selections έβγαζαν `NoListAvailable`/stage timeout.
- Root cause:
  - Το νέο count-only Stage 3 flow επηρέασε αρνητικά το normal enumeration path.
- Guardrail / Rule:
  - `Select All` συνεχίζει με count-only token fastpath.
  - Όταν **δεν** είναι select-all, γίνεται explicit fallback σε dedicated legacy enumeration helper.
  - Κανόνας: speed optimizations μόνο σε token case, stable path για normal selections.
- Files affected:
  - `rcopySingle.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcopySingle.ps1` μέσω `scriptblock` compile check.
  - Runtime verification pending (small/mid multi-select from same folder).

### 2026-02-13 - Token move duplicate-target cleanup fix
- Problem:
  - Σε tokenized `Robo-Cut` (select-all), όταν target είχε ήδη same files, κάποια source files έμεναν πίσω.
- Root cause:
  - Το `/MOVE` διαγράφει μόνο files που θεωρήθηκαν copied· same files μπορεί να θεωρηθούν skipped.
- Guardrail / Rule:
  - Στο tokenized move path προστίθεται και `/IS` μαζί με canonical `/MOVE`.
  - Έτσι same-name/same-content files μπαίνουν στο transfer set και καθαρίζονται από source.
- Files affected:
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Runtime verification pending (select-all cut προς folder με already-existing identical files).

### 2026-02-13 - Token move argument packing hotfix (`/MOVE /IS`)
- Problem:
  - Σε select-all token move, ο robocopy έβγαζε `Invalid Parameter ... "/MOVE /IS"` (ExitCode 16).
- Root cause:
  - Τα move flags περνούσαν σαν joined string και σε ορισμένα paths αντιμετωπίζονταν ως single argument αντί για ξεχωριστά tokens.
- Guardrail / Rule:
  - Προστέθηκε κεντρικό `Get-ModeFlagTokens` normalization helper.
  - `Invoke-RobocopyTransfer` πλέον δέχεται mode flags ως `object` (string ή array) και κάνει πάντα token split πριν το argument build.
  - Το token move path περνάει mode flags ως token array (όχι joined string).
- Files affected:
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` μέσω `Parser::ParseFile` (`OK`).
  - Runtime verification pending (Robo-Cut select-all token path με same target folder).

### 2026-02-13 - Debug logging call hotfix (`Write-DebugMarker`)
- Problem:
  - Σε paste run με `DebugMode=True`, το `rcp.ps1` έσκαγε με `The term 'Write-DebugMarker' is not recognized`.
- Root cause:
  - Προστέθηκε debug call σε function που δεν υπάρχει στο `rcp.ps1` (υπάρχει μόνο στο stage script).
- Guardrail / Rule:
  - Στο `rcp.ps1` όλα τα debug telemetry writes περνούν από `Write-RunLog` με πρόθεμα `DEBUG |`.
- Files affected:
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` μέσω `Parser::ParseFile` (`OK`).

### 2026-02-13 - Preserve source root folder in tokenized select-all move
- Problem:
  - Σε `Robo-Cut` select-all μέσα από folder, το source root folder μπορούσε να διαγραφεί όταν άδειαζε.
- Root cause:
  - Το tokenized move path εκτελεί robocopy στο source directory με `/MOVE`, που μπορεί να αφαιρέσει και το root source folder όταν μείνει empty.
- Guardrail / Rule:
  - Πριν το tokenized move, δημιουργείται προσωρινό keep-root marker file στο source root.
  - Στα mode flags προστίθεται `/XF <marker>` ώστε να μη μετακινηθεί αυτό το file και να μην αδειάσει πλήρως ο root folder.
  - Μετά το transfer, το marker file αφαιρείται (`finally` cleanup), ώστε να μένει ο original source folder άδειος αλλά ίδιος (χωρίς delete/recreate reorder).
- Files affected:
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` μέσω `Parser::ParseFile` (`OK`).
  - Runtime verification pending (select-all cut από source folder, επιβεβαίωση ότι ο source folder διατηρεί θέση/identity).
