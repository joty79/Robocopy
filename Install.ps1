#requires -version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall', 'InstallGitHub', 'UpdateGitHub')]
    [string]$Action = 'Install',
    [string]$InstallPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'RoboCopyContext'),
    [string]$SourcePath = $PSScriptRoot,
    [ValidateSet('Local', 'GitHub')]
    [string]$PackageSource = 'Local',
    [string]$GitHubRepo = 'joty79/Robocopy',
    [string]$GitHubRef = 'master',
    [string]$GitHubZipUrl = '',
    [switch]$Force,
    [switch]$NoExplorerRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '1.0.0'
$script:LegacyRoot = 'D:\Users\joty79\scripts\Robocopy'
$script:UninstallKeyPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\RoboCopyContext'
$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:TempPackageRoots = [System.Collections.Generic.List[string]]::new()

function Resolve-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    [System.IO.Path]::GetFullPath($Path.Trim())
}

$InstallPath = Resolve-NormalizedPath -Path $InstallPath
$SourcePath = Resolve-NormalizedPath -Path $SourcePath
$script:InstallerLogPath = Join-Path $InstallPath 'logs\installer.log'
$script:HasCliArgs = $MyInvocation.BoundParameters.Count -gt 0

function Add-Warning {
    param([Parameter(Mandatory)][string]$Message)
    $script:Warnings.Add($Message) | Out-Null
}

function Write-Banner {
    param([string]$Title = 'RoboCopy Context Installer')
    try {
        Clear-Host
    }
    catch {
        # Non-interactive hosts may not support cursor operations used by Clear-Host.
    }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('  {0}  v{1}' -f $Title, $script:InstallerVersion) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}

function Write-Step {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host ('[>] {0}' -f $Text) -ForegroundColor $Color
}

function Initialize-InstallerLog {
    try {
        $logDir = Split-Path -Path $script:InstallerLogPath -Parent
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
    }
    catch {
        $script:InstallerLogPath = Join-Path $env:TEMP 'RoboCopyContext-installer.log'
    }
}

