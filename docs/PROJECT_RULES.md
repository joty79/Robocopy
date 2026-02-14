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

### 2026-02-13 - Centralize runtime logs under `logs\`
- Problem:
  - Τα runtime logs γράφονταν στο repo root, κάνοντας το workspace noisy και το housekeeping δύσκολο.
- Root cause:
  - `rcp.ps1`/`rcopySingle.ps1` είχαν hardcoded log paths στο `$PSScriptRoot` root.
- Guardrail / Rule:
  - Όλα τα runtime logs γράφονται πλέον σε dedicated `logs\` folder με auto-create:
    - `logs\stage_log.txt`
    - `logs\run_log.txt`
    - `logs\error_log.txt`
    - `logs\robocopy_debug.log`
  - `README.md` και `RoboTune.ps1` δείχνουν πλέον στα νέα log paths.
- Files affected:
  - `rcopySingle.ps1`
  - `rcp.ps1`
  - `RoboTune.ps1`
  - `README.md`
  - `.gitignore`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation (`rcopySingle.ps1`, `rcp.ps1`) via `Parser::ParseFile` (`OK`).

### 2026-02-14 - Context menu grouping fix (`Robo-Cut/Copy/Paste`)
- Problem:
  - `Robo-Cut`/`Robo-Copy` και `Robo-Paste` εμφανίζονταν σε διαφορετικά blocks, άρα το group ordering ήταν ασταθές.
- Root cause:
  - Τα verbs ήταν split σε διαφορετικά registry parent branches (`AllFilesystemObjects` vs `Directory`).
- Guardrail / Rule:
  - Για files: verbs στο `HKCU\Software\Classes\*\shell`.
  - Για folders: related verbs στο ίδιο `HKCU\Software\Classes\Directory\shell`.
  - Για `Directory\Background`: μόνο `Paste`.
  - Πάντα cleanup των παλιών Robo keys πριν νέο import.
- Files affected:
  - `RoboCopy_StandAlone.reg`
  - `docs/CONTEXT_MENU_GROUPING_FIX.md`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Runtime menu verification: pending (Explorer restart + visual ordering check).

### 2026-02-14 - Installer v1 (per-user, directory-independent)
- Problem:
  - Runtime depended on hardcoded source-repo paths, making fresh-machine setup fragile.
- Root cause:
  - `.vbs` wrappers and `.reg` commands pointed to fixed `D:\Users\joty79\scripts\Robocopy` paths.
- Guardrail / Rule:
  - Install/update/uninstall is handled by `Install.ps1`.
  - Per-user install root is `%LOCALAPPDATA%\RoboCopyContext`.
  - Registry writes are dynamic under `HKCU\Software\Classes\...` (cleanup-first + read-back verification).
  - Missing `wt.exe` must fall back to elevated `pwsh.exe` paste launcher.
  - One-time migration from legacy root copies config/logs but skips `state\staging\*.stage.json`.
- Files affected:
  - `Install.ps1`
  - `README.md`
  - `docs/INSTALLER.md`
  - `state/install-meta.json`
  - `assets/Cut.ico`
  - `assets/Copy.ico`
  - `assets/Paste.ico`
- Validation/tests run:
  - Parse validation for `Install.ps1` via `Parser::ParseFile` (`OK`).
  - Runtime install/update/uninstall matrix: pending.

### 2026-02-14 - Installer registry/powershell hotfix pack
- Problem:
  - Installer εμφάνιζε registry warnings/mismatches και σε failure paths εμφανίζονταν key names (`Y_10_RoboCut`) αντί για `MUIVerb`.
  - Εμφανίστηκαν PowerShell binding errors σε empty-string values κατά το registry write.
- Root cause:
  - Stale Robo keys υπήρχαν και σε `HKCR` merged view, όχι μόνο σε `HKCU\Software\Classes`.
  - Empty-string args (`/d ""`) σε native `reg.exe` invocation περνούσαν σε strict parameter signatures που δεν δέχονταν empty tokens.
  - Mandatory string params χωρίς `[AllowEmptyString()]` έσκαγαν σε legitimate empty registry values.
- Guardrail / Rule:
  - Context-menu cleanup πρέπει να διαγράφει **και** `HKCU` **και** `HKCR` variants.
  - Για wildcard shell branches (`*\shell`, `Directory\shell`) προτιμάμε `reg.exe` add/query/delete για deterministic behavior.
  - Empty-compatible parameters δηλώνονται με `[AllowEmptyString()]`.
  - Native argument lists με empty data χρησιμοποιούν safe literal handling (όχι raw empty token).
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
  - `D:\Users\joty79\.codex\AGENTS.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`OK`).
  - Registry state verified with direct `reg query` checks on `HKCU`/`HKCR` Robo keys.

### 2026-02-14 - Installer GitHub package source mode
- Problem:
  - Χρειαζόμαστε install/update χωρίς local source checkout, απευθείας από remote repo.
- Root cause:
  - Ο installer v1 βασιζόταν μόνο σε local `SourcePath`.
- Guardrail / Rule:
  - Νέο package source model στο `Install.ps1`:
    - `Local` (default) -> deploy from local source.
    - `GitHub` -> download archive (repo/ref ή explicit zip URL), extract σε temp root, validate required runtime files, deploy, cleanup temp.
  - Νέα actions:
    - `InstallGitHub`
    - `UpdateGitHub`
  - Interactive menu περιλαμβάνει και GitHub install/update επιλογές.
- Files affected:
  - `Install.ps1`
  - `README.md`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - GitHub installer robustness hotfix (archive root + optional RoboTune.json)
- Problem:
  - `InstallGitHub` έσκαγε με:
    - `The property 'Count' cannot be found...` (single extracted root object).
    - `Downloaded package is missing required file: RoboTune.json`.
- Root cause:
  - Root detection assumed collection semantics (`.Count`) instead of normalized array.
  - `RoboTune.json` ήταν treated ως hard-required package file, ενώ μπορεί να λείπει από clean repo states.
- Guardrail / Rule:
  - Archive root detection uses normalized array (`@(...)`) and searches candidate extracted folders for a valid package root (`Install.ps1` + `rcp.ps1`).
  - `RoboTune.json` is optional in source package; installer auto-creates default config if missing.
- Files affected:
  - `Install.ps1`
  - `README.md`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Installer metadata backward-compat hotfix (`Add-Member` upsert)
- Problem:
  - `InstallGitHub` failed on old `install-meta.json` with:
    - `The property 'package_source' cannot be found on this object`.
- Root cause:
  - Με `Set-StrictMode`, direct assignment σε νέα metadata fields αποτυγχάνει όταν το loaded JSON object δεν έχει τα νέα properties.
- Guardrail / Rule:
  - Metadata writes γίνονται με safe upsert helper:
    - αν property λείπει -> `Add-Member`
    - αλλιώς update existing value
  - Default metadata schema περιλαμβάνει πλέον:
    - `package_source`
    - `github_repo`
    - `github_ref`
    - `github_zip_url`
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Installer runtime fix for metadata source_path assignment
- Problem:
  - `InstallGitHub` έσκαγε runtime με:
    - `The term 'if' is not recognized ...`
- Root cause:
  - `if` block χρησιμοποιήθηκε inline ως argument expression σε `Set-MetaValue` call, αντί για precomputed variable.
- Guardrail / Rule:
  - Complex conditional values για function args υπολογίζονται πρώτα σε local variable και μετά περνιούνται ως `-Value`.
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).
