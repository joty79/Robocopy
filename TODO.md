# TODO

- [x] Add `same-volume move` fast path for `cut` operations.
  - Scope: only when source and destination are in the same volume.
  - Engine: use native move/rename path (not robocopy copy+delete flow).
  - Guardrails: keep existing safety checks and protected path rules.
  - Validation: benchmark against current robocopy move flow for large files and folder trees.

- [x] Fix Desktop multi-select reliability (wallpaper Desktop + real Desktop folder window).
  - Validation: Desktop multi-select tested and confirmed working.

- [ ] Add `single-file` fast path in main runtime (skip full orchestration when safe).
  - Trigger: exactly one staged file item.
  - Goal: reduce fixed startup tax observed in benchmarks.
  - Keep fallback to universal flow for unsupported/conflict-heavy cases.

- [ ] Add `single-folder` fast path in main runtime (skip full orchestration when safe).
  - Trigger: exactly one staged folder item.
  - Goal: reduce fixed startup tax observed in benchmarks.
  - Keep fallback to universal flow for unsupported/conflict-heavy cases.

- [ ] Add dedicated `Search Results` route (do not touch normal folder/Desktop flow).
  - Detect search context (`search-ms` / virtual view) in selection capture.
  - Route Search Results to separate handling path; keep default flow unchanged.
  - Requirement: zero regression for normal folder/Desktop operations.

- [ ] Decide `mixed-parent` policy for Search Results selections.
  - Option A (safe default): reject mixed-parent selection with clear message.
  - Option B (full support): group items by parent and execute one transfer per parent group.
  - Validation: confirm no partial copy and no anchor-only silent behavior.

- [ ] Handle mapped network drives in elevated paste flow (`Z:` visibility issue).
  - Root cause: elevated token may not see user mapped drives.
  - Implement: normalize mapped drive paths to UNC (`\\server\share\...`) before transfer.
  - Goal: same behavior for mapped drive and UNC paths without requiring `EnableLinkedConnections`.

- [ ] P0 safety: prevent unintended scope expansion in cut/copy flows.
  - Observed failure mode: staging/copy from `C:\` resolved unexpectedly to `C:\Users\joty79`.
  - Observed failure mode: cut of a single intended item led to moving a broader parent scope (`C:\Users\joty79`).
  - Required behavior: operations must execute only on explicitly staged items; never infer/expand to parent/root silently.
  - Required behavior: cut must be all-or-nothing for the staged set (no hidden extra items, no partial unintended scope).
  - Validation: reproduce original scenario and confirm deterministic source list before transfer execution.