function Write-InstallerLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = '{0} | {1} | {2}' -f $timestamp, $Level, $Message
    try { Add-Content -Path $script:InstallerLogPath -Value $line -Encoding UTF8 } catch {}

    switch ($Level) {
        'WARN' { Write-Step -Text $Message -Color Yellow; Add-Warning -Message $Message }
        'ERROR' { Write-Step -Text $Message -Color Red }
        default { Write-Step -Text $Message -Color DarkGray }
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Show-InteractiveMenu {
    while ($true) {
        Write-Banner
        Write-Host ('Source:  {0}' -f $SourcePath) -ForegroundColor DarkGray
        Write-Host ('Install: {0}' -f $InstallPath) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '[1] Install' -ForegroundColor Green
        Write-Host '[2] Update' -ForegroundColor Yellow
        Write-Host '[3] Install (GitHub)' -ForegroundColor Green
        Write-Host '[4] Update (GitHub)' -ForegroundColor Yellow
        Write-Host '[5] Uninstall' -ForegroundColor Red
        Write-Host '[0] Exit' -ForegroundColor Gray
        Write-Host ''
        $choice = (Read-Host 'Select option').Trim()
        switch ($choice) {
            '1' { return 'Install' }
            '2' { return 'Update' }
            '3' { return 'InstallGitHub' }
            '4' { return 'UpdateGitHub' }
            '5' { return 'Uninstall' }
            '0' { return 'Exit' }
            default {
                Write-Host 'Invalid option. Press any key...' -ForegroundColor Red
                [void][System.Console]::ReadKey($true)
            }
        }
    }
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($Force) { return $true }
    $answer = (Read-Host "$Prompt [y/N]").Trim().ToLowerInvariant()
    $answer -eq 'y'
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-Preflight {
    Write-Step -Text 'Running preflight checks...' -Color Cyan

    $required = @('pwsh.exe', 'wscript.exe', 'robocopy.exe')
    $missing = @()
    foreach ($cmd in $required) {
        if (-not (Test-CommandExists -Name $cmd)) {
            $missing += $cmd
        }
    }

    if ($missing.Count -gt 0) {
        Write-InstallerLog -Level ERROR -Message ("Missing required commands: {0}" -f ($missing -join ', '))
        return [pscustomobject]@{
            Ok = $false
            HasWindowsTerminal = $false
        }
    }

    $hasWt = Test-CommandExists -Name 'wt.exe'
    if (-not $hasWt) {
        Write-InstallerLog -Level WARN -Message 'wt.exe not found. Paste wrapper will use elevated pwsh fallback.'
    }
    else {
        Write-InstallerLog -Message 'wt.exe detected.'
    }

    return [pscustomobject]@{
        Ok = $true
        HasWindowsTerminal = $hasWt
    }
}

function Get-RegistryCleanupPaths {
    @(
        'HKCR\Directory\Background\shell\mvpaste',
        'HKCR\Directory\shell\mvdir',
        'HKCR\Directory\shell\rcopy',
        'HKCR\AllFilesystemObjects\shell\mvdir',
        'HKCR\AllFilesystemObjects\shell\rcopy',
        'HKCR\Directory\Background\shell\rpaste',
        'HKCR\Directory\shell\rpaste',
        'HKCU\Software\Classes\AllFilesystemObjects\shell\rcopy',
        'HKCU\Software\Classes\AllFilesystemObjects\shell\mvdir',
        'HKCU\Software\Classes\Directory\shell\rpaste',
        'HKCU\Software\Classes\Directory\Background\shell\rpaste',
        'HKCR\*\shell\Y_10_RoboCut',
        'HKCR\*\shell\Y_11_RoboCopy',
        'HKCR\Directory\shell\Y_10_RoboCut',
        'HKCR\Directory\shell\Y_11_RoboCopy',
        'HKCR\Directory\shell\Y_12_RoboPaste',
        'HKCR\Directory\Background\shell\Y_12_RoboPaste',
        'HKCU\Software\Classes\AllFilesystemObjects\shell\Y_10_RoboCut',
        'HKCU\Software\Classes\AllFilesystemObjects\shell\Y_11_RoboCopy',
        'HKCU\Software\Classes\Directory\shell\Y_10_RoboCut',
        'HKCU\Software\Classes\Directory\shell\Y_11_RoboCopy',
        'HKCU\Software\Classes\Directory\shell\Y_12_RoboPaste',
        'HKCU\Software\Classes\Directory\Background\shell\Y_12_RoboPaste',
        'HKCU\Software\Classes\*\shell\Y_10_RoboCut',
        'HKCU\Software\Classes\*\shell\Y_11_RoboCopy'
    )
}

function Invoke-RegCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments,
        [switch]$IgnoreNotFound
    )

    $output = & reg.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $text = ($output | Out-String).Trim()
        if ($IgnoreNotFound -and $text -match 'unable to find the specified registry key or value') {
            return $null
        }
        throw "reg.exe failed (exit $exitCode): reg $($Arguments -join ' ')`n$text"
    }
    return $output
}

function Add-RegStringValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $safeValue = if ($Value -eq '') { '""' } else { $Value }
    Invoke-RegCommand -Arguments @('add', $Key, '/v', $Name, '/t', 'REG_SZ', '/d', $safeValue, '/f') | Out-Null
}

function Add-RegDefaultValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $safeValue = if ($Value -eq '') { '""' } else { $Value }
    Invoke-RegCommand -Arguments @('add', $Key, '/ve', '/t', 'REG_SZ', '/d', $safeValue, '/f') | Out-Null
}

function Remove-RegTree {
    param([Parameter(Mandatory)][string]$Key)
    Invoke-RegCommand -Arguments @('delete', $Key, '/f') -IgnoreNotFound | Out-Null
}

function Get-RegStringValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name
    )
    $queryOutput = if ($Name -eq '(default)') {
        Invoke-RegCommand -Arguments @('query', $Key, '/ve') -IgnoreNotFound
    }
    else {
        Invoke-RegCommand -Arguments @('query', $Key, '/v', $Name) -IgnoreNotFound
    }

    if (-not $queryOutput) {
        return $null
    }

    $line = $queryOutput | Where-Object {
        $_ -match 'REG_' -and $_ -match '^\s*(\(Default\)|\S+)\s+REG_'
    } | Select-Object -First 1

    if (-not $line) {
        return $null
    }

    $parts = ($line -split '\s{2,}') | Where-Object { $_ -ne '' }
    if ($parts.Count -ge 3) {
        return $parts[2]
    }
    return ''
}

function Remove-RoboRegistryKeys {
    Write-InstallerLog -Message 'Cleaning old Robo registry keys...'
    foreach ($path in Get-RegistryCleanupPaths) {
        try {
            Remove-RegTree -Key $path
        }
        catch {
            Write-InstallerLog -Level WARN -Message ("Failed to remove key: {0}" -f $path)
        }
    }
}

