# RoboCopy Context Menu Implementation

This folder contains a standalone Windows context-menu workflow based on `robocopy`:
- `Robo-Copy` (stage selected files/folders for copy)
- `Robo-Cut` (stage selected files/folders for move)
- `Robo-Paste` (execute copy/move into target folder)

The core engine is `rcp.ps1`.

Permanent delete is now handled only by `NuclearDelete\NuclearDeleteFolder.ps1`.

## Components

- `Install.ps1`
  - Per-user installer (`Install`, `Update`, `Uninstall`).
  - Supports package source modes:
    - `Local` (default): deploy from current source folder.
    - `GitHub`: download package zip from repo/ref and deploy/update directly.
  - If `RoboTune.json` is missing in downloaded package, installer auto-creates a safe default config.
  - Installs runtime files into `%LOCALAPPDATA%\RoboCopyContext`.
  - Writes dynamic context-menu registry entries under `HKCU\Software\Classes\...`.
  - Registers uninstall entry in Apps & Features (HKCU uninstall key).
- `RoboCopy_StandAlone.reg`
  - Legacy/manual registry script.
  - Installer flow is recommended for directory-independent setup.
- `RoboCopy_Silent.vbs`
  - Hidden launcher for staging (`Robo-Copy` / `Robo-Cut`).
  - Calls `rcopySingle.ps1` with `pwsh.exe -NoProfile`.
  - Uses a short-lived lock file (`state\stage.lock`) so only one hidden staging `pwsh` starts per multi-select burst.
  - Uses a burst marker (`state\stage.burst`) to suppress duplicate mixed-selection invokes from the same parent folder.
- `rcopySingle.ps1`
  - Captures full Explorer selection from the active parent window (files + folders) with short retries.
  - Uses a named mutex (`Global\MoveTo_RoboCopy_Stage`) to serialize concurrent staging writes.
  - Uses a short session window to append per-item invokes into one staged set.
  - Stores staged source paths in `state\staging\rc.stage.json` / `state\staging\mv.stage.json` using a fast flat `V2` line-based payload (atomic temp-write + rename).
  - Uses fixed `file` staging backend for safety and consistency.
  - Writes diagnostics/telemetry to `logs\stage_log.txt` (`SelectionReadMs`, `DedupeMs`, `PersistFileMs`, `PersistRegistryMs`, `TotalStageMs`).
- `RoboPaste_Admin.vbs`
  - Elevated launcher for paste.
  - Opens elevated `pwsh.exe` and runs `rcp.ps1` with `-NoProfile`.
- `rcp.ps1`
  - Reads staged files/folders from file staging snapshots and executes `robocopy`.
  - Clears the staging burst marker (`state\stage.burst`) on paste exit paths, so immediate next copy/cut is not suppressed.
  - Handles overwrite/merge prompt when destination item already exists.
  - Prints benchmark output in the paste window (per folder + session summary).
- `RoboTune.ps1`
  - Interactive tuning UI for MT rules, benchmark mode, debug mode, hold-window behavior, and extra robocopy args.
  - Saves tuning in `RoboTune.json`.

## Execution Flow

0. Run installer once:
   - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1`
   - or install directly from GitHub:
     - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action InstallGitHub -Force`
     - optional overrides:
       - `-GitHubRepo "joty79/Robocopy"`
       - `-GitHubRef "master"`
       - `-GitHubZipUrl "https://..."` (explicit archive URL)
   - Default install root: `%LOCALAPPDATA%\RoboCopyContext`
1. Right-click selected source files/folders -> `Robo-Copy` or `Robo-Cut`.
2. `RoboCopy_Silent.vbs` acquires staging lock and runs one hidden `rcopySingle.ps1` instance.
   - if the previous stage from the same parent folder was a multi-item selection in the last few seconds, duplicate invokes are skipped.
3. `rcopySingle.ps1` writes stage snapshot into:
   - `state\staging\rc.stage.json` for copy
   - `state\staging\mv.stage.json` for move
   - file format is `V2` line payload (`V2|command|session|utc|expected|anchor_parent` + one path per line)
4. Right-click destination folder (or background) -> `Robo-Paste`.
5. `RoboPaste_Admin.vbs` starts elevated `pwsh.exe`, running:
   - `pwsh -File rcp.ps1 auto auto "<destination>"`
6. `rcp.ps1` auto-detects active mode (`rc` or `mv`) from staged file snapshots.
7. For each staged source item:
   - Builds destination as `<pasteTarget>\<sourceName>`
   - If source is folder, runs folder robocopy flow (`/E`).
   - If source is file, groups files by source parent and runs batched file-filter robocopy calls (chunked to avoid command-length limits).
   - If move mode, deletes source item only after successful transfer.
