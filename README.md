# RoboCopy Context Menu Implementation

This folder contains a standalone Windows context-menu workflow based on `robocopy`:
- `Robo-Copy` (stage source folder for copy)
- `Robo-Cut` (stage source folder for move)
- `Robo-Paste` (execute copy/move into target folder)

The core engine is `rcp.ps1`.

## Components

- `RoboCopy_StandAlone.reg`
  - Registers context-menu entries under `HKEY_CLASSES_ROOT\Directory\...`.
  - Wires commands to VBS wrappers.
- `RoboCopy_Silent.vbs`
  - Hidden launcher for staging (`Robo-Copy` / `Robo-Cut`).
  - Calls `rcopySingle.ps1` with `pwsh.exe`.
- `rcopySingle.ps1`
  - Stores selected source folder path in registry (`HKCU:\RCWM\rc` or `HKCU:\RCWM\mv`).
  - One staging slot per mode (copy/move).
- `RoboPaste_Admin.vbs`
  - Elevated launcher for paste.
  - Opens `wt.exe` as admin and runs `rcp.ps1`.
- `rcp.ps1`
  - Reads staged folders from registry and executes `robocopy`.
  - Handles overwrite/merge prompt when destination folder already exists.
  - Prints benchmark output in the paste window (per folder + session summary).
- `RoboTune.ps1`
  - Interactive tuning UI for MT rules, benchmark mode, and extra robocopy args.
  - Saves tuning in `RoboTune.json`.

## Execution Flow

1. Right-click source folder -> `Robo-Copy` or `Robo-Cut`.
2. `RoboCopy_Silent.vbs` runs `rcopySingle.ps1` hidden.
3. `rcopySingle.ps1` writes source path into:
   - `HKCU:\RCWM\rc` for copy
   - `HKCU:\RCWM\mv` for move
4. Right-click destination folder (or background) -> `Robo-Paste`.
5. `RoboPaste_Admin.vbs` starts elevated `wt.exe`, running:
   - `pwsh -File rcp.ps1 auto auto "<destination>"`
6. `rcp.ps1` auto-detects active mode (`rc` or `mv`) by checking registry properties.
7. For each staged source folder:
   - Builds destination as `<pasteTarget>\<sourceFolderName>`
   - Runs `robocopy` with multi-thread flags
   - If move mode, deletes source folder after copy (`rd /s /q`)
8. Clears staging registry entries at the end.

## robocopy Behavior in `rcp.ps1`

Base flags used:
- `/E /NP /NJH /NJS /NC /NS`

Move mode adds:
- `/MOV`

`/MT` is now selected automatically per source/destination path:
- `8` threads: any `HDD`, network path, or same physical disk
- `32` threads: `SSD -> SSD`
- `16` threads: fallback for unknown/mixed local media

Optional override:
- set env var `RCWM_MT` (range `1..128`) to force a fixed thread count.
- use `RoboTune.json` for route-specific MT and default MT rules.

If destination folder already exists, script prompts:
- `Enter`: overwrite-style pass (normal flag set)
- `M`: merge mode using `/XC /XN /XO` (skip changed/newer/older files)
- `Esc`: abort remaining operations

## Registry Model

- Staging keys:
  - `HKCU:\RCWM\rc`
  - `HKCU:\RCWM\mv`
- The source folder paths are stored as property names on these keys.
- Paste step reads key property names as source list, then clears them.

## Requirements

- Windows with `robocopy.exe` (`C:\Windows\System32\robocopy.exe`)
- PowerShell 7 (`pwsh.exe`)
- Windows Script Host (`wscript.exe`)
- Windows Terminal (`wt.exe`) for elevated paste flow
- Write access to current user registry (`HKCU`)

## Important Notes / Limitations

- Current implementation is folder-oriented (context menu is on `Directory` keys).
- Registry and script paths are hardcoded to `D:\Users\joty79\scripts\Robocopy\...`.
  - In this repo, files are under `D:\Users\joty79\scripts\MoveTo\Robocopy\...`.
  - Update `.reg` and `.vbs` paths before using.
- `Robo-Paste` is forced to run elevated (`runas`), so UAC prompt is expected.
- A script comment notes a potential issue with folder names starting with `0` (registry/value-name edge case).

## Quick Validation Checklist

1. Apply `.reg` after fixing absolute paths.
2. Stage one folder with `Robo-Copy`, then paste into test destination.
3. Repeat with `Robo-Cut` and confirm source removal.
4. Test collision behavior:
   - existing destination folder
   - `Enter` vs `M` vs `Esc`
5. Verify registry cleanup under `HKCU:\RCWM\rc` and `HKCU:\RCWM\mv` after completion.
6. Validate benchmark lines in paste output (when benchmark mode is ON):
   - `Result: ExitCode=...`
   - `Benchmark: Files=... Data=... Time=... Throughput...`
   - `=== Session Benchmark ===`

## Thread-Tuning Test Commands

Use probe mode to validate the chosen `/MT` without copying files:

```powershell
pwsh -NoProfile -File .\Robocopy\rcp.ps1 __mtprobe "D:\SourceFolder" "E:\DestinationFolder"
```

You can compare scenarios quickly:
- `NVMe -> NVMe`
- `NVMe -> HDD`
- `HDD -> HDD`
- same-drive vs different-drive letter

## Interactive Tuning Window

Run:

```powershell
pwsh -NoProfile -File .\Robocopy\RoboTune.ps1
```

Menu actions:
- add/update per-route MT (example: `E -> D = 64`)
- remove route overrides
- set `default_mt`
- set extra robocopy args (example: `/R:0 /W:0`)
- toggle benchmark mode

Benchmark mode behavior:
- `ON`: benchmark metrics enabled + paste window stays open at end.
  - End hotkeys: `Enter` close, `Esc` close, `T` open `RoboTune.ps1`.
- `OFF`: benchmark metrics disabled and window closes as before.

`rcp.ps1` auto-loads `RoboTune.json` on each paste run.