function Set-RegistryDefault {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value
    )
    New-Item -Path $Path -Force | Out-Null
    Set-Item -Path $Path -Value $Value
}

function Set-RegistryString {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Write-RoboRegistry {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$CutIcon,
        [Parameter(Mandatory)][string]$CopyIcon,
        [Parameter(Mandatory)][string]$PasteIcon
    )

    Remove-RoboRegistryKeys

    $silentWrapper = Join-Path $InstallRoot 'RoboCopy_Silent.vbs'
    $pasteWrapper = Join-Path $InstallRoot 'RoboPaste_Admin.vbs'

    $cmdCut = "wscript.exe `"$silentWrapper`" mv `"%1`""
    $cmdCopy = "wscript.exe `"$silentWrapper`" `"%1`""
    $cmdPaste = "wscript.exe `"$pasteWrapper`" `"%V`""

    $fileCut = 'HKCU\Software\Classes\*\shell\Y_10_RoboCut'
    $fileCopy = 'HKCU\Software\Classes\*\shell\Y_11_RoboCopy'
    $folderCut = 'HKCU\Software\Classes\Directory\shell\Y_10_RoboCut'
    $folderCopy = 'HKCU\Software\Classes\Directory\shell\Y_11_RoboCopy'
    $folderPaste = 'HKCU\Software\Classes\Directory\shell\Y_12_RoboPaste'
    $bgPaste = 'HKCU\Software\Classes\Directory\Background\shell\Y_12_RoboPaste'

    Add-RegStringValue -Key $fileCut -Name 'MUIVerb' -Value 'Robo-Cut'
    Add-RegStringValue -Key $fileCut -Name 'NoWorkingDirectory' -Value ''
    Add-RegStringValue -Key $fileCut -Name 'MultiSelectModel' -Value 'Document'
    Add-RegStringValue -Key $fileCut -Name 'Icon' -Value $CutIcon
    Add-RegStringValue -Key $fileCut -Name 'SeparatorBefore' -Value ''
    Add-RegDefaultValue -Key "$fileCut\command" -Value $cmdCut

    Add-RegStringValue -Key $fileCopy -Name 'MUIVerb' -Value 'Robo-Copy'
    Add-RegStringValue -Key $fileCopy -Name 'NoWorkingDirectory' -Value ''
    Add-RegStringValue -Key $fileCopy -Name 'MultiSelectModel' -Value 'Document'
    Add-RegStringValue -Key $fileCopy -Name 'Icon' -Value $CopyIcon
    Add-RegStringValue -Key $fileCopy -Name 'SeparatorAfter' -Value ''
    Add-RegDefaultValue -Key "$fileCopy\command" -Value $cmdCopy

    Add-RegStringValue -Key $folderCut -Name 'MUIVerb' -Value 'Robo-Cut'
    Add-RegStringValue -Key $folderCut -Name 'NoWorkingDirectory' -Value ''
    Add-RegStringValue -Key $folderCut -Name 'MultiSelectModel' -Value 'Document'
    Add-RegStringValue -Key $folderCut -Name 'Icon' -Value $CutIcon
    Add-RegStringValue -Key $folderCut -Name 'SeparatorBefore' -Value ''
    Add-RegDefaultValue -Key "$folderCut\command" -Value $cmdCut

    Add-RegStringValue -Key $folderCopy -Name 'MUIVerb' -Value 'Robo-Copy'
    Add-RegStringValue -Key $folderCopy -Name 'NoWorkingDirectory' -Value ''
    Add-RegStringValue -Key $folderCopy -Name 'MultiSelectModel' -Value 'Document'
    Add-RegStringValue -Key $folderCopy -Name 'Icon' -Value $CopyIcon
    Add-RegDefaultValue -Key "$folderCopy\command" -Value $cmdCopy

    Add-RegStringValue -Key $folderPaste -Name 'MUIVerb' -Value 'Robo-Paste'
    Add-RegStringValue -Key $folderPaste -Name 'Icon' -Value $PasteIcon
    Add-RegStringValue -Key $folderPaste -Name 'HasLUAShield' -Value ''
    Add-RegStringValue -Key $folderPaste -Name 'SeparatorAfter' -Value ''
    Add-RegDefaultValue -Key "$folderPaste\command" -Value $cmdPaste

    Add-RegStringValue -Key $bgPaste -Name 'MUIVerb' -Value 'Robo-Paste'
    Add-RegStringValue -Key $bgPaste -Name 'Icon' -Value $PasteIcon
    Add-RegStringValue -Key $bgPaste -Name 'HasLUAShield' -Value ''
    Add-RegStringValue -Key $bgPaste -Name 'SeparatorBefore' -Value ''
    Add-RegStringValue -Key $bgPaste -Name 'SeparatorAfter' -Value ''
    Add-RegDefaultValue -Key "$bgPaste\command" -Value $cmdPaste
}

function Verify-RoboRegistry {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $silentWrapper = Join-Path $InstallRoot 'RoboCopy_Silent.vbs'
    $pasteWrapper = Join-Path $InstallRoot 'RoboPaste_Admin.vbs'
    $cmdCut = "wscript.exe `"$silentWrapper`" mv `"%1`""
    $cmdCopy = "wscript.exe `"$silentWrapper`" `"%1`""
    $cmdPaste = "wscript.exe `"$pasteWrapper`" `"%V`""

    $checks = @(
        @{ Key = 'HKCU\Software\Classes\*\shell\Y_10_RoboCut'; Name = 'MUIVerb'; Expected = 'Robo-Cut' },
        @{ Key = 'HKCU\Software\Classes\*\shell\Y_10_RoboCut\command'; Name = '(default)'; Expected = $cmdCut },
        @{ Key = 'HKCU\Software\Classes\*\shell\Y_11_RoboCopy\command'; Name = '(default)'; Expected = $cmdCopy },
        @{ Key = 'HKCU\Software\Classes\Directory\shell\Y_12_RoboPaste'; Name = 'MUIVerb'; Expected = 'Robo-Paste' },
        @{ Key = 'HKCU\Software\Classes\Directory\shell\Y_12_RoboPaste\command'; Name = '(default)'; Expected = $cmdPaste },
        @{ Key = 'HKCU\Software\Classes\Directory\Background\shell\Y_12_RoboPaste\command'; Name = '(default)'; Expected = $cmdPaste }
    )

    $allOk = $true
    foreach ($check in $checks) {
        $actual = Get-RegStringValue -Key $check.Key -Name $check.Name
        if ($actual -ne $check.Expected) {
            $allOk = $false
            Write-InstallerLog -Level WARN -Message ("Registry verification failed: {0} [{1}] | Expected='{2}' | Actual='{3}'" -f $check.Key, $check.Name, $check.Expected, $actual)
        }
    }
    return $allOk
}

