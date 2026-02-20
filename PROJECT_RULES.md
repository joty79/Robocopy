# PROJECT_RULES.md (Robocopy)

## Scope
- This file stores Robocopy repo decisions, tuning guardrails, and runtime lessons.
- Keep entries concise and actionable.
- Do not move MoveTo/NuclearDelete-only items here.

## Decision Log
### 2026-02-11 - Adaptive RoboCopy thread rule
- Problem: Fixed `/MT:32` is fast on NVMe but can underperform on HDD or same-drive copies.
- Root cause: Storage bottlenecks vary by media type and path topology.
- Guardrail: Choose `/MT` adaptively (`8` for HDD/network/same-physical-disk, `32` for SSD->SSD, `16` fallback).
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: Use `__mtprobe` mode with representative source/destination paths.

### 2026-02-11 - RoboCopy benchmark and tuning controls
- Problem: Needed real-time speed visibility and manual MT tuning per partition route.
- Root cause: Performance depends on source/destination topology and workload shape.
- Guardrail: Use explicit `benchmark_mode` toggle; when ON keep paste window open with hotkey to `RoboTune.ps1`, when OFF close normally.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/RoboTune.ps1`, `Robocopy/README.md`.
- Validation/tests: Parse check + `__mtprobe` + interactive config load.

### 2026-02-11 - RoboDelete folder context menu
- Problem: Need one-click folder test entry from Explorer for permanent delete speed checks.
- Root cause: Manual drag/drop batch flow is slower to trigger repeatedly during benchmarks.
- Guardrail: Use folder-only context menu entry pointing to `robodelete_fast.bat` via VBS wrapper.
- Files affected: `Robocopy/RoboDelete_Folder.vbs`, `Robocopy/RoboDelete_Folder.reg`, `Robocopy/README.md`.
- Validation/tests: VBS syntax check (`cscript //nologo`) + file content verification.

### 2026-02-11 - RoboDelete MT and speed profile
- Problem: Needed explicit robocopy multi-thread tuning for delete benchmarks.
- Root cause: Baseline batch lacked `/MT` control.
- Guardrail: Default `robodelete_fast.bat` folder profile uses `/MT:64` plus `/R:0 /W:0 /NFL /NDL /NJH /NJS /NP /XJ`; allow override via `ROBODELETE_MT`.
- Files affected: `Robocopy/robodelete_fast.bat`, `Robocopy/README.md`.
- Validation/tests: Local temp-folder run with `ROBODELETE_MT=64` and summary/log verification.

### 2026-02-11 - RoboDelete low-overhead testing mode
- Problem: Benchmark view/progress output can distort delete-speed measurements.
- Root cause: Console progress rendering (`/ETA` and verbose output) adds non-trivial overhead in some workloads.
- Guardrail: Add `ROBODELETE_TEST` mode; default `1` sets silent fast profile + hold window for summary, with elapsed time as primary metric and minimal summary fields.
- Files affected: `Robocopy/robodelete_fast.bat`, `Robocopy/README.md`.
- Validation/tests: Batch parse/flow verification and config echo/log field checks for `TEST/VISUAL/HOLD`.

### 2026-02-11 - RoboTune debug mode for copy diagnostics
- Problem: Needed a quick way to capture robocopy diagnostics for red-error cases during copy/paste tests.
- Root cause: Existing benchmark/run logs did not include full robocopy verbose file-level details.
- Guardrail: Add `debug_mode` in `RoboTune.json`; when ON, `rcp.ps1` appends `/TEE /LOG+:robocopy_debug.log /V /TS /FP /BYTES` (without duplicating user flags), when OFF keep fast default behavior.
- Files affected: `Robocopy/RoboTune.ps1`, `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation OK for both scripts (`RoboTune.ps1`, `rcp.ps1`).

### 2026-02-12 - Suppress profile startup errors in Robocopy launchers
- Problem: Red startup errors appeared at the beginning of RoboCopy runs and were reproducible each time.
- Root cause: Launcher VBS started `pwsh` with user profile loading, and profile `PSReadLine` settings can error in non-interactive/redirected contexts.
- Guardrail: Launch Robocopy scripts with `-NoProfile` in VBS wrappers to avoid unrelated profile noise and keep output focused on transfer logs.
- Files affected: `Robocopy/RoboPaste_Admin.vbs`, `Robocopy/RoboCopy_Silent.vbs`, `Robocopy/README.md`.
- Validation/tests: Script inspection of generated command lines (contains `-NoProfile`) + repeated log check with no `rcp.ps1` runtime errors.

### 2026-02-12 - Robocopy multi-select hardening for files + folders
- Problem: Context-menu staging was unreliable for large/mixed multi-select and effectively kept one source path in edge cases.
- Root cause: Copy/Cut registration was directory-only and staging logic overwrote previous entry per invoke.
- Guardrail: Register Copy/Cut under `AllFilesystemObjects` with `MultiSelectModel=Document`; use VBS lock to enforce single staging worker per Explorer burst; capture full Explorer selection snapshot in `rcopySingle.ps1`; store staged paths as ordered `item_######` values in registry; update paste engine to handle both directory and file transfers.
- Files affected: `Robocopy/RoboCopy_StandAlone.reg`, `Robocopy/RoboCopy_Silent.vbs`, `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`, `rcopySingle.ps1`) + VBS syntax check + registry command review (`AllFilesystemObjects`, `MultiSelectModel=Document`, `%1` launcher arg).

