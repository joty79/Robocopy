param()

[Console]::InputEncoding = [Text.UTF8Encoding]::UTF8
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$configPath = Join-Path $PSScriptRoot "RoboTune.json"

function New-DefaultConfig {
    return [ordered]@{
        benchmark_mode = $false
        benchmark      = $false
        hold_window    = $false
        debug_mode     = $false
        mt_rules       = [ordered]@{
            ssd_to_ssd             = 32
            ssd_hdd_any            = 8
            hdd_to_hdd_diff_volume = 8
            hdd_to_hdd_same_volume = 8
            lan_any                = 8
            usb_any                = 8
            unknown_local          = 8
        }
        extra_args     = @()
    }
}

function Load-Config {
    param([string]$Path)

    $cfg = New-DefaultConfig
    if (-not (Test-Path -LiteralPath $Path)) {
        return $cfg
    }

    try {
        $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($obj.mode -and ([string]$obj.mode).ToLowerInvariant() -eq "benchmark") {
                $cfg.benchmark_mode = $true
            }
            if ($null -ne $obj.benchmark_mode) { $cfg.benchmark_mode = [bool]$obj.benchmark_mode }
            if ($null -ne $obj.benchmark) { $cfg.benchmark = [bool]$obj.benchmark }
            if ($null -ne $obj.hold_window) { $cfg.hold_window = [bool]$obj.hold_window }
            if ($null -ne $obj.debug_mode) { $cfg.debug_mode = [bool]$obj.debug_mode }
            if ($obj.mt_rules) {
                $hasSsdHddAny = $false
                $hasLanAny = $false
                $hasUsbAny = $false
                foreach ($ruleName in @(
                    "ssd_to_ssd",
                    "ssd_hdd_any",
                    "hdd_to_hdd_diff_volume",
                    "hdd_to_hdd_same_volume",
                    "lan_any",
                    "usb_any",
                    "unknown_local"
                )) {
                    $ruleValue = $obj.mt_rules.$ruleName
                    if ($null -ne $ruleValue -and "$ruleValue" -match '^\d+$') {
                        $ruleMt = [int]$ruleValue
                        if ($ruleMt -ge 1 -and $ruleMt -le 128) {
                            $cfg.mt_rules[$ruleName] = $ruleMt
                            if ($ruleName -eq "ssd_hdd_any") { $hasSsdHddAny = $true }
                            elseif ($ruleName -eq "lan_any") { $hasLanAny = $true }
                            elseif ($ruleName -eq "usb_any") { $hasUsbAny = $true }
                        }
                    }
                }

                if (-not $hasSsdHddAny) {
                    $legacySsdToHdd = $obj.mt_rules.ssd_to_hdd
                    $legacyHddToSsd = $obj.mt_rules.hdd_to_ssd
                    $legacyMixed = $null
                    if ($null -ne $legacySsdToHdd -and "$legacySsdToHdd" -match '^\d+$') {
                        $legacyMixed = [int]$legacySsdToHdd
                    }
                    elseif ($null -ne $legacyHddToSsd -and "$legacyHddToSsd" -match '^\d+$') {
                        $legacyMixed = [int]$legacyHddToSsd
                    }
                    if ($null -ne $legacyMixed -and $legacyMixed -ge 1 -and $legacyMixed -le 128) {
                        $cfg.mt_rules.ssd_hdd_any = $legacyMixed
                    }
                }

                if (-not $hasLanAny) {
                    $legacyNetworkAny = $obj.mt_rules.network_any
                    if ($null -ne $legacyNetworkAny -and "$legacyNetworkAny" -match '^\d+$') {
                        $legacyLan = [int]$legacyNetworkAny
                        if ($legacyLan -ge 1 -and $legacyLan -le 128) {
                            $cfg.mt_rules.lan_any = $legacyLan
                        }
                    }
                }

                if (-not $hasUsbAny) {
                    $legacyUnknown = $obj.mt_rules.unknown_local
                    if ($null -ne $legacyUnknown -and "$legacyUnknown" -match '^\d+$') {
                        $legacyUsb = [int]$legacyUnknown
                        if ($legacyUsb -ge 1 -and $legacyUsb -le 128) {
                            $cfg.mt_rules.usb_any = $legacyUsb
                        }
                    }
                }
            }
            if ($obj.extra_args) {
                $cfg.extra_args = @($obj.extra_args | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
        }
    }
    catch {
        Write-Host "Failed to read existing config. Starting with defaults." -ForegroundColor Yellow
    }

    return $cfg
}

function Save-Config {
    param([System.Collections.IDictionary]$Config, [string]$Path)

    $json = $Config | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Save-ConfigNow {
    param([System.Collections.IDictionary]$Config, [string]$Path)

    Save-Config -Config $Config -Path $Path
}

function Show-Config {
    param([System.Collections.IDictionary]$Config)

    $defaults = New-DefaultConfig

    Write-Host ""
    Write-Host "Current RoboTune config" -ForegroundColor Cyan
    Write-Host "  benchmark_mode: $($Config.benchmark_mode)"
    Write-Host "  benchmark     : $($Config.benchmark)"
    Write-Host "  hold_window   : $($Config.hold_window)"
    Write-Host "  debug_mode    : $($Config.debug_mode)"
    Write-Host "  mt_rules:"
    if ($Config.mt_rules) {
        Write-Host ("    ssd_to_ssd             : {0}" -f $Config.mt_rules.ssd_to_ssd)
        Write-Host ("    ssd_hdd_any            : {0}" -f $Config.mt_rules.ssd_hdd_any)
        Write-Host ("    hdd_to_hdd_diff_volume : {0}" -f $Config.mt_rules.hdd_to_hdd_diff_volume)
        Write-Host ("    hdd_to_hdd_same_volume : {0}" -f $Config.mt_rules.hdd_to_hdd_same_volume)
        Write-Host ("    lan_any                : {0}" -f $Config.mt_rules.lan_any)
        Write-Host ("    usb_any                : {0}" -f $Config.mt_rules.usb_any)
        Write-Host ("    unknown_local          : {0}" -f $Config.mt_rules.unknown_local)
    }
    Write-Host "  extra_args: $((@($Config.extra_args) -join ' '))"
    $extraArgsCurrent = if ($Config.extra_args -and $Config.extra_args.Count -gt 0) { @($Config.extra_args) -join " " } else { "(none)" }
    $extraArgsDefault = if ($defaults.extra_args -and $defaults.extra_args.Count -gt 0) { @($defaults.extra_args) -join " " } else { "(none)" }

    Write-Host ""
    Write-Host "Adjustable settings" -ForegroundColor Cyan
    $settings = @(
        [pscustomobject]@{
            Setting     = "benchmark_mode"
            Current     = [string]$Config.benchmark_mode
            Default     = [string]$defaults.benchmark_mode
            ControlledBy= "Menu 3"
            Effect      = "ON => benchmark output forced ON"
        },
        [pscustomobject]@{
            Setting     = "benchmark"
            Current     = [string]$Config.benchmark
            Default     = [string]$defaults.benchmark
            ControlledBy= "Auto/Menu 3"
            Effect      = "Show per-op and session benchmark lines"
        },
        [pscustomobject]@{
            Setting     = "hold_window"
            Current     = [string]$Config.hold_window
            Default     = [string]$defaults.hold_window
            ControlledBy= "Auto/Menu 3, Menu 5"
            Effect      = "Keep paste window open at end (Enter/Esc/T)"
        },
        [pscustomobject]@{
            Setting     = "debug_mode"
            Current     = [string]$Config.debug_mode
            Default     = [string]$defaults.debug_mode
            ControlledBy= "Menu 4"
            Effect      = "Enable detailed robocopy debug log + console echo"
        },
        [pscustomobject]@{
            Setting     = "mt_rules"
            Current     = "custom media-rule map"
            Default     = "built-in media defaults"
            ControlledBy= "Menu 1"
            Effect      = "Per media combo MT (SSD/HDD/LAN/USB/same-volume)"
        },
        [pscustomobject]@{
            Setting     = "extra_args"
            Current     = $extraArgsCurrent
            Default     = $extraArgsDefault
            ControlledBy= "Menu 2"
            Effect      = "Extra robocopy flags (except /MT which is protected)"
        }
    )
    $settings | Format-Table -AutoSize

    Write-Host ""
    Write-Host "Auto MT fallback (when no env override):" -ForegroundColor DarkCyan
    Write-Host "  - 8  : HDD involved, LAN path, or same physical disk"
    Write-Host "  - 32 : SSD -> SSD"
    Write-Host "  - 8  : unknown/mixed local media"
    Write-Host "  - env override: RCWM_MT=1..128"
    Write-Host "  - mt_rules can override these auto values per media combo"
}

function Set-BenchmarkMode {
    param(
        [System.Collections.IDictionary]$Config,
        [bool]$Enabled
    )

    $Config.benchmark_mode = $Enabled
    if ($Enabled) {
        $Config.benchmark = $true
    }
    else {
        $Config.benchmark = $false
    }
}

function Read-MtRuleInput {
    param(
        [string]$PromptText,
        [int]$CurrentValue,
        [switch]$AllowEscape
    )

    while ($true) {
        $suffix = if ($AllowEscape) { " | ESC=back" } else { "" }
        $inputResult = Read-LineWithEscape -PromptText ("{0} [{1}] (blank=keep{2})" -f $PromptText, $CurrentValue, $suffix)
        if ($AllowEscape -and $inputResult.Cancelled) {
            return [pscustomobject]@{
                Cancelled = $true
                Value     = $CurrentValue
            }
        }
        $raw = $inputResult.Text
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{
                Cancelled = $false
                Value     = $CurrentValue
            }
        }
        if ($AllowEscape -and $raw.Trim().Equals("esc", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Cancelled = $true
                Value     = $CurrentValue
            }
        }
        if ($raw -match '^\d+$') {
            $candidate = [int]$raw
            if ($candidate -ge 1 -and $candidate -le 128) {
                return [pscustomobject]@{
                    Cancelled = $false
                    Value     = $candidate
                }
            }
        }
        Write-Host "Invalid MT value. Use 1..128, blank, or ESC." -ForegroundColor Yellow
    }
}

function Read-LineWithEscape {
    param(
        [string]$PromptText,
        [ConsoleColor]$PromptColor = [ConsoleColor]::Gray
    )

    Write-Host -NoNewline ($PromptText + ": ") -ForegroundColor $PromptColor
    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        switch ($keyInfo.Key) {
            'Escape' {
                Write-Host ""
                return [pscustomobject]@{
                    Cancelled = $true
                    Text      = [string]$buffer.ToString()
                }
            }
            'Enter' {
                Write-Host ""
                return [pscustomobject]@{
                    Cancelled = $false
                    Text      = [string]$buffer.ToString()
                }
            }
            'Backspace' {
                if ($buffer.Length -gt 0) {
                    [void]$buffer.Remove($buffer.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
            }
            default {
                if ($keyInfo.KeyChar -ne [char]0) {
                    [void]$buffer.Append($keyInfo.KeyChar)
                    Write-Host $keyInfo.KeyChar -NoNewline
                }
            }
        }
    }
}

function Read-ExtraArgsLine {
    Write-Host -NoNewline "Extra args " -ForegroundColor Gray
    Write-Host -NoNewline "(space-separated), e.g. " -ForegroundColor Gray
    Write-Host -NoNewline "/R:0 /W:0" -ForegroundColor Green
    Write-Host -NoNewline " (blank to clear, " -ForegroundColor Gray
    Write-Host -NoNewline "ESC=back" -ForegroundColor Red
    Write-Host -NoNewline "): " -ForegroundColor Gray

    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        switch ($keyInfo.Key) {
            'Escape' {
                Write-Host ""
                return [pscustomobject]@{
                    Cancelled = $true
                    Text      = [string]$buffer.ToString()
                }
            }
            'Enter' {
                Write-Host ""
                return [pscustomobject]@{
                    Cancelled = $false
                    Text      = [string]$buffer.ToString()
                }
            }
            'Backspace' {
                if ($buffer.Length -gt 0) {
                    [void]$buffer.Remove($buffer.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
            }
            default {
                if ($keyInfo.KeyChar -ne [char]0) {
                    [void]$buffer.Append($keyInfo.KeyChar)
                    Write-Host $keyInfo.KeyChar -NoNewline
                }
            }
        }
    }
}

function Show-HowToUse {
    Write-Host ""
    Write-Host "=== How To Use ===" -ForegroundColor Cyan
    Write-Host "1. Set media MT rules" -ForegroundColor Gray
    Write-Host "   - Set MT for SSD/HDD/LAN/USB scenarios." -ForegroundColor Gray
    Write-Host "   - In this submenu type ESC to return without changes." -ForegroundColor Gray
    Write-Host "2. Set extra args" -ForegroundColor Gray
    Write-Host "   - Add flags like /R:0 /W:0 (except /MT)." -ForegroundColor Gray
    Write-Host "   - Blank clears args. Type ESC to return without changes." -ForegroundColor Gray
    Write-Host "3. Toggle benchmark mode" -ForegroundColor Gray
    Write-Host "   - Enables benchmark output and forces runtime hold window ON." -ForegroundColor Gray
    Write-Host "4. Toggle debug mode" -ForegroundColor Gray
    Write-Host "   - Writes detailed debug entries to logs\\robocopy_debug.log." -ForegroundColor Gray
    Write-Host "5. Toggle hold_window" -ForegroundColor Gray
    Write-Host "   - Keeps paste window open at end (when benchmark_mode is OFF)." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Global: κάθε αλλαγή αποθηκεύεται αυτόματα." -ForegroundColor Green
    Write-Host "Press any key to return..." -ForegroundColor DarkCyan
    [Console]::ReadKey($true) | Out-Null
}

function Write-StatePair {
    param(
        [string]$Name,
        [object]$Value,
        [switch]$First
    )

    if (-not $First) {
        Write-Host " | " -NoNewline -ForegroundColor Gray
    }
    Write-Host ($Name + " = ") -NoNewline -ForegroundColor Gray
    Write-Host ([string]$Value) -NoNewline -ForegroundColor Green
}

function Write-MtPair {
    param(
        [string]$Name,
        [int]$Value,
        [switch]$First
    )

    if (-not $First) {
        Write-Host "  " -NoNewline -ForegroundColor Gray
    }
    Write-Host ($Name + " = ") -NoNewline -ForegroundColor Gray
    Write-Host ([string]$Value) -NoNewline -ForegroundColor Green
}

function Write-MenuLine {
    param(
        [string]$Number,
        [string]$Prefix,
        [string]$Highlight,
        [string]$Suffix,
        [ConsoleColor]$HighlightColor
    )

    Write-Host ($Number + ". ") -NoNewline -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        Write-Host $Prefix -NoNewline -ForegroundColor Gray
    }
    Write-Host $Highlight -NoNewline -ForegroundColor $HighlightColor
    if (-not [string]::IsNullOrWhiteSpace($Suffix)) {
        Write-Host $Suffix -ForegroundColor Gray
    }
    else {
        Write-Host ""
    }
}

function Write-MtSubmenuLine {
    param(
        [string]$Number,
        [string]$Label,
        [int]$Value
    )

    Write-Host ($Number + ". ") -NoNewline -ForegroundColor Gray
    Write-Host ($Label + " = ") -NoNewline -ForegroundColor Cyan
    Write-Host ([string]$Value) -ForegroundColor Green
}

function Get-MtRuleOrFallback {
    param(
        [object]$Rules,
        [string]$RuleName,
        [int]$FallbackValue
    )

    if ($Rules) {
        $candidate = $Rules.$RuleName
        if ($null -ne $candidate -and "$candidate" -match '^\d+$') {
            $mt = [int]$candidate
            if ($mt -ge 1 -and $mt -le 128) {
                return $mt
            }
        }
    }

    return $FallbackValue
}

$config = Load-Config -Path $configPath

while ($true) {
    Clear-Host
    $benchmarkMode = [bool]$config.benchmark_mode
    $effectiveBenchmark = if ($benchmarkMode) { $true } else { [bool]$config.benchmark }
    $effectiveHoldWindow = if ($benchmarkMode) { $true } else { [bool]$config.hold_window }
    $mtSsdSsd = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "ssd_to_ssd" -FallbackValue 32
    $mtSsdHddAny = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "ssd_hdd_any" -FallbackValue 8
    $mtHddDiff = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "hdd_to_hdd_diff_volume" -FallbackValue 8
    $mtHddSame = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "hdd_to_hdd_same_volume" -FallbackValue 8
    $mtLan = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "lan_any" -FallbackValue 8
    $mtUsb = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "usb_any" -FallbackValue 8

    Write-Host ""
    Write-Host "=== RoboTune Menu ===" -ForegroundColor Green
    Write-Host "MODES : [ " -NoNewline -ForegroundColor Yellow
    Write-StatePair -Name "benchmark" -Value $effectiveBenchmark -First
    Write-StatePair -Name "debug" -Value ([bool]$config.debug_mode)
    Write-StatePair -Name "hold_window" -Value $effectiveHoldWindow
    Write-Host " ]" -ForegroundColor Yellow
    Write-Host "MT    : [ " -NoNewline -ForegroundColor Yellow
    Write-MtPair -Name "SSD -> SSD" -Value $mtSsdSsd -First
    Write-MtPair -Name "SSD <-> HDD" -Value $mtSsdHddAny
    Write-MtPair -Name "HDD -> Diff HDD" -Value $mtHddDiff
    Write-MtPair -Name "HDD -> same HDD" -Value $mtHddSame
    Write-MtPair -Name "LAN" -Value $mtLan
    Write-MtPair -Name "USB" -Value $mtUsb
    Write-Host " ]" -ForegroundColor Yellow
    Write-Host "ARGs  : " -NoNewline -ForegroundColor Yellow
    if ($config.extra_args -and @($config.extra_args).Count -gt 0) {
        Write-Host ((@($config.extra_args) -join " ")) -ForegroundColor Green
    }
    else {
        Write-Host "none" -ForegroundColor Green
    }
    if ($benchmarkMode -and -not [bool]$config.hold_window) {
        Write-Host "WARNING: benchmark_mode forces hold_window = True for runtime (saved hold_window is False)." -ForegroundColor Red
    }
    Write-MenuLine -Number "1" -Prefix "Set media " -Highlight "MT" -Suffix " rules" -HighlightColor Green
    Write-MenuLine -Number "2" -Prefix "Set extra " -Highlight "args" -Suffix "" -HighlightColor Green
    Write-MenuLine -Number "3" -Prefix "Toggle " -Highlight "benchmark" -Suffix " mode" -HighlightColor Green
    Write-MenuLine -Number "4" -Prefix "Toggle " -Highlight "debug" -Suffix " mode" -HighlightColor Red
    Write-MenuLine -Number "5" -Prefix "Toggle " -Highlight "hold_window" -Suffix "" -HighlightColor Green
    Write-MenuLine -Number "6" -Prefix "" -Highlight "How to use" -Suffix "" -HighlightColor Cyan
    Write-Host "[Esc] " -NoNewline -ForegroundColor Yellow
    Write-Host "Exit" -ForegroundColor Red

    Write-Host -NoNewline "Select option: "
    $keyInfo = [Console]::ReadKey($true)
    Write-Host ""
    $choice = $null
    switch ($keyInfo.Key) {
        "D1" { $choice = "1" }
        "NumPad1" { $choice = "1" }
        "D2" { $choice = "2" }
        "NumPad2" { $choice = "2" }
        "D3" { $choice = "3" }
        "NumPad3" { $choice = "3" }
        "D4" { $choice = "4" }
        "NumPad4" { $choice = "4" }
        "D5" { $choice = "5" }
        "NumPad5" { $choice = "5" }
        "D6" { $choice = "6" }
        "NumPad6" { $choice = "6" }
        "Escape" {
            Write-Host "Exit." -ForegroundColor Yellow
            return
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
            continue
        }
    }

    switch ($choice) {
        "1" {
            if (-not $config.mt_rules) {
                $config.mt_rules = (New-DefaultConfig).mt_rules
            }

            while ($true) {
                Clear-Host
                $tmpSsdSsd = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "ssd_to_ssd" -FallbackValue 32
                $tmpSsdHddAny = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "ssd_hdd_any" -FallbackValue 8
                $tmpHddDiff = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "hdd_to_hdd_diff_volume" -FallbackValue 8
                $tmpHddSame = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "hdd_to_hdd_same_volume" -FallbackValue 8
                $tmpLan = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "lan_any" -FallbackValue 8
                $tmpUsb = Get-MtRuleOrFallback -Rules $config.mt_rules -RuleName "usb_any" -FallbackValue 8

                Write-Host ""
                Write-Host "=== Set Media " -NoNewline -ForegroundColor Gray
                Write-Host "MT" -NoNewline -ForegroundColor Green
                Write-Host " Rules ===" -ForegroundColor Gray
                Write-MtSubmenuLine -Number "1" -Label "SSD -> SSD" -Value $tmpSsdSsd
                Write-MtSubmenuLine -Number "2" -Label "SSD <-> HDD" -Value $tmpSsdHddAny
                Write-MtSubmenuLine -Number "3" -Label "HDD -> Diff HDD" -Value $tmpHddDiff
                Write-MtSubmenuLine -Number "4" -Label "HDD -> same HDD" -Value $tmpHddSame
                Write-MtSubmenuLine -Number "5" -Label "LAN" -Value $tmpLan
                Write-MtSubmenuLine -Number "6" -Label "USB" -Value $tmpUsb
                Write-Host "[Esc] Back" -ForegroundColor Yellow
                Write-Host -NoNewline "Select rule: " -ForegroundColor Gray
                $ruleKeyInfo = [Console]::ReadKey($true)
                Write-Host ""

                $ruleChoice = $null
                switch ($ruleKeyInfo.Key) {
                    "D1" { $ruleChoice = "1" }
                    "NumPad1" { $ruleChoice = "1" }
                    "D2" { $ruleChoice = "2" }
                    "NumPad2" { $ruleChoice = "2" }
                    "D3" { $ruleChoice = "3" }
                    "NumPad3" { $ruleChoice = "3" }
                    "D4" { $ruleChoice = "4" }
                    "NumPad4" { $ruleChoice = "4" }
                    "D5" { $ruleChoice = "5" }
                    "NumPad5" { $ruleChoice = "5" }
                    "D6" { $ruleChoice = "6" }
                    "NumPad6" { $ruleChoice = "6" }
                    "Escape" { break }
                    default {
                        Write-Host "Invalid option." -ForegroundColor Red
                        Start-Sleep -Milliseconds 600
                        continue
                    }
                }

                if ($ruleKeyInfo.Key -eq "Escape") { break }

                switch ($ruleChoice) {
                    "1" {
                        $r = Read-MtRuleInput -PromptText "SSD -> SSD" -CurrentValue $tmpSsdSsd -AllowEscape
                        if ($r.Cancelled) { continue }
                        $config.mt_rules.ssd_to_ssd = [int]$r.Value
                    }
                    "2" {
                        $r = Read-MtRuleInput -PromptText "SSD <-> HDD" -CurrentValue $tmpSsdHddAny -AllowEscape
                        if ($r.Cancelled) { continue }
                        $config.mt_rules.ssd_hdd_any = [int]$r.Value
                    }
                    "3" {
                        $r = Read-MtRuleInput -PromptText "HDD -> Diff HDD" -CurrentValue $tmpHddDiff -AllowEscape
                        if ($r.Cancelled) { continue }
                        $config.mt_rules.hdd_to_hdd_diff_volume = [int]$r.Value
                    }
                    "4" {
                        $r = Read-MtRuleInput -PromptText "HDD -> same HDD" -CurrentValue $tmpHddSame -AllowEscape
                        if ($r.Cancelled) { continue }
                        $config.mt_rules.hdd_to_hdd_same_volume = [int]$r.Value
                    }
                    "5" {
                        $r = Read-MtRuleInput -PromptText "LAN involved" -CurrentValue $tmpLan -AllowEscape
                        if ($r.Cancelled) { continue }
                        $config.mt_rules.lan_any = [int]$r.Value
                    }
                    "6" {
                        $r = Read-MtRuleInput -PromptText "USB involved" -CurrentValue $tmpUsb -AllowEscape
                        if ($r.Cancelled) { continue }
                        $config.mt_rules.usb_any = [int]$r.Value
                    }
                }

                $config.mt_rules.unknown_local = 8
                Save-ConfigNow -Config $config -Path $configPath
            }
        }
        "2" {
            Write-Host "=== Set Extra Robocopy " -NoNewline -ForegroundColor Gray
            Write-Host "Args" -NoNewline -ForegroundColor Green
            Write-Host " ===" -ForegroundColor Gray
            Write-Host "current extra_args = " -NoNewline -ForegroundColor Gray
            if ($config.extra_args -and @($config.extra_args).Count -gt 0) {
                Write-Host ((@($config.extra_args) -join " ")) -ForegroundColor Green
            }
            else {
                Write-Host "none" -ForegroundColor Green
            }
            $argInput = Read-ExtraArgsLine
            if ($argInput.Cancelled) {
                continue
            }
            $argLine = $argInput.Text
            if (-not [string]::IsNullOrWhiteSpace($argLine) -and $argLine.Trim().Equals("esc", [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if (-not $argLine) {
                $config.extra_args = @()
                Write-Host "extra_args cleared." -ForegroundColor Green
                Save-ConfigNow -Config $config -Path $configPath
                continue
            }
            $tokens = $argLine -split '\s+' | Where-Object { $_ }
            $config.extra_args = @($tokens)
            Write-Host "extra_args updated." -ForegroundColor Green
            Save-ConfigNow -Config $config -Path $configPath
        }
        "3" {
            $next = -not [bool]$config.benchmark_mode
            Set-BenchmarkMode -Config $config -Enabled $next
            Write-Host "benchmark_mode = $($config.benchmark_mode)" -ForegroundColor Green
            Write-Host "benchmark      = $($config.benchmark)" -ForegroundColor Green
            Save-ConfigNow -Config $config -Path $configPath
        }
        "4" {
            $config.debug_mode = -not [bool]$config.debug_mode
            Write-Host "debug_mode = $($config.debug_mode)" -ForegroundColor Green
            if ($config.debug_mode) {
                Write-Host "Debug output will be appended to logs\\robocopy_debug.log" -ForegroundColor DarkCyan
            }
            Save-ConfigNow -Config $config -Path $configPath
        }
        "5" {
            $config.hold_window = -not [bool]$config.hold_window
            Write-Host "hold_window = $($config.hold_window)" -ForegroundColor Green
            if ($config.hold_window) {
                Write-Host "Paste window will stay open at end ([Enter]/[Esc]/[T])." -ForegroundColor DarkCyan
            }
            Save-ConfigNow -Config $config -Path $configPath
        }
        "6" {
            Show-HowToUse
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
        }
    }
}