function Set-UninstallEntry {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $installScript = Join-Path $InstallRoot 'Install.ps1'
    $uninstallCmd = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$installScript`" -Action Uninstall -Force"

    Set-RegistryString -Path $script:UninstallKeyPath -Name 'DisplayName' -Value 'RoboCopy Context Menu'
    Set-RegistryString -Path $script:UninstallKeyPath -Name 'DisplayVersion' -Value $script:InstallerVersion
    Set-RegistryString -Path $script:UninstallKeyPath -Name 'Publisher' -Value 'joty79'
    Set-RegistryString -Path $script:UninstallKeyPath -Name 'InstallLocation' -Value $InstallRoot
    Set-RegistryString -Path $script:UninstallKeyPath -Name 'UninstallString' -Value $uninstallCmd
    Set-RegistryDword -Path $script:UninstallKeyPath -Name 'NoModify' -Value 1
    Set-RegistryDword -Path $script:UninstallKeyPath -Name 'NoRepair' -Value 1
}

function Remove-UninstallEntry {
    try {
        if (Test-Path -LiteralPath $script:UninstallKeyPath) {
            Remove-Item -LiteralPath $script:UninstallKeyPath -Recurse -Force
        }
    }
    catch {
        Write-InstallerLog -Level WARN -Message 'Could not remove uninstall registry entry.'
    }
}

function Copy-FileIfNeeded {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$PreserveExisting
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing source file: $Source"
    }

    $srcNorm = Resolve-NormalizedPath -Path $Source
    $dstNorm = Resolve-NormalizedPath -Path $Destination
    if ($srcNorm -ieq $dstNorm) {
        return
    }

    $dstDir = Split-Path -Path $Destination -Parent
    Ensure-Directory -Path $dstDir

    if ($PreserveExisting -and (Test-Path -LiteralPath $Destination)) {
        return
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Resolve-IconSourceFile {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$IconName
    )
    $preferred = Join-Path $SourceRoot ("assets\{0}" -f $IconName)
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    $fallback = Join-Path 'D:\Users\joty79\Documents\Icons' $IconName
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    throw "Icon not found: $IconName"
}

function Deploy-PackageFiles {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $runtimeFiles = @(
        'Install.ps1',
        'rcp.ps1',
        'rcopySingle.ps1',
        'RoboCopy_Silent.vbs',
        'RoboPaste_Admin.vbs',
        'RoboTune.ps1'
    )

    foreach ($name in $runtimeFiles) {
        $src = Join-Path $SourceRoot $name
        $dst = Join-Path $InstallRoot $name
        Copy-FileIfNeeded -Source $src -Destination $dst
    }

    $tuneSrc = Join-Path $SourceRoot 'RoboTune.json'
    $tuneDst = Join-Path $InstallRoot 'RoboTune.json'
    if (Test-Path -LiteralPath $tuneSrc) {
        Copy-FileIfNeeded -Source $tuneSrc -Destination $tuneDst -PreserveExisting
    }
    elseif (-not (Test-Path -LiteralPath $tuneDst)) {
        $defaultTune = [ordered]@{
            benchmark_mode = $true
            benchmark = $true
            hold_window = $true
            debug_mode = $false
            stage_backend = 'file'
            default_mt = 32
            extra_args = @()
            routes = @()
        }
        $defaultTune | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tuneDst -Encoding UTF8
        Write-InstallerLog -Level WARN -Message 'RoboTune.json missing in package. Created default config at install path.'
    }

    $assetsDir = Join-Path $InstallRoot 'assets'
    Ensure-Directory -Path $assetsDir
    foreach ($icon in @('Cut.ico', 'Copy.ico', 'Paste.ico')) {
        $src = Resolve-IconSourceFile -SourceRoot $SourceRoot -IconName $icon
        $dst = Join-Path $assetsDir $icon
        Copy-FileIfNeeded -Source $src -Destination $dst
    }
}

function Get-GitHubArchiveUrl {
    if (-not [string]::IsNullOrWhiteSpace($GitHubZipUrl)) {
        return $GitHubZipUrl.Trim()
    }
    return ("https://codeload.github.com/{0}/zip/refs/heads/{1}" -f $GitHubRepo, $GitHubRef)
}

function Assert-RequiredPackageFiles {
    param([Parameter(Mandatory)][string]$Root)
    $required = @(
        'Install.ps1',
        'rcp.ps1',
        'rcopySingle.ps1',
        'RoboCopy_Silent.vbs',
        'RoboPaste_Admin.vbs',
        'RoboTune.ps1',
        'assets\Cut.ico',
        'assets\Copy.ico',
        'assets\Paste.ico'
    )
    foreach ($entry in $required) {
        $path = Join-Path $Root $entry
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Downloaded package is missing required file: $entry"
        }
    }
}

function Resolve-PackageSourceRoot {
    if ($PackageSource -eq 'Local') {
        return $SourcePath
    }

    $url = Get-GitHubArchiveUrl
    $tempRoot = Join-Path $env:TEMP ("RoboCopyContext_pkg_{0}" -f ([guid]::NewGuid().ToString('N')))
    $zipPath = Join-Path $tempRoot 'package.zip'
    $extractPath = Join-Path $tempRoot 'extract'
    Ensure-Directory -Path $tempRoot
    Ensure-Directory -Path $extractPath
    $script:TempPackageRoots.Add($tempRoot) | Out-Null

    Write-InstallerLog -Message ("Downloading package: {0}" -f $url)
    try {
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    }
    catch {
        throw "Failed to download package from GitHub. URL: $url | Error: $($_.Exception.Message)"
    }

    try {
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    }
    catch {
        throw "Failed to extract downloaded package. Error: $($_.Exception.Message)"
    }

    $roots = @(Get-ChildItem -LiteralPath $extractPath -Directory -ErrorAction SilentlyContinue)
    if ($roots.Length -eq 0) {
        throw 'Downloaded package extraction produced no root folder.'
    }

    $packageRoot = $roots[0].FullName
    $candidateRoots = @($packageRoot) + @(Get-ChildItem -LiteralPath $extractPath -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $selectedRoot = $null
    foreach ($candidate in $candidateRoots) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'Install.ps1')) -and (Test-Path -LiteralPath (Join-Path $candidate 'rcp.ps1'))) {
            $selectedRoot = $candidate
            break
        }
    }

    if (-not $selectedRoot) {
        throw 'Could not locate valid package root after extraction.'
    }

    $packageRoot = $selectedRoot
    Assert-RequiredPackageFiles -Root $packageRoot
    Write-InstallerLog -Message ("Using downloaded package root: {0}" -f $packageRoot)
    return $packageRoot
}

function Patch-SilentWrapper {
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $content = Get-Content -LiteralPath $WrapperPath -Raw
    $patched = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        'Const SCRIPT_ROOT = ".*?"',
        ('Const SCRIPT_ROOT = "{0}"' -f $InstallRoot)
    )
    Set-Content -LiteralPath $WrapperPath -Value $patched -Encoding UTF8
}

function Write-PasteWrapper {
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $rcpPath = Join-Path $InstallRoot 'rcp.ps1'
    $content = @"
' Elevated wrapper for rcp.ps1 (Robo-Paste)
' Auto-generated by Install.ps1

Option Explicit

Dim shellApp, shellObj
Set shellApp = CreateObject("Shell.Application")
Set shellObj = CreateObject("WScript.Shell")

If WScript.Arguments.Count = 0 Then
    WScript.Quit 1
End If

Dim folderPath, scriptPath, args, wtExit
folderPath = WScript.Arguments(0)
scriptPath = "$rcpPath"

wtExit = shellObj.Run("cmd /c where wt.exe >nul 2>nul", 0, True)

If wtExit = 0 Then
    args = "new-tab pwsh -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """ auto auto """ & folderPath & """"
    shellApp.ShellExecute "wt.exe", args, "", "runas", 1
Else
    args = "-NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """ auto auto """ & folderPath & """"
    shellApp.ShellExecute "pwsh.exe", args, "", "runas", 1
End If
"@
    Set-Content -LiteralPath $WrapperPath -Value $content -Encoding UTF8
}

function Get-DefaultMeta {
    [ordered]@{
        schema_version = 1
        installer_version = $script:InstallerVersion
        install_path = $InstallPath
        source_path = $SourcePath
        package_source = 'Local'
        github_repo = ''
        github_ref = ''
        github_zip_url = ''
        migration_completed = $false
        migration_utc = $null
        migrated_from = $null
        last_action = $null
        installed_utc = $null
    }
}

function Load-InstallMeta {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $metaPath = Join-Path $InstallRoot 'state\install-meta.json'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        return [pscustomobject](Get-DefaultMeta)
    }
    try {
        return (Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json)
    }
    catch {
        Write-InstallerLog -Level WARN -Message 'Existing install-meta.json is invalid. Reinitializing metadata.'
        return [pscustomobject](Get-DefaultMeta)
    }
}

function Save-InstallMeta {
    param(
        [Parameter(Mandatory)][psobject]$Meta,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $metaPath = Join-Path $InstallRoot 'state\install-meta.json'
    Ensure-Directory -Path (Split-Path -Path $metaPath -Parent)
    $Meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaPath -Encoding UTF8
}

function Set-MetaValue {
    param(
        [Parameter(Mandatory)][psobject]$Meta,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )
    $prop = $Meta.PSObject.Properties[$Name]
    if (-not $prop) {
        Add-Member -InputObject $Meta -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $Meta.$Name = $Value
    }
}

function Invoke-OneTimeMigration {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][psobject]$Meta
    )
    if ($Meta.migration_completed) {
        return
    }

    $legacyRootNorm = Resolve-NormalizedPath -Path $script:LegacyRoot
    $installRootNorm = Resolve-NormalizedPath -Path $InstallRoot
    if ($legacyRootNorm -ieq $installRootNorm) {
        $Meta.migration_completed = $true
        $Meta.migration_utc = (Get-Date).ToUniversalTime().ToString('o')
        $Meta.migrated_from = $null
        return
    }

    if (-not (Test-Path -LiteralPath $script:LegacyRoot)) {
        $Meta.migration_completed = $true
        $Meta.migration_utc = (Get-Date).ToUniversalTime().ToString('o')
        $Meta.migrated_from = $null
        return
    }

    Write-InstallerLog -Message ("Starting one-time migration from {0}" -f $script:LegacyRoot)

    $legacyTune = Join-Path $script:LegacyRoot 'RoboTune.json'
    $destTune = Join-Path $InstallRoot 'RoboTune.json'
    if ((Test-Path -LiteralPath $legacyTune) -and (-not (Test-Path -LiteralPath $destTune))) {
        Copy-FileIfNeeded -Source $legacyTune -Destination $destTune
    }

    $legacyLogs = Join-Path $script:LegacyRoot 'logs'
    $destLogs = Join-Path $InstallRoot 'logs'
    if (Test-Path -LiteralPath $legacyLogs) {
        Ensure-Directory -Path $destLogs
        Get-ChildItem -LiteralPath $legacyLogs -File -ErrorAction SilentlyContinue | ForEach-Object {
            $dest = Join-Path $destLogs $_.Name
            if (-not (Test-Path -LiteralPath $dest)) {
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
    }

    $legacyState = Join-Path $script:LegacyRoot 'state'
    if (Test-Path -LiteralPath $legacyState) {
        Get-ChildItem -LiteralPath $legacyState -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.FullName -match '\\state\\staging\\') { return }
            if ($_.Name -like '*.stage.json') { return }

            $relative = $_.FullName.Substring($legacyState.Length).TrimStart('\')
            $dest = Join-Path (Join-Path $InstallRoot 'state') $relative
            $destDir = Split-Path -Path $dest -Parent
            Ensure-Directory -Path $destDir
            if (-not (Test-Path -LiteralPath $dest)) {
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
    }

    $Meta.migration_completed = $true
    $Meta.migration_utc = (Get-Date).ToUniversalTime().ToString('o')
    $Meta.migrated_from = $script:LegacyRoot
}

function Restart-ExplorerShell {
    if ($NoExplorerRestart) {
        Write-InstallerLog -Level WARN -Message 'Explorer restart skipped by -NoExplorerRestart. Restart Explorer manually to refresh menu.'
        return
    }
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe
        Write-InstallerLog -Message 'Explorer restarted.'
    }
    catch {
        Write-InstallerLog -Level WARN -Message 'Explorer restart failed. Please restart Explorer manually.'
    }
}

function Invoke-InstallOrUpdate {
    param([Parameter(Mandatory)][ValidateSet('Install', 'Update')][string]$Mode)

    Write-Banner
    Initialize-InstallerLog
    Write-InstallerLog -Message ("Starting {0} to {1}" -f $Mode, $InstallPath)
    Write-InstallerLog -Message ("Installer script path: {0}" -f $PSCommandPath)
    Write-InstallerLog -Message ("Package source mode: {0}" -f $PackageSource)
    Write-InstallerLog -Message ("Source path: {0}" -f $SourcePath)

    $preflight = Invoke-Preflight
    if (-not $preflight.Ok) {
        Write-Host ''
        Write-Host 'Installation aborted: missing required dependencies.' -ForegroundColor Red
        return 1
    }

    Ensure-Directory -Path $InstallPath
    Ensure-Directory -Path (Join-Path $InstallPath 'logs')
    Ensure-Directory -Path (Join-Path $InstallPath 'state')
    Ensure-Directory -Path (Join-Path $InstallPath 'state\staging')
    Ensure-Directory -Path (Join-Path $InstallPath 'assets')

    $meta = Load-InstallMeta -InstallRoot $InstallPath
    Invoke-OneTimeMigration -InstallRoot $InstallPath -Meta $meta

    $effectiveSourceRoot = $null
    try {
        $effectiveSourceRoot = Resolve-PackageSourceRoot
        Deploy-PackageFiles -SourceRoot $effectiveSourceRoot -InstallRoot $InstallPath
    }
    finally {
        foreach ($temp in $script:TempPackageRoots) {
            try {
                if (Test-Path -LiteralPath $temp) {
                    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            catch {}
        }
        $script:TempPackageRoots.Clear()
    }
    Patch-SilentWrapper -WrapperPath (Join-Path $InstallPath 'RoboCopy_Silent.vbs') -InstallRoot $InstallPath
    Write-PasteWrapper -WrapperPath (Join-Path $InstallPath 'RoboPaste_Admin.vbs') -InstallRoot $InstallPath

    $cutIcon = Join-Path $InstallPath 'assets\Cut.ico'
    $copyIcon = Join-Path $InstallPath 'assets\Copy.ico'
    $pasteIcon = Join-Path $InstallPath 'assets\Paste.ico'

    Write-RoboRegistry -InstallRoot $InstallPath -CutIcon $cutIcon -CopyIcon $copyIcon -PasteIcon $pasteIcon
    $registryOk = Verify-RoboRegistry -InstallRoot $InstallPath
    if (-not $registryOk) {
        Write-InstallerLog -Level WARN -Message 'Registry read-back verification reported mismatches.'
    }

    Set-UninstallEntry -InstallRoot $InstallPath

    Set-MetaValue -Meta $meta -Name 'installer_version' -Value $script:InstallerVersion
    Set-MetaValue -Meta $meta -Name 'install_path' -Value $InstallPath
    Set-MetaValue -Meta $meta -Name 'source_path' -Value (
        if ($PackageSource -eq 'GitHub') { ("github://{0}@{1}" -f $GitHubRepo, $GitHubRef) } else { $SourcePath }
    )
    Set-MetaValue -Meta $meta -Name 'package_source' -Value $PackageSource
    Set-MetaValue -Meta $meta -Name 'github_repo' -Value $GitHubRepo
    Set-MetaValue -Meta $meta -Name 'github_ref' -Value $GitHubRef
    Set-MetaValue -Meta $meta -Name 'github_zip_url' -Value $GitHubZipUrl
    Set-MetaValue -Meta $meta -Name 'last_action' -Value $Mode
    Set-MetaValue -Meta $meta -Name 'installed_utc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
    Save-InstallMeta -Meta $meta -InstallRoot $InstallPath

    Restart-ExplorerShell

    Write-Host ''
    if ($script:Warnings.Count -gt 0 -or -not $registryOk) {
        Write-Host ("{0} completed with warnings." -f $Mode) -ForegroundColor Yellow
        return 2
    }

    Write-Host ("{0} completed successfully." -f $Mode) -ForegroundColor Green
    return 0
}

function Invoke-Uninstall {
    Write-Banner
    Initialize-InstallerLog
    Write-InstallerLog -Message ("Starting uninstall from {0}" -f $InstallPath)

    try {
        Remove-RoboRegistryKeys
        Remove-UninstallEntry

        if (Test-Path -LiteralPath $InstallPath) {
            $selfPath = $PSCommandPath
            if ([string]::IsNullOrWhiteSpace($selfPath) -and $MyInvocation.MyCommand) {
                $selfPath = $MyInvocation.MyCommand.Definition
            }
            $installRootNorm = Resolve-NormalizedPath -Path $InstallPath
            $selfNorm = if ([string]::IsNullOrWhiteSpace($selfPath)) { '' } else { Resolve-NormalizedPath -Path $selfPath }
            if ($selfNorm.StartsWith($installRootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                $cmd = "/c ping 127.0.0.1 -n 3 >nul & rmdir /s /q `"$InstallPath`""
                Start-Process -FilePath 'cmd.exe' -ArgumentList $cmd -WindowStyle Hidden
                Write-InstallerLog -Message 'Scheduled self-delete of install directory.'
            }
            else {
                Remove-Item -LiteralPath $InstallPath -Recurse -Force -ErrorAction Stop
                Write-InstallerLog -Message 'Removed install directory.'
            }
        }

        Restart-ExplorerShell
        Write-Host 'Uninstall completed successfully.' -ForegroundColor Green
        return 0
    }
    catch {
        Write-InstallerLog -Level ERROR -Message ("Uninstall failed: {0}" -f $_.Exception.Message)
        Write-Host 'Uninstall failed.' -ForegroundColor Red
        return 3
    }
}