### 2026-02-12 - Robocopy staging scalar-path and timestamp parsing fix
- Problem: Staging could write `item_000001 = D` (only drive letter) and keep failing with missing source list.
- Root cause: Single-item path handling could degrade to scalar-string indexing, and timestamp parse used an incompatible overload causing staging to abort before writing.
- Guardrail: Normalize staged path collections explicitly to `string[]` before save/merge and use safe datetime parse (`try { [DateTime]::Parse(...) } catch {}`) for session-window logic.
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1`.
- Validation/tests: Smoke stage run wrote full paths (`item_000001..item_000009`) and `stage_log.txt` confirmed `selected=9`.

### 2026-02-12 - Robocopy file batching to avoid one-file-per-call slowdown
- Problem: File multi-select copy was effectively one `robocopy` process per file and felt very slow; folder paste could fail right after staging due malformed single-item registry value.
- Root cause: File flow in `rcp.ps1` invoked `robocopy` per file filter; staging merge/save paths in `rcopySingle.ps1` could collapse to scalar-string and write only first character (`D`).
- Guardrail: Force array normalization for staged selections/combined lists in `rcopySingle.ps1`; in `rcp.ps1` group files by source directory and run batched file-filter transfers (with chunking to avoid command-length limits), keeping folder flow unchanged.
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1`.
- Validation/tests: PowerShell parser validation for both scripts + smoke staging check now writes full value (`item_000001 = D:\...`) instead of single drive letter.

### 2026-02-12 - Robocopy multi-file path overhead reduction (selection-heavy runs)
- Problem: Large file selections were slower than Explorer and produced heavy repeated console/check overhead compared to folder-level robocopy.
- Root cause: Multi-select path still paid high per-batch console rendering and pre-copy filesystem checks (`Test-Path` per selected item), with conservative filename chunk size causing too many robocopy invocations.
- Guardrail: In `rcp.ps1`, suppress per-file/dir listing in normal mode (`/NFL /NDL`), increase file batch chunk target (6500 -> 26000 chars), and replace per-item destination `Test-Path` checks with in-memory destination name set + duplicate-name tracking.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + source inspection of new flags/chunk size/name-set conflict classification.

### 2026-02-12 - Robocopy multi-select second performance pass (lookup/output trimming)
- Problem: In very large file selections, overhead remained noticeable during classification and conflict-heavy flows.
- Root cause: Extra filesystem lookups (`Test-Path` + `Get-Item` pairs and second-pass `Get-Item` in file batches) plus full-list console dumps for large selections/conflicts.
- Guardrail: Remove redundant existence checks in collection pass, avoid second-pass `Get-Item` in file-batch builder (use staged path parsing), and truncate huge selection/conflict previews in normal mode.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + source inspection for preview truncation and reduced lookup flow.

### 2026-02-12 - Robocopy context-menu fast path (no pre-conflict scan)
- Problem: Multi-file context-menu operations still spent time in conflict classification and interactive checks even when reliability did not require user prompts.
- Root cause: Single-mode flow (`mode=s`) reused merge-precheck pipeline designed for manual interactive mode.
- Guardrail: For context-menu single mode, bypass pre-scan conflict classification/prompt and execute direct transfer path; keep interactive merge prompt only for manual mode (`mode=m`). Also cache MT decisions and reduce per-transfer run-log writes unless benchmark/debug is enabled.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + source inspection of `mode=s` direct path, decision cache, and conditional run-log writes.

### 2026-02-12 - Wildcard fast-path for full-folder file selections
- Problem: Even after batching improvements, very large "Select All files" runs still required multiple filename batches and extra overhead.
- Root cause: File mode passed explicit filename lists to robocopy; command-line size limits forced chunking.
- Guardrail: Detect when selected files equal all top-level files in a source directory and switch to a single wildcard file-filter call (`*`) for that group; fallback to filename batching otherwise.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + source inspection for fast-path selection check and wildcard run-log marker.

### 2026-02-12 - Staging lock in VBS to cut pwsh clone bursts
- Problem: Mixed file+folder selections could spawn many hidden `pwsh` processes during copy/cut staging.
- Root cause: Explorer multi-select invokes the verb per item (`%1`), and each invoke launched `rcopySingle.ps1`.
- Guardrail: Add short-lived lock file in `RoboCopy_Silent.vbs` (`state\stage.lock`) with stale cleanup so one selection burst launches only one hidden staging `pwsh`; other burst invokes exit immediately.
- Files affected: `Robocopy/RoboCopy_Silent.vbs`, `Robocopy/README.md`.
- Validation/tests: VBS script execution check (no-arg run), plus source inspection of lock acquire/release and stale lock cleanup.

### 2026-02-12 - Mixed-selection burst suppression marker
- Problem: Mixed selections still triggered additional hidden staging workers after the initial stage, creating `pwsh` bursts and CPU spikes.
- Root cause: Explorer could continue issuing per-item invokes from the same parent folder even after the first full-selection stage completed.
- Guardrail: `RoboCopy_Silent.vbs` now stores a short burst marker (`state\stage.burst`) for `mode+parent`; same-burst duplicate invokes are skipped for a few seconds. `rcopySingle.ps1` returns a dedicated exit code (`10`) when stage captured multi-item selection so VBS only marks true multi bursts.
- Files affected: `Robocopy/RoboCopy_Silent.vbs`, `Robocopy/rcopySingle.ps1`, `Robocopy/README.md`.
- Validation/tests: VBS no-arg run (`cscript //nologo`) + PowerShell parse check (`rcopySingle.ps1`) + hash sync check with standalone `D:\Users\joty79\scripts\Robocopy`.

### 2026-02-12 - Back-to-back copy/paste suppression reset
- Problem: Two very fast copy/paste cycles could make the second paste window open/close immediately (no staged items).
- Root cause: Burst suppression marker (`state\stage.burst`) could still be active from previous cycle when the next copy started.
- Guardrail: Clear `state\stage.burst` on all `Robo-Paste` exit paths (normal finish, early exit, and error) in `rcp.ps1`.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + runtime A/B test with immediate second copy/paste cycle.

### 2026-02-12 - Burst suppression gated by active staged session
- Problem: Fast second copy from the same parent could be suppressed even when it was a valid new action, causing paste window to close with no transfer.
- Root cause: `RoboCopy_Silent.vbs` relied on `state\stage.burst` + parent match only, without confirming registry stage still existed.
- Guardrail: In `RoboCopy_Silent.vbs`, apply burst suppression only when staged registry session is active (`__last_stage_utc` and `item_000001` exist); otherwise clear stale burst marker and continue staging.
- Files affected: `Robocopy/RoboCopy_Silent.vbs`.
- Validation/tests: VBS no-arg execution (`cscript //nologo`) + log correlation (`run_log.txt` showed prior empty-start symptom).

### 2026-02-12 - Copy staging lock retry for first-click reliability
- Problem: In fast consecutive copy/paste cycles, first copy click could be dropped and only the second manual try would stage correctly.
- Root cause: `RoboCopy_Silent.vbs` exited immediately on lock contention, even when contention was short-lived from near-complete previous staging activity.
- Guardrail: Add bounded lock retry (`4 x 700ms`) after initial lock failure (while still respecting burst suppression), so first click waits briefly instead of being discarded.
- Files affected: `Robocopy/RoboCopy_Silent.vbs`.
- Validation/tests: VBS no-arg execution (`cscript //nologo`) + live sync to `D:\Users\joty79\scripts\Robocopy` + runtime retest requested.

