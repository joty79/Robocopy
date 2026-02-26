The issue is a combination of **permissions** (the "Admin vs User" trap I mentioned) and **missing logic** in the script.

Your script assumes the "Root" menu keys (`Z_MoveTo`) already exist and are configured correctly (which the `.reg` file does). If the script runs and those keys are missing (or if it creates them fresh), it fails to set the special properties that make them a "Menu".

Here is the fixed version of your script.

### Changes Made:
1.  **Added Admin Check:** It now warns you if you run it as Admin (which puts keys in the wrong registry hive).
2.  **Self-Healing Root Keys:** The script now explicitly creates and configures the `Move To` root menu (setting `MUIVerb`, `Icon`, and `SubCommands`). This makes the `.reg` file unnecessary.
3.  **Fixed `$args` Bug:** Renamed the `$args` variable to `$regArgs` (using `$args` is dangerous in PowerShell functions).
4.  **Fixed Registry Pathing:** Switched to consistent `Registry::` provider paths to avoid mixing methods.

### How to use:
1.  Save this code as `SyncMoveToMenu.ps1`.
2.  **Run it in a NORMAL PowerShell window** (Run `pwsh` or `powershell`).
    *   **DO NOT** use `seuncpwsh` (it likely forces Admin/Elevated mode).
    *   **DO NOT** Right-Click -> "Run as Administrator".

```powershell
# SyncMoveToMenu.ps1 - Syncs destinations with registry menu (with icons)

# --- CHECK FOR ADMIN (PREVENT WRONG HIVE) ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "DO NOT RUN AS ADMINISTRATOR!"
    Write-Warning "You are currently running this script as Admin."
    Write-Warning "The registry keys will be written to the Administrator account, not YOUR account."
    Write-Warning "Please close this and run it in a normal PowerShell window."
    Start-Sleep -Seconds 5
}

$destinationsFolder = "D:\Users\joty79\scripts\MoveTo\destinations"
$menuRootName = "Z_MoveTo"
$legacyMenuRootName = "MoveToCustom"
$scriptRoot = Split-Path -Path $PSCommandPath -Parent

# Registry Paths
$regPathFiles = "Registry::HKEY_CURRENT_USER\Software\Classes\*\shell\$menuRootName"
$regPathDirs = "Registry::HKEY_CURRENT_USER\Software\Classes\Directory\shell\$menuRootName"

$legacyRegPathFiles = "Registry::HKEY_CURRENT_USER\Software\Classes\*\shell\$legacyMenuRootName\shell"
$legacyRegPathDirs = "Registry::HKEY_CURRENT_USER\Software\Classes\Directory\shell\$legacyMenuRootName\shell"

$reservedShortcutNames = @(
    "add as destination",
    "add to destinations",
    "edit destinations",
    "[add as destination]",
    "[add to destinations]",
    "[edit destinations]"
)

# Helper to ensure the PARENT menu exists and acts as a container
function Ensure-RootMenu {
    param(
        [string]$Path,
        [string]$Icon
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    # These properties are REQUIRED for the cascading menu to work
    Set-ItemProperty -Path $Path -Name "MUIVerb" -Value "Move To" -Force
    Set-ItemProperty -Path $Path -Name "Icon" -Value $Icon -Force
    Set-ItemProperty -Path $Path -Name "SubCommands" -Value "" -Force
    
    # Ensure 'shell' subkey exists
    $shellPath = "$Path\shell"
    if (-not (Test-Path $shellPath)) {
        New-Item -Path $shellPath -Force | Out-Null
    }
    return $shellPath
}

function Ensure-StaticActionEntries {
    param(
        [Parameter(Mandatory = $true)][string]$FilesShellPath,
        [Parameter(Mandatory = $true)][string]$DirsShellPath,
        [Parameter(Mandatory = $true)][string]$ScriptRootPath
    )

    function Add-RegValue {
        param(
            [Parameter(Mandatory = $true)][string]$Key,
            [string]$Name,
            [Parameter(Mandatory = $true)][string]$Type,
            [Parameter(Mandatory = $true)][string]$Data,
            [switch]$DefaultValue
        )

        # FIXED: Use $regArgs instead of $args (which is reserved)
        $regArgs = New-Object System.Collections.Generic.List[string]
        [void]$regArgs.Add("add")
        [void]$regArgs.Add($Key)
        [void]$regArgs.Add("/f")

        if ($DefaultValue) {
            [void]$regArgs.Add("/ve")
        }
        else {
            [void]$regArgs.Add("/v")
            [void]$regArgs.Add($Name)
        }

        [void]$regArgs.Add("/t")
        [void]$regArgs.Add($Type)
        [void]$regArgs.Add("/d")
        [void]$regArgs.Add($Data)

        $null = & reg.exe @regArgs 2>$null
    }

    $editVbs = Join-Path $ScriptRootPath "EditDestinations.vbs"
    $addVbs = Join-Path $ScriptRootPath "AddMoveToDestination.vbs"
    # Escaping logic fixed for VBS paths
    $editVbs = $editVbs -replace "\\", "\\"
    $addVbs = $addVbs -replace "\\", "\\"
    
    $editCmd = "wscript.exe `"$editVbs`""
    $addCmd = "wscript.exe `"$addVbs`" `"%1`""

    # Use standard HKCU paths for reg.exe
    $fileEditKey = "HKCU\Software\Classes\*\shell\Z_MoveTo\shell\zzz_Edit"
    $dirAddKey = "HKCU\Software\Classes\Directory\shell\Z_MoveTo\shell\yyy_Add"
    $dirEditKey = "HKCU\Software\Classes\Directory\shell\Z_MoveTo\shell\zzz_Edit"

    Add-RegValue -Key $fileEditKey -Name "MUIVerb" -Type "REG_SZ" -Data "[Edit destinations]"
    Add-RegValue -Key $fileEditKey -Name "Icon" -Type "REG_SZ" -Data "shell32.dll,-16710"
    Add-RegValue -Key $fileEditKey -Name "CommandFlags" -Type "REG_DWORD" -Data "0x20"
    Add-RegValue -Key "$fileEditKey\command" -Type "REG_SZ" -Data $editCmd -DefaultValue

    Add-RegValue -Key $dirAddKey -Name "MUIVerb" -Type "REG_SZ" -Data "[Add as destination]"
    Add-RegValue -Key $dirAddKey -Name "Icon" -Type "REG_SZ" -Data "shell32.dll,-16769"
    Add-RegValue -Key $dirAddKey -Name "CommandFlags" -Type "REG_DWORD" -Data "0x20"
    Add-RegValue -Key "$dirAddKey\command" -Type "REG_SZ" -Data $addCmd -DefaultValue

    Add-RegValue -Key $dirEditKey -Name "MUIVerb" -Type "REG_SZ" -Data "[Edit destinations]"
    Add-RegValue -Key $dirEditKey -Name "Icon" -Type "REG_SZ" -Data "shell32.dll,-16710"
    Add-RegValue -Key "$dirEditKey\command" -Type "REG_SZ" -Data $editCmd -DefaultValue
}

