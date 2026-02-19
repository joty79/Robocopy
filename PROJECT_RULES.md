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