### 2026-02-12 - Paste waits for stage readiness on ultra-fast copy/paste
- Problem: Ultra-fast copy->paste could fail on first paste (window opens/closes), then work on second attempt.
- Root cause: Paste could start before hidden staging (`rcopySingle.ps1`) had finished writing registry items.
- Guardrail: In `rcp.ps1`, replace immediate staged-list read with lock-aware wait/retry (`Get-StagedPathListWithWait`): short fast-fail when no stage activity is detected, but wait up to 6s when staging lock is active/observed.
- Files affected: `Robocopy/rcp.ps1`.
- Validation/tests: PowerShell parser validation for workspace + live copy, sync to `D:\Users\joty79\scripts\Robocopy`, remote push on `fix/second-paste-window-close`.

### 2026-02-12 - Fail-closed stage contract + stable selection capture
- Problem: In ultra-fast flows, dangerous partial copy could happen (subset copied) instead of clean fail/retry.
- Root cause: Staging could snapshot selection too early (breaking on first `count>1`) and paste accepted whatever registry list existed without readiness/integrity checks.
- Guardrail: `rcopySingle.ps1` now captures best/stable selection across retries and writes stage metadata (`__ready`, `__expected_count`, `__session_id`, `__last_stage_utc`); `rcp.ps1` now accepts stage only when metadata is valid (`ready=1` and expected count matches actual items), otherwise fail-closed (`NoListAvailable`).
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1`.
- Validation/tests: PowerShell parser validation (workspace + live standalone folder) + sync to `D:\Users\joty79\scripts\Robocopy` + remote push (`aed5aef`) on `fix/second-paste-window-close`.

### 2026-02-12 - Restore stage-ready wait for metadata snapshots (old no-list regression)
- Problem: Old error returned (`NoListAvailable (mode=s)`) even though staging succeeded a moment later.
- Root cause: Paste switched to fail-closed metadata snapshots but lost the earlier wait/retry window; in fast copy->paste race, `rcp.ps1` read registry before stage write completed.
- Guardrail: Add metadata-aware wait resolver in `rcp.ps1` (`Resolve-ActiveStagedSnapshotWithWait`) that polls for a valid ready snapshot (`__ready=1` + expected count match) with lock/burst signal awareness, then selects active command; keep fail-closed behavior if readiness never materializes.
- Files affected: `Robocopy/rcp.ps1` (synced to `D:\Users\joty79\scripts\Robocopy\rcp.ps1`).
- Validation/tests: PowerShell parser validation on workspace and live copies; log correlation against failing window (`run start` before `stage OK`) to confirm fixed race point.

### 2026-02-12 - Narrow burst suppression window for same-folder rapid re-copy
- Problem: Very fast second copy from the same source folder could be treated as duplicate burst and fail in silent flow.
- Root cause: VBS burst suppression (`state\stage.burst`) allowed up to 6s same-parent suppression while stage session was active, which could catch intentional next copy action.
- Guardrail: In `RoboCopy_Silent.vbs`, keep burst marker lifetime but only suppress near-instant duplicates (`<=1s`) when active stage exists; for older marker ages, clear marker and allow restage.
- Files affected: `Robocopy/RoboCopy_Silent.vbs` (synced to `D:\Users\joty79\scripts\Robocopy\RoboCopy_Silent.vbs`).
- Validation/tests: VBS no-arg run (`cscript //nologo`) + live sync for immediate manual retest.

### 2026-02-12 - Fast same-folder second-copy hardening (lock retry + longer stage wait)
- Problem: In ultra-fast back-to-back copy/paste from same source folder, first attempt could fail (`NoListAvailable`) and only second retry work.
- Root cause: Silent staging invoke could be dropped under short lock contention windows; paste resolver wait window (6s) could expire before a delayed/late stage became ready.
- Guardrail: Increase silent lock acquire retry window in `RoboCopy_Silent.vbs` (`LOCK_RETRY_ATTEMPTS=10`, `LOCK_RETRY_DELAY_MS=600`) and reduce stale lock threshold (`STALE_LOCK_SECONDS=30`); increase stage-ready max wait in `rcp.ps1` to `12000ms` while keeping fast-fail when no signals exist.
- Files affected: `Robocopy/RoboCopy_Silent.vbs`, `Robocopy/rcp.ps1` (synced to `D:\Users\joty79\scripts\Robocopy`).
- Validation/tests: PowerShell parser validation on live `rcp.ps1` + live file sync for manual back-to-back scenario retest.

### 2026-02-12 - Burst suppression requires fully ready stage metadata
- Problem: Same-folder rapid second copy could be suppressed even when prior staged data was incomplete/corrupted, leading to timeout then `NoListAvailable`.
- Root cause: `RoboCopy_Silent.vbs` considered stage "active" based on weak markers (`__last_stage_utc` + first item), which can be true for partial/non-ready stage state.
- Guardrail: In `HasActiveStageSession`, require strict readiness (`__ready=1`, `__expected_count>0`, and `item_000001` exists) before allowing burst suppression; otherwise do not suppress and let restage proceed.
- Files affected: `Robocopy/RoboCopy_Silent.vbs` (synced to `D:\Users\joty79\scripts\Robocopy\RoboCopy_Silent.vbs`).
- Validation/tests: VBS no-arg execution (`cscript //nologo`) + log-driven root-cause correlation (`Stage rejected ... Ready=False | Expected= | Actual=...`).

### 2026-02-12 - Deterministic registry value cleanup (no wildcard clear)
- Problem: Stage keys could retain stale `item_######` entries, causing fail-closed mismatches (`Ready=True`, `Expected=N`, `Actual>>N`) and repeated `NoListAvailable`.
- Root cause: Wildcard property deletion (`Remove-ItemProperty ... -Name *`) proved unreliable for registry value cleanup in this flow, so old entries survived between stages.
- Guardrail: Replace wildcard deletion with explicit per-value cleanup by enumerating registry properties and removing each non-PS/non-default name (`Clear-RegistryValuesByName` / `Clear-StagedRegistryValues`).
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1` (synced to `D:\Users\joty79\scripts\Robocopy`).
- Validation/tests: PowerShell parser validation (workspace + live), plus live registry snapshot check (`Ready=1`, `Expected=4944`, `Items=4944`) showing matched counts.

### 2026-02-12 - Atomic stage overwrite (disable session append/reuse)
- Problem: Re-copying from same source could intermittently fail with `NoListAvailable`, and stage logs showed inflated totals from previous actions.
- Root cause: `Save-StagedPaths` reused recent session data (`reused_session=True`) and appended old staged entries, making stage state non-deterministic under rapid consecutive actions.
- Guardrail: Make stage writes atomic per action: always replace staged list with current selection only (no append/reuse), while keeping deterministic value-by-value registry cleanup.
- Files affected: `Robocopy/rcopySingle.ps1` (runtime + workspace sync).
- Validation/tests: Parse validation for runtime/workspace scripts + log-driven confirmation target (`reused_session` expected to stay `False` after change).

### 2026-02-12 - Paste wait for ready snapshot (avoid fast-click no-list race)
- Problem: `NoListAvailable` still appeared when paste was invoked very quickly after copy/cut, even though staging completed moments later.
- Root cause: `rcp.ps1` used one-shot staged snapshot read in paste flow; if stage metadata was not ready yet, it failed immediately.
- Guardrail: Add `Get-ReadyStagedSnapshotWithWait` in `rcp.ps1` and use it before `NoListAvailable` to wait briefly for a valid ready snapshot (`__ready=1` + expected count match), with lock-aware timeout/fast-fail behavior.
- Files affected: `Robocopy/rcp.ps1` (runtime + workspace sync).
- Validation/tests: PowerShell parse validation on runtime/workspace + log expectation for `Stage wait resolved` on fast consecutive actions.

### 2026-02-12 - File staging backend (default) with backend abstraction
- Problem: Registry staging kept failing intermittently under high-frequency copy/cut->paste timing races.
- Root cause: Registry snapshot readiness and consume timing remained vulnerable to stale/partial state despite retries.
- Guardrail: Default stage backend switched to atomic file snapshots (`state\staging\rc.stage.json`, `state\staging\mv.stage.json`) with explicit backend abstraction (`file`/`registry`) in both stage writer and paste reader/clear paths.
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1`, `Robocopy/RoboTune.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation for modified scripts + static verification of backend precedence (`RCWM_STAGE_BACKEND` env -> `RoboTune.json.stage_backend` -> default `file`).

### 2026-02-13 - Keep source folder after tokenized select-all move
- Problem: Σε move από μέσα σε folder (select-all files/folders), το source folder μπορούσε να διαγραφεί όταν άδειαζε.
- Root cause: Το tokenized move path χρησιμοποιεί `/MOVE` στο source directory, που μπορεί να αφαιρέσει και το root source folder όταν μείνει empty.
- Guardrail: Μετά από successful tokenized move, αν λείπει το source directory, γίνεται explicit recreate ώστε να παραμένει άδειο.
- Files affected: `rcp.ps1`, `PROJECT_RULES.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + runtime retest pending (select-all cut μέσα από source folder).

### 2026-02-13 - Preserve source folder identity (no recreate/reorder)
- Problem: Το recreate-after-delete workaround διατηρούσε μεν folder name, αλλά μπορούσε να αλλάζει η θέση/sort order του source folder στο Explorer.
- Root cause: Το source root folder διαγραφόταν πρώτα από `/MOVE` και μετά ξαναδημιουργούνταν.
- Guardrail: Στο tokenized move path δημιουργείται προσωρινό keep-root marker file στο source root και περνάει exclude (`/XF <marker>`), ώστε ο root folder να μη διαγράφεται ποτέ. Μετά το transfer ο marker αφαιρείται.
- Files affected: `rcp.ps1`, `PROJECT_RULES.md`.
- Validation/tests: PowerShell parser validation (`rcp.ps1`) + runtime retest pending (select-all cut, verify source folder remains same object/position).

## Entry Template

### 2026-02-19 - Keep-root marker cleanup reliability (SelectAll move)

- Problem: Rarely one source file remained after a successful tokenized move.
- Root cause: Temporary keep-root marker (`__rcwm_keep_root_*.tmp`) is excluded from `/MOVE`; single-shot cleanup could fail transiently.
- Guardrail/rule: Use fast bounded retry cleanup for marker file and log warning only if marker still exists after retries.
- Files affected:
  - `rcp.ps1`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for modified scripts.

### 2026-02-19 - Tokenized move transient delete reconciliation

- Problem: Rare leftover source file could remain after successful tokenized move due to transient `Access denied` on source delete.
- Root cause: Robocopy transfer succeeded but one source file delete could fail transiently; marker cleanup was already fixed and not involved.
- Guardrail/rule: Add token-path-only, root-only conditional reconciliation after successful move; delete only safe twins (same name + same size + same LastWriteTimeUtc) with tiny bounded retries.
- Files affected:
  - `rcp.ps1`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for modified scripts.

### 2026-02-19 - Desktop anchor-miss fallback for stage selection

- Problem: Multi-select copy from Desktop could stage only one folder/file and paste would copy a single item.
- Root cause: Desktop Direct Access probe executed only when `fallbackCount <= 0`; stale selection from another Desktop window (`fallbackCount > 0`) skipped desktop probe and produced single-selection mismatch.
- Guardrail/rule: In `Get-ExplorerSelectionFromParentEnumerated`, run Desktop Direct Access whenever anchor is not found in enumerated windows (anchor-normalized available), not only on zero fallback count.
- Files affected:
  - `rcopySingle.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcopySingle.ps1`.

### 2026-02-19 - Preserve recent multi-stage against late single-mismatch overwrite

- Problem: After a correct `selected=2` stage, a late second invoke could still overwrite stage with `selected=1` and copy only one item.
- Root cause: `single-selection mismatch` fallback (`use-anchor`) could replace a fresh multi-item stage within the same burst.
- Guardrail/rule: Before applying single-mismatch `use-anchor`, check existing staged header; if recent (`<=5s`) and `ExpectedCount>1`, skip overwrite and preserve existing multi-stage.
- Files affected:
  - `rcopySingle.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcopySingle.ps1`.

### 2026-02-19 - Prevent stale stage use during active copy staging

- Problem: Paste could consume an older staged session while a newer large selection was still staging, causing "copy that makes no sense".
- Root cause: `Resolve-StagedPayload` returned the latest ready snapshot before enforcing active-stage marker checks; stale ready data could win during race windows.
- Guardrail/rule: Add script-level `stage.inprogress` marker, and in paste resolver wait for a snapshot staged at/after resolve start whenever any active marker is observed (`stage.lock`, `stage.burst`, or `stage.inprogress`); if unresolved, skip fallback snapshot for safety.
- Files affected:
  - `rcp.ps1`
  - `rcopySingle.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcp.ps1`.
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcopySingle.ps1`.

### 2026-02-19 - Tokenize "all top-level files selected" even with unselected folders present

- Problem: Copy staging became slow/retry-prone when all files were selected but sibling folders were unselected in the same directory.
- Root cause: Fast token path in `rcopySingle.ps1` only triggered on strict select-all (`SelectedItems.Count == Folder.Items().Count`), forcing full enumeration + large staged payload writes.
- Guardrail/rule: Add a second count-only fast-path: if `SelectedItems.Count` equals `(Folder.Items().Count - top-level directory count)`, stage wildcard token (`?WILDCARD?|...`) and skip full selected-item enumeration.
- Files affected:
  - `rcopySingle.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcopySingle.ps1`.

### 2026-02-19 - Files-scoped wildcard token to avoid copying unselected folders

- Problem: In "all top-level files selected" scenarios, paste could still copy unselected sibling folders.
- Root cause: Wildcard token transfer used directory mode (`/E`) semantics in `rcp.ps1`; token lacked explicit scope and was treated as full-folder transfer.
- Guardrail/rule: Extend token payload with scope (`ALL` vs `FILES`); for `FILES` scope run token transfer as file-only (`SourceIsFile` + `*`) and never include directory move semantics.
- Files affected:
  - `rcopySingle.ps1`
  - `rcp.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcopySingle.ps1`.
  - PowerShell parser validation (`Parser::ParseFile`) passed for `rcp.ps1`.

### 2026-02-20 - Uninstall cleanup covers legacy HKCU menu branches

- Problem: `Install.ps1 -Action Uninstall` could leave old context-menu registry keys (still pointing to `D:\Users\joty79\scripts\Robocopy`) in some legacy setups.
- Root cause: Cleanup list missed several `HKCU\Software\Classes\Directory\shell` and `HKCU\Software\Classes\*\shell` legacy keys (`rcopy`/`mvdir`/`mvpaste`).
- Guardrail/rule: Keep uninstall cleanup list as superset of known legacy key families across both `HKCR` and `HKCU\Software\Classes`.
- Files affected:
  - `Install.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `Install.ps1`.

### 2026-02-12 - Robocopy staging reliability + file-path error fix
- Problem: Multi-select still often collapsed to one item, and file copy path could throw `Parameter set cannot be resolved`.
- Root cause: Concurrent per-item invokes could overwrite staging state; file branch used fragile parent-path resolution (`Split-Path -LiteralPath`) in some cases.
- Guardrail: In `rcopySingle.ps1`, use named mutex (`Global\MoveTo_RoboCopy_Stage`), retry Explorer selection read, and session-window append (`item_######` + `__last_stage_utc`) so per-item invokes accumulate reliably; in `rcp.ps1`, resolve file parent from `sourceItem.DirectoryName` with fallback.
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/RoboCopy_Silent.vbs`, `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: PowerShell parser validation + runtime staging check in registry (`HKCU:\RCWM\rc`) + error log check (`error_log.txt`) for previous stack location (`rcp.ps1:692`).

### 2026-02-12 - Robocopy pre-paste reset (atomic stage + strict ready contract)
- Problem: Μετά από μεγάλο mixed copy και άμεσο recopy από το ίδιο source, εμφανιζόταν unreliable behavior (`NoListAvailable`, partial stage, inconsistent retry behavior).
- Root cause: Συνδυασμός από session append/reuse στο staging, weak stage validation στο paste resolve, και permissive burst suppression/lock handling στο VBS wrapper.
- Guardrail: `rcopySingle.ps1` γράφει πλέον atomic stage ανά action (χωρίς reuse) με metadata contract (`__ready`, `__expected_count`, `__session_id`, `__last_stage_utc`, `__anchor_parent`), `rcp.ps1` αποδέχεται μόνο ready snapshots με expected=actual και κάνει bounded polling πριν fail-closed, ενώ `RoboCopy_Silent.vbs` κάνει suppression μόνο όταν υπάρχει valid ready stage + lock retry + μικρότερο burst window.
- Files affected: `Robocopy/rcopySingle.ps1`, `Robocopy/rcp.ps1`, `Robocopy/RoboCopy_Silent.vbs` (synced σε `D:\Users\joty79\scripts\Robocopy` και `MoveTo/Robocopy`).
- Validation/tests: PowerShell parser checks (`rcopySingle.ps1`, `rcp.ps1`) + `cscript //nologo RoboCopy_Silent.vbs` smoke run, manual runtime scenario test pending από user.

### 2026-02-12 - Adaptive stage-wait extension for copy->paste race
- Problem: Μετά από μεγάλο copy action, το αμέσως επόμενο paste μπορούσε να δώσει `NoListAvailable` στο πρώτο attempt και να δουλέψει στο δεύτερο.
- Root cause: Το stage resolver είχε fixed μικρό timeout χωρίς adaptive extension όταν υπήρχε ενεργό stage signal (`stage.lock`/`stage.burst`) από in-flight staging.
- Guardrail: `rcp.ps1` χρησιμοποιεί adaptive resolver timing (`StageResolveTimeoutMs=4000`, `StageResolveMaxTimeoutMs=12000`) και επεκτείνει προσωρινά την αναμονή μόνο όταν υπάρχουν lock/burst signals, αλλιώς fail-closed άμεσα.
- Files affected: `Robocopy/rcp.ps1` (runtime + `MoveTo/Robocopy` sync).
- Validation/tests: PowerShell parser validation + hash sync check μεταξύ runtime/workspace αντίγραφου.

### 2026-02-12 - Post-lock burst suppression re-check (queued invoke drain)
- Problem: Σε μεγάλο multi-select (`71 items`) εμφανίζονταν διαδοχικά πολλαπλά `stage_log OK` entries αντί για 1, αυξάνοντας CPU spike και race risk.
- Root cause: Πολλά VBS invocations περνούσαν το pre-lock suppression πριν γραφτεί burst marker και έμπαιναν queued στο lock, άρα κάθε queued invoke έκανε νέο staging.
- Guardrail: Στο `RoboCopy_Silent.vbs` προστέθηκε δεύτερο suppression check αμέσως μετά το lock acquire· αν πλέον υπάρχει active burst για ίδιο mode/parent, γίνεται immediate exit χωρίς νέο staging.
- Files affected: `Robocopy/RoboCopy_Silent.vbs` (runtime + `MoveTo/Robocopy` sync).
- Validation/tests: Hash sync check runtime/workspace + log-pattern review (`stage_log` πολλαπλά sessions στο ίδιο selection).

### 2026-02-12 - Auto-recover rollback (fail-closed only)
- Problem: Το `auto-recover` στο paste flow δεν ήταν αξιόπιστο στο real usage και πρόσθετε καθυστέρηση/πολυπλοκότητα χωρίς σταθερό όφελος.
- Root cause: Το fallback polling για late stage snapshot μπορούσε να δημιουργεί μη ντετερμινιστική συμπεριφορά σε edge timing windows.
- Guardrail: Αφαίρεση `auto-recover` path από `rcp.ps1` και επιστροφή σε strict fail-closed συμβόλαιο (`NoListAvailable` όταν δεν υπάρχει έτοιμο staged list).
- Files affected: `Robocopy/rcp.ps1` (sync σε `D:\Users\joty79\scripts\Robocopy\rcp.ps1` και `MoveTo/Robocopy/rcp.ps1`).
- Validation/tests: `Get-FileHash` equality check runtime/workspace + PowerShell parser validation και στα δύο `rcp.ps1`.

### 2026-02-20 - Uninstall self-elevates for HKCR cleanup

- Problem: Standard (non-admin) uninstall could leave menu entries because HKCR deletes fail without elevation.
- Root cause: `Install.ps1 -Action Uninstall` ran in current token and did not enforce elevation before registry cleanup.
- Guardrail/rule: Uninstall action must relaunch itself elevated (`pwsh.exe -Verb RunAs`) when not admin, then perform cleanup in elevated process.
- Files affected:
  - `Install.ps1`
  - `PROJECT_RULES.md`
- Validation/tests run:
  - PowerShell parser validation (`Parser::ParseFile`) passed for `Install.ps1`.

## Entry Template

## Entry Template
### YYYY-MM-DD - Short decision title
- Problem:
- Root cause:
- Guardrail/rule:
- Files affected:
- Validation/tests:

