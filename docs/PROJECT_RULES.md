# PROJECT_RULES (Robocopy)

## Scope
- Standalone `Robocopy` context-menu workflow στο `D:\Users\joty79\scripts\Robocopy`.
- Core execution split:
  - `rcopySingle.ps1` = stage
  - `rcp.ps1` = paste engine
  - `RoboCopy_Silent.vbs` / `RoboPaste_Admin.vbs` = wrappers

## Critical Decisions

### 2026-02-16 - Stage backend locked to `file` (remove toggle risk)
- Problem:
  - Το `stage_backend` toggle δεν χρησιμοποιούνταν και μπορούσε να γυρίσει κατά λάθος σε `registry`, δημιουργώντας debug/runtime divergence από το tuned path.
- Root cause:
  - Legacy fallback option παρέμεινε στο UI/config μετά τα performance/safety optimizations που στόχευαν το file staging flow.
- Guardrail / Rule:
  - Αφαιρέθηκε το `stage_backend` από RoboTune menu/config surface.
  - Runtime (`rcopySingle.ps1`, `rcp.ps1`) κλειδώθηκε σε `file` backend για deterministic behavior.
- Files affected:
  - `RoboTune.ps1`
  - `rcopySingle.ps1`
  - `rcp.ps1`
  - `README.md`
- Validation/tests run:
  - Parse validation `RoboTune.ps1`, `rcopySingle.ps1`, `rcp.ps1` μέσω parser check.

### 2026-02-16 - Removed route-based MT overrides (RoboTune cleanup)
- Problem:
  - Route override menu (`Add/Remove route MT`) πρόσθετε complexity χωρίς να χρησιμοποιείται.
- Root cause:
  - Διπλό tuning model (`routes` + `default_mt` + auto rules) έκανε το config πιο δύσκολο στη συντήρηση.
- Guardrail / Rule:
  - Αφαιρέθηκαν πλήρως τα route overrides από `RoboTune.ps1`, `rcp.ps1`, και docs.
  - MT tuning πλέον βασίζεται σε: `RCWM_MT` env > `default_mt` > `mt_rules`.
- Files affected:
  - `RoboTune.ps1`
  - `rcp.ps1`
  - `README.md`
- Validation/tests run:
  - Parse validation `RoboTune.ps1` και `rcp.ps1` μέσω parser check.

### 2026-02-16 - Configurable MT media-combo rules (`mt_rules`)
- Problem:
  - Χρειαζόταν ξεχωριστό MT control για SSD/HDD combos (ειδικά `SSD->HDD`, `HDD->HDD diff volume`, `HDD->HDD same volume`) χωρίς να εξαρτάται μόνο από `default_mt` ή route overrides.
- Root cause:
  - Το auto MT logic ήταν hardcoded και δεν επέτρεπε per-combo tuning.
- Guardrail / Rule:
  - Προστέθηκε `mt_rules` block στο `RoboTune.json` με validated values `1..128`.
  - Decision priority πλέον: `RCWM_MT` env > route override > `default_mt` > `mt_rules` media combo.
  - Νέο RoboTune menu action για interactive update των `mt_rules`.
- Files affected:
  - `rcp.ps1`
  - `RoboTune.ps1`
  - `README.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` και `RoboTune.ps1` μέσω parser check.

### 2026-02-15 - Single-item stage source must equal context anchor
- Problem:
  - Σε single-item Cut/Copy μπορούσε να staged path να αποκλίνει από το clicked item (`%1` anchor), οδηγώντας σε λάθος source στο paste.
- Root cause:
  - Το COM selection fallback μπορούσε να επιστρέψει 1 path που δεν ταίριαζε με το anchor.
- Guardrail / Rule:
  - Για single-item stage (non-token), αν selected path != anchor, γίνεται hard override στο anchor και γράφεται warning/debug marker.
- Files affected:
  - `rcopySingle.ps1`
- Validation/tests run:
  - Parse validation `rcopySingle.ps1` μέσω parser check.

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
  - (Superseded by 2026-02-17) Runtime now uses elevated `pwsh.exe` paste launcher directly (no `wt.exe` dependency).
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

### 2026-02-14 - Critical paste-target safety fix for drive roots (`C:\`)
- Problem:
  - Σε paste προς drive root, target μπορούσε να γίνει drive-relative (`C:`) και να resolve σε `C:\Users\...`, με high-risk wrong destination behavior.
