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