8. Clears the consumed stage payload at the end.

## robocopy Behavior in `rcp.ps1`

Base flags used:
- `/E /NP /NJH /NJS /NC /NS`
- Normal mode adds `/NFL /NDL` to reduce per-file console overhead on large multi-select runs.

Move mode adds:
- `/MOV`

`/MT` is selected per this priority order:
- `RCWM_MT` env override (if set)
- `mt_rules` media-combo map (auto fallback)

Default `mt_rules`:
- `ssd_to_ssd = 32`
- `ssd_hdd_any = 8`
- `hdd_to_hdd_diff_volume = 8`
- `hdd_to_hdd_same_volume = 8`
- `lan_any = 8`
- `usb_any = 8`

Optional override:
- set env var `RCWM_MT` (range `1..128`) to force a fixed thread count.
- use `RoboTune.json` for media `mt_rules`.

If destination folder already exists, script prompts:
- `Enter`: overwrite-style pass (normal flag set)
- `M`: merge mode using `/XC /XN /XO` (skip changed/newer/older files)
- `Esc`: abort remaining operations

## Staging Model

- Backend is fixed to `file`.
  - Stage files: `state\staging\rc.stage.json`, `state\staging\mv.stage.json`
  - Uses flat `V2` line payload for fast staging writes.
  - `rcp.ps1` keeps backward compatibility and can still read legacy JSON snapshots.

## Requirements

- Windows with `robocopy.exe` (`C:\Windows\System32\robocopy.exe`)
- PowerShell 7 (`pwsh.exe`)
- Windows Script Host (`wscript.exe`)
- `pwsh.exe` is used directly for elevated paste launch (no `wt.exe` dependency)
- Write access to script `state` folder

## Logs

- `logs\stage_log.txt` (staging telemetry)
- `logs\run_log.txt` (paste run telemetry)
- `logs\error_log.txt` (fatal errors)
- `logs\robocopy_debug.log` (only when debug mode is ON)

## Important Notes / Limitations

- Copy/Cut are registered on `AllFilesystemObjects` with `MultiSelectModel=Document` for reliable file/folder multi-select.
- Installer mode is directory-independent:
  - commands point to installed scripts under `%LOCALAPPDATA%\RoboCopyContext\...`.
  - no source-repo absolute path dependency after install.
- `Robo-Paste` is forced to run elevated (`runas`), so UAC prompt is expected.
- A script comment notes a potential issue with folder names starting with `0` (registry/value-name edge case).

## Quick Validation Checklist

1. Run installer:
   - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1`
   - GitHub install/update:
     - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action InstallGitHub -Force`
     - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action UpdateGitHub -Force`
2. Stage one folder with `Robo-Copy`, then paste into test destination.
3. Stage one file with `Robo-Copy`, then paste into test destination.
4. Repeat with `Robo-Cut` and confirm source removal (file + folder).
5. Test collision behavior:
   - existing destination folder
   - `Enter` vs `M` vs `Esc`
6. Verify staged payload cleanup after completion:
   - file backend: `state\staging\*.stage.json` removed
   - registry backend: `HKCU:\RCWM\rc` / `HKCU:\RCWM\mv` cleared
7. Validate benchmark lines in paste output (when benchmark mode is ON):
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
- set media MT rules (`mt_rules`) per SSD/HDD/LAN/USB combo
- set extra robocopy args (example: `/R:0 /W:0`)
- toggle benchmark mode
- toggle debug mode
- toggle hold window

Benchmark mode behavior:
- `ON`: benchmark metrics enabled + paste window stays open at end.
  - End hotkeys: `Enter` close, `Esc` close, `T` open `RoboTune.ps1`.
- `OFF`: benchmark metrics disabled and window closes as before.

Debug mode behavior:
- `ON`: appends detailed robocopy output to `logs\robocopy_debug.log` and mirrors it in the console (`/TEE`).
- adds detailed flags automatically when missing: `/V /TS /FP /BYTES`.
- `OFF`: no extra debug flags or debug log from this mode.

Performance notes:
- Stage phase uses lazy validation (raw path ingest + dedupe) and defers deep filesystem checks to paste phase.
- File multi-select is grouped by source directory and passed to robocopy in larger filename batches (command-line safe chunking).
- Folder copy/cut remains the fastest path because it executes directory-level robocopy flow.
- Large selection/conflict previews are truncated in normal mode to reduce console rendering overhead.
- Context-menu single mode now uses a direct fast path (no pre-scan conflict prompt). Manual mode keeps the interactive conflict prompt.
- If selected files are exactly all top-level files of a source folder, a wildcard fast-path (`*`) is used to reduce batch count and improve speed.

`rcp.ps1` auto-loads `RoboTune.json` on each paste run.