- Root cause:
  - Context-menu argument handling για folder/background paste δεν κάλυπτε με ασφάλεια τα root-drive cases.
  - Το paste engine δε normalizαρε πάντα drive-relative/root token forms πριν το `Test-Path`.
- Guardrail / Rule:
  - Registry commands:
    - folder paste uses `%1`
    - background paste uses `%V.` (safe root token form)
  - `rcp.ps1` κάνει explicit normalization πριν validation:
    - `C:` -> `C:\`
    - `C:\.` -> `C:\`
    - `...\.` -> `...\`
- Files affected:
  - `Install.ps1`
  - `rcp.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation (`Install.ps1`, `rcp.ps1`) via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Critical hardening for staging + move safety (drive-relative source and protected roots)
- Problem:
  - Staging μπορούσε να resolve drive-relative anchor forms (`C:`) σε user-profile paths μέσω `Resolve-Path`, και σε rare fallback cases να stage λάθος source.
  - Paste move flow δεν είχε effective guardrail για protected roots, άρα ένα λάθος staged path μπορούσε να προχωρήσει σε transfer.
- Root cause:
  - Path normalization δεν ήταν centralized στο stage script (`rcopySingle.ps1`) πριν από `Resolve-Path`.
  - Move safety checks δεν υπήρχαν στο effective transfer list του paste pipeline.
- Guardrail / Rule:
  - Introduce shared context-path normalization in both stage and paste engines:
    - `C:` -> `C:\`
    - `C:\.` -> `C:\`
    - `...\.` -> `...\`
  - Apply normalization before `Resolve-Path` in `rcopySingle.ps1`.
  - Enforce move safety filtering in `rcp.ps1`:
    - block exact protected roots (`SystemDrive`, `SystemRoot`, `USERPROFILE`, `Program Files`, `ProgramData`).
    - blocked paths are removed from effective transfer list.
    - if all move items are blocked, abort with explicit safety error.
- Files affected:
  - `rcopySingle.ps1`
  - `rcp.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation (`rcopySingle.ps1`, `rcp.ps1`) via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Installer hardening: local-source fallback + GitHub update check
- Problem:
  - Όταν το `Install.ps1` τρέχει standalone από path χωρίς package files (π.χ. Desktop), έσκαγε με `Missing source file: ...\rcp.ps1`.
  - Δεν υπήρχε update pre-check πριν από install/update flow.
- Root cause:
  - Το `PackageSource=Local` επέστρεφε τυφλά `$SourcePath` χωρίς completeness validation.
  - Δεν γινόταν compare installed metadata commit vs latest GitHub commit.
- Guardrail / Rule:
  - Installer validates local package root completeness.
  - Αν local source είναι incomplete:
    - fallback σε existing install root (αν complete), αλλιώς
    - auto-switch σε GitHub package source.
  - Added GitHub update check (latest commit) πριν το install/update flow.
  - Installer stores `github_commit` in `install-meta.json` για επόμενο compare.
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Installer source selection policy update (prefer GitHub on incomplete local source)
- Problem:
  - Σε `Action=Install/Update` από standalone script path, το fallback μπορούσε να χρησιμοποιήσει το existing install root ως source και να μην τραβήξει latest GitHub version.
  - Αυτό οδηγούσε σε "updated with warnings" χωρίς πραγματικό code refresh.
- Root cause:
  - Source resolver επέστρεφε early local fallback πριν δοκιμάσει GitHub package fetch.
- Guardrail / Rule:
  - Όταν `PackageSource=Local` και το local source είναι incomplete:
    - προτιμάται GitHub fetch,
    - local install root χρησιμοποιείται μόνο ως emergency fallback αν αποτύχει GitHub download/extract/validation.
  - `package_source` metadata γράφει την πραγματική resolved source (`GitHub` ή fallback `Local`).
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Installer UX simplification (3-option menu, restart prompt, core file checks)
- Problem:
  - Interactive menu είχε διπλές επιλογές (`Install/Update` και `Install/Update GitHub`) που μπέρδευαν το flow.
  - Explorer restart γινόταν χωρίς explicit prompt.
  - Δεν υπήρχε άμεσο visual verify των core runtime files μετά το deploy.
- Root cause:
  - Legacy menu layout και implicit restart behavior από προηγούμενα installer iterations.
- Guardrail / Rule:
  - Interactive menu reduced to `Install`, `Update`, `Uninstall`, `Exit`.
  - `Install`/`Update` interactive actions use GitHub source by default.
  - Added explicit user prompt before Explorer restart (unless `-Force` or `-NoExplorerRestart`).
  - Added `Verify-CoreRuntimeFiles` with green success lines (`[✓]`) and warning tracking on missing files.
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-14 - Installer self-update guard (master `Install.ps1` check on launch)
- Problem:
  - `Install.ps1` μπορεί να εκτελείται από οποιοδήποτε path (π.χ. Desktop) και να είναι outdated, οδηγώντας σε ασυνεπή install behavior.
- Root cause:
  - Δεν υπήρχε pre-flight self-update check του installer script πριν από το main flow.
- Guardrail / Rule:
  - On launch, installer compares local `Install.ps1` vs `master` `Install.ps1` from GitHub (normalized content hash).
  - If same: prints green success and continues normally.
  - If different: asks user to download latest in same directory and relaunches latest script.
  - If overwrite of running file fails, writes fallback `Install_latest.ps1` and relaunches that.
  - Added `-SkipSelfUpdateCheck` to prevent relaunch loop.
- Files affected:
  - `Install.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-15 - Temp folder-only benchmark context menu (single-folder copy/paste)
- Problem:
  - Χρειαζόταν isolated benchmark flow για να μετρηθεί snappiness σε αυστηρά `1 folder -> 1 target folder` χωρίς το overhead του full multi-selection/universal engine.
- Root cause:
  - Το full stack καλύπτει πολλά scenarios/guards και δυσκολεύει τη σύγκριση καθαρού single-folder path.
- Guardrail / Rule:
  - Added temp benchmark stack with dedicated scripts/keys:
    - stage only one folder path (`benchmarks/folder-only-context/FolderBench_CopyStage.ps1`)
    - paste folder-to-folder via direct `robocopy` call (`benchmarks/folder-only-context/FolderBench_Paste.ps1`)
    - wrappers (`benchmarks/folder-only-context/FolderBench_CopySilent.vbs`, `benchmarks/folder-only-context/FolderBench_Paste.vbs`)
    - separate reg integration (`benchmarks/folder-only-context/RoboCopy_FolderOnly_Benchmark.reg`)
  - Uses separate context-menu key names (`Y_30_*`, `Y_31_*`) to avoid collisions with normal Robo-Copy/Robo-Paste entries.
- Files affected:
  - `benchmarks/folder-only-context/FolderBench_CopyStage.ps1`
  - `benchmarks/folder-only-context/FolderBench_Paste.ps1`
  - `benchmarks/folder-only-context/FolderBench_CopySilent.vbs`
  - `benchmarks/folder-only-context/FolderBench_Paste.vbs`
  - `benchmarks/folder-only-context/RoboCopy_FolderOnly_Benchmark.reg`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation for new PowerShell scripts via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-15 - Always-visible elapsed timing in main runtime
- Problem:
  - Με `benchmark=false`, το main runtime δεν έδειχνε χρόνο στο console, άρα δεν γινόταν γρήγορη σύγκριση με temp benchmark runs.
- Root cause:
  - Το session timing output ήταν δεμένο αποκλειστικά με `BenchmarkOutput`.
- Guardrail / Rule:
  - Keep transfer/session timing visible even when benchmark counters are off.
  - With `benchmark=false`, print compact summary:
    - `Elapsed: ... | Operations: ...`
    - `Phase timing: Resolve | Prep | Execute | Total`
  - With `benchmark=true`, keep full benchmark block and include same phase timing line.
- Files affected:
  - `rcp.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-15 - Temp single-file benchmark context menu (single-file copy/paste)
- Problem:
  - Χρειαζόταν isolated benchmark flow για να συγκριθεί η απόδοση του strict `single-file` path πριν ενσωματωθεί fast path στο main runtime.
- Root cause:
  - Το universal engine κάνει extra orchestration που δεν είναι πάντα απαραίτητο για 1 file benchmark scenarios.