function Invoke-Main {
    if (-not $script:HasCliArgs) {
        $menuAction = Show-InteractiveMenu
        if ($menuAction -eq 'Exit') {
            return 0
        }
        $Action = $menuAction
    }

    switch ($Action) {
        'Install' {
            $PackageSource = 'Local'
            if (-not (Confirm-Action -Prompt "Install RoboCopy Context Menu to '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            return (Invoke-InstallOrUpdate -Mode 'Install')
        }
        'Update' {
            $PackageSource = 'Local'
            if (-not (Confirm-Action -Prompt "Update existing RoboCopy Context Menu at '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            return (Invoke-InstallOrUpdate -Mode 'Update')
        }
        'InstallGitHub' {
            $PackageSource = 'GitHub'
            if (-not (Confirm-Action -Prompt "Install from GitHub '$GitHubRepo' ('$GitHubRef') to '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            return (Invoke-InstallOrUpdate -Mode 'Install')
        }
        'UpdateGitHub' {
            $PackageSource = 'GitHub'
            if (-not (Confirm-Action -Prompt "Update from GitHub '$GitHubRepo' ('$GitHubRef') at '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            return (Invoke-InstallOrUpdate -Mode 'Update')
        }
        'Uninstall' {
            if (-not (Confirm-Action -Prompt "Uninstall RoboCopy Context Menu from '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            return (Invoke-Uninstall)
        }
        default {
            Write-Host "Unknown action: $Action" -ForegroundColor Red
            return 1
        }
    }
}

exit (Invoke-Main)
