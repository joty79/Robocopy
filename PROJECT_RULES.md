# PROJECT_RULES

## Critical Decisions

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