- Guardrail / Rule:
  - Added temp benchmark stack with dedicated scripts/keys:
    - stage only one file path (`benchmarks/single-file-context/FileBench_CopyStage.ps1`)
    - paste file-to-folder via direct `robocopy` call (`benchmarks/single-file-context/FileBench_Paste.ps1`)
    - wrappers (`benchmarks/single-file-context/FileBench_CopySilent.vbs`, `benchmarks/single-file-context/FileBench_Paste.vbs`)
    - separate reg integration (`benchmarks/single-file-context/RoboCopy_SingleFile_Benchmark.reg`)
  - Uses separate context-menu key names (`Y_32_*`, `Y_33_*`) to avoid collisions with normal Robo-Copy/Robo-Paste entries and folder benchmark temp keys.
- Files affected:
  - `benchmarks/single-file-context/FileBench_CopyStage.ps1`
  - `benchmarks/single-file-context/FileBench_Paste.ps1`
  - `benchmarks/single-file-context/FileBench_CopySilent.vbs`
  - `benchmarks/single-file-context/FileBench_Paste.vbs`
  - `benchmarks/single-file-context/RoboCopy_SingleFile_Benchmark.reg`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation for new PowerShell scripts via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-15 - RoboTune usability: decouple hold window from benchmark mode
- Problem:
  - Όταν `benchmark_mode` γινόταν OFF, το window συχνά έκλεινε στο τέλος και δυσκόλευε manual timing checks.
- Root cause:
  - Το RoboTune benchmark toggle άλλαζε αυτόματα και το `hold_window`, οπότε δεν υπήρχε ανεξάρτητος έλεγχος.
- Guardrail / Rule:
  - `benchmark_mode` toggle controls benchmark output only.
  - Added dedicated menu toggle for `hold_window`.
  - Users can keep window open without forcing benchmark mode.
- Files affected:
  - `RoboTune.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `RoboTune.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-15 - Main runtime fast path for same-volume cut (native move)
- Problem:
  - Main runtime είχε fixed orchestration tax σε cut flows, ειδικά ορατό σε single-item and same-volume scenarios.
- Root cause:
  - Move operations περνούσαν πάντα από robocopy copy+delete semantics, ακόμα και όταν source/destination ήταν στο ίδιο volume και χωρίς conflicts.
- Guardrail / Rule:
  - Added safe native move fast path (`Move-Item`) for `cut` only, with fallback to robocopy on any failure.
  - Enabled only when all conditions hold:
    - `IsMove = true`
    - `MergeMode = false`
    - same-volume source/destination
    - no destination conflict for target item(s)
  - Applied to:
    - single directory transfer
    - single file transfer
    - grouped file-batch transfer from same source directory
  - Keeps existing safety/protected path checks untouched.
- Files affected:
  - `rcp.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-15 - Critical safety guard for folder move target semantics
- Problem:
  - Move-to-folder icon scenarios could be unsafe/ambiguous, with risk of destructive outcomes when destination semantics were interpreted incorrectly or when destination was inside source.
- Root cause:
  - Native move fast path used container destination semantics and previously allowed fallback behavior for `destination inside source` cases.
- Guardrail / Rule:
  - Added hard block for move operations when destination path is inside source path (`DestinationInsideSource`), no robocopy fallback.
  - Native move fast path now uses explicit final destination path:
    - directory: `Move-Item Source -> PasteTarget\ItemName`
    - file: `Move-Item Source -> PasteTarget\FileName`
  - This removes ambiguity for folder-icon paste behavior and prevents self-nesting destructive patterns.
- Files affected:
  - `rcp.ps1`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `rcp.ps1` via `Parser::ParseFile` (`PARSE_OK`).

### 2026-02-17 - Paste launcher moved to pwsh-only (remove wt dependency)
- Problem:
  - Paste launch had extra `wt.exe` dependency and branch logic while user wanted lighter direct launch.
- Root cause:
  - `RoboPaste_Admin.vbs` and installer-generated paste wrapper used `wt.exe` first and only then fallback to `pwsh.exe`.
- Guardrail / Rule:
  - Always launch elevated `pwsh.exe` directly for `Robo-Paste`.
  - No runtime dependency on Windows Terminal for paste execution.
- Files affected:
  - `RoboPaste_Admin.vbs`
  - `Install.ps1`
  - `README.md`
  - `RoboCopy_StandAlone.reg`
  - `docs/INSTALLER.md`
  - `docs/PROJECT_RULES.md`
- Validation/tests run:
  - Parse validation `Install.ps1` via `Parser::ParseFile` (`PARSE_OK`).
