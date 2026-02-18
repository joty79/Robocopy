# RoboCopy Installer v1

Ο installer είναι το `Install.ps1` και υποστηρίζει `Install`, `Update`, `Uninstall`.

## Default Install Target

- `%LOCALAPPDATA%\RoboCopyContext`
- Registry scope: `HKCU` μόνο.

## Interactive Usage

Τρέξε χωρίς arguments για visual menu:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

Menu επιλογές:
- `Install`
- `Update`
- `Uninstall`
- `Exit`

## CLI Usage

```powershell
# Install
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action Install

# Update existing install
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action Update

# Uninstall
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Action Uninstall
```

Optional flags:
- `-InstallPath "<custom path>"`
- `-SourcePath "<package path>"`
- `-Force`
- `-NoExplorerRestart`

## What Installer Writes

- Files to install root:
  - `rcp.ps1`
  - `rcopySingle.ps1`
  - `RoboCopy_Silent.vbs`
  - `RoboPaste_Admin.vbs`
  - `RoboTune.ps1`
  - `RoboTune.json`
  - `assets\Cut.ico`, `assets\Copy.ico`, `assets\Paste.ico`
  - `Install.ps1`
- State/log folders:
  - `state\`
  - `state\staging\`
  - `logs\`
- Metadata file:
  - `state\install-meta.json`

## Registry Model

Installer κάνει cleanup-first και μετά γράφει:

- Files:
  - `HKCU\Software\Classes\*\shell\Y_10_RoboCut`
  - `HKCU\Software\Classes\*\shell\Y_11_RoboCopy`
- Folders:
  - `HKCU\Software\Classes\Directory\shell\Y_10_RoboCut`
  - `HKCU\Software\Classes\Directory\shell\Y_11_RoboCopy`
  - `HKCU\Software\Classes\Directory\shell\Y_12_RoboPaste`
- Folder background:
  - `HKCU\Software\Classes\Directory\Background\shell\Y_12_RoboPaste`

Commands δείχνουν πάντα στα installed wrappers.

## Dependencies

Required:
- `pwsh.exe`
- `wscript.exe`
- `robocopy.exe`

Optional:
- none (paste wrapper uses elevated `pwsh.exe` directly).

## Migration

One-time migration από `D:\Users\joty79\scripts\Robocopy`:
- Migrates: `RoboTune.json`, `logs\*`, safe `state` metadata.
- Skips: `state\staging\*.stage.json` (για να αποφευχθεί stale paste).

## Uninstall Integration

Γράφεται uninstall entry στο:

- `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\RoboCopyContext`

με `UninstallString` που καλεί:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<InstallPath>\Install.ps1" -Action Uninstall -Force
```

## Exit Codes

- `0`: success
- `1`: preflight/dependency failure
- `2`: success with warnings
- `3`: uninstall failure