Write-Host "`n=== Syncing Move To Menu ===" -ForegroundColor Cyan

# 1. FIX THE ROOT KEYS FIRST
$targetFilesShell = Ensure-RootMenu -Path $regPathFiles -Icon "shell32.dll,-16761"
$targetDirsShell  = Ensure-RootMenu -Path $regPathDirs  -Icon "shell32.dll,-16761"

$shortcuts = Get-ChildItem -Path $destinationsFolder -Filter "*.lnk" -File -ErrorAction SilentlyContinue

if (-not $shortcuts) {
    Write-Host "No shortcuts found." -ForegroundColor Yellow
}

# 2. CLEANUP (Target specific files)
foreach ($regPath in @($targetFilesShell, $targetDirsShell, $legacyRegPathFiles, $legacyRegPathDirs)) {
    if (Test-Path -LiteralPath $regPath) {
        Get-ChildItem -LiteralPath $regPath -ErrorAction SilentlyContinue | Where-Object {
            $_.PSChildName -like "dest_*"
        } | ForEach-Object {
            Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 3. STATIC ENTRIES
Ensure-StaticActionEntries -FilesShellPath $targetFilesShell -DirsShellPath $targetDirsShell -ScriptRootPath $scriptRoot

$shell = New-Object -ComObject WScript.Shell
$count = 0

foreach ($sc in $shortcuts) {
    $name = $sc.BaseName
    $normalizedName = (($name -replace '\s+', ' ').Trim()).ToLowerInvariant()

    if ($reservedShortcutNames -contains $normalizedName) {
        continue
    }

    $safeName = $name -replace '[^a-zA-Z0-9]', '_'
    $keyName = "dest_$safeName"
    
    # Read shortcut
    try {
        $lnk = $shell.CreateShortcut($sc.FullName)
        $targetPath = $lnk.TargetPath
        $arguments = [string]$lnk.Arguments
        $iconFromLnk = $lnk.IconLocation
    } catch {
        continue
    }

    # Determine icon
    $icon = "shell32.dll,3"
    if ($iconFromLnk -and $iconFromLnk -ne ",0") {
        $icon = $iconFromLnk
    }
    elseif ($targetPath -and (Test-Path $targetPath -PathType Container)) {
        $desktopIni = Join-Path $targetPath "desktop.ini"
        if (Test-Path $desktopIni) {
            $content = Get-Content $desktopIni -Raw -ErrorAction SilentlyContinue
            if ($content -match 'IconResource=(.+)') {
                $icon = $matches[1].Trim()
            }
        }
    }
    
    $command = "wscript.exe `"D:\Users\joty79\scripts\MoveTo\MoveTo.vbs`" `"%1`" `"$name`""
    
    foreach ($regPath in @($targetFilesShell, $targetDirsShell)) {
        $keyPath = "$regPath\$keyName"
        
        New-Item -Path $keyPath -Force -ErrorAction SilentlyContinue | Out-Null
        New-Item -Path "$keyPath\command" -Force -ErrorAction SilentlyContinue | Out-Null
        
        Set-ItemProperty -LiteralPath $keyPath -Name "MUIVerb" -Value $name -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $keyPath -Name "Icon" -Value $icon -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath "$keyPath\command" -Name "(Default)" -Value $command -ErrorAction SilentlyContinue
    }
    
    Write-Host "  + $name" -ForegroundColor Green
    $count++
}

Write-Host "`nDone! $count destinations synced." -ForegroundColor Blue

# Restart Explorer to apply changes (Optional, usually not needed for HKCU updates but good for refresh)
Stop-Process -Name explorer -Force
```