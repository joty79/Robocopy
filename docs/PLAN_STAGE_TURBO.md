# Robocopy Stage Turbo - Progress Tracker
Date: 2026-02-13
Project: D:\Users\joty79\scripts\Robocopy

## Goal
- [ ] Reduce stage bottleneck for large multi-selection while keeping reliability parity.

## Phase 1 - Telemetry Baseline
- [x] Add stage timing logs in `rcopySingle.ps1` (`SelectionReadMs`, `DedupeMs`, `PersistFileMs`, `PersistRegistryMs`, `TotalStageMs`).
- [x] Add paste telemetry in `rcp.ps1` (`StageFormat`, `StagedCount`, `MissingAtPasteCount`).
- [ ] Validate no behavior change after telemetry-only checkpoint.

## Phase 2 - Fast Stage Ingest
- [x] Replace heavy dedupe with raw string dedupe (`HashSet`, case-insensitive).
- [x] Remove per-item `Resolve-Path` / `Test-Path` from stage loop.
- [x] Tune selection retry/stability constants for faster converge.
- [ ] Validate copy/cut staging still stable for mixed selections.

## Phase 3 - Fast Stage Persist (V2 Format)
- [x] Replace JSON stage write with line-based V2 format using `.NET StreamWriter`.
- [x] Keep atomic temp-write + rename.
- [x] Keep file names/paths safe with UTF-8 output.
- [ ] Validate stage snapshot creation under rapid repeated invokes.

## Phase 4 - Reader Compatibility in `rcp.ps1`
- [x] Add V2 reader path.
- [x] Add fallback legacy JSON reader.
- [x] Remove eager filesystem validation in snapshot read path.
- [x] Keep existence/type checks in transfer phase only.
- [ ] Validate no regression in move/delete-after-success logic.

## Phase 5 - Backend/Sync Rules
- [x] In `file` backend: registry sync metadata-only.
- [x] In `registry` backend: keep full item writes unchanged.
- [ ] Validate both backends (`file`, `registry`) end-to-end.

## Phase 6 - Docs and Rules
- [x] Update `README.md` with V2 format + dual-reader compatibility notes.
- [x] Create/update `PROJECT_RULES.md` with critical fix entry.
- [x] Record root cause, guardrail, files changed, validation summary.

## Phase 7 - Test Matrix
- [ ] Single file copy.
- [ ] Single folder copy.
- [ ] Mixed file+folder copy.
- [ ] Single file move.
- [ ] Single folder move.
- [ ] Multi-source parent selection.
- [ ] 100 items benchmark.
- [ ] 1000 items benchmark.
- [ ] 5000 items benchmark.
- [ ] Conflict destination scenarios.
- [ ] Extreme race scenario (copy again before paste finishes).
- [ ] Path edge cases (spaces, `[]`, long names, unicode).

## Acceptance Criteria
- [ ] Reliability parity in normal usage (<1000 items).
- [ ] ~1000 items stage latency under 2s (typical SSD setup).
- [ ] ~5000 items stage latency under 8s (typical SSD setup).
- [ ] Legacy JSON stage snapshots still readable.
- [ ] Logs are sufficient for root-cause debugging.

## Gemini Mirror Sync (per checkpoint/commit)
- [x] `rcopySingle.ps1` -> `D:\Users\joty79\scripts\MoveTo\gemini\rcopySingle.ps1.txt`
- [x] `rcp.ps1` -> `D:\Users\joty79\scripts\MoveTo\gemini\rcp.ps1.txt`
- [ ] `RoboCopy_Silent.vbs` -> `D:\Users\joty79\scripts\MoveTo\gemini\RoboCopy_Silent.vbs.txt` (only if changed)
- [ ] `RoboPaste_Admin.vbs` -> `D:\Users\joty79\scripts\MoveTo\gemini\RoboPaste_Admin.vbs.txt` (only if changed)
- [ ] `RoboCopy_StandAlone.reg` -> `D:\Users\joty79\scripts\MoveTo\gemini\RoboCopy_StandAlone.reg.txt` (only if changed)

## Checkpoint Log
- [x] Checkpoint 1 completed
- [ ] Checkpoint 2 completed
- [ ] Checkpoint 3 completed
- [ ] Checkpoint 4 completed
