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
        default_mt     = $null
        mt_rules       = [ordered]@{
            ssd_to_ssd             = 32
            ssd_to_hdd             = 8
            hdd_to_ssd             = 8
            hdd_to_hdd_diff_volume = 8
            hdd_to_hdd_same_volume = 8
            network_any            = 8
            unknown_local          = 16
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
            if ($null -ne $obj.default_mt -and "$($obj.default_mt)" -match '^\d+$') {
                $mt = [int]$obj.default_mt
                if ($mt -ge 1 -and $mt -le 128) { $cfg.default_mt = $mt }
            }
            if ($obj.mt_rules) {
                foreach ($ruleName in @(
                    "ssd_to_ssd",
                    "ssd_to_hdd",
                    "hdd_to_ssd",
                    "hdd_to_hdd_diff_volume",
                    "hdd_to_hdd_same_volume",
                    "network_any",
                    "unknown_local"
                )) {
                    $ruleValue = $obj.mt_rules.$ruleName
                    if ($null -ne $ruleValue -and "$ruleValue" -match '^\d+$') {
                        $ruleMt = [int]$ruleValue
                        if ($ruleMt -ge 1 -and $ruleMt -le 128) {
                            $cfg.mt_rules[$ruleName] = $ruleMt
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

function Show-Config {
    param([System.Collections.IDictionary]$Config)

    $defaults = New-DefaultConfig

    Write-Host ""
    Write-Host "Current RoboTune config" -ForegroundColor Cyan
    Write-Host "  benchmark_mode: $($Config.benchmark_mode)"
    Write-Host "  benchmark     : $($Config.benchmark)"
    Write-Host "  hold_window   : $($Config.hold_window)"
    Write-Host "  debug_mode    : $($Config.debug_mode)"
    Write-Host "  default_mt: $($Config.default_mt)"
    Write-Host "  mt_rules:"
    if ($Config.mt_rules) {
        Write-Host ("    ssd_to_ssd             : {0}" -f $Config.mt_rules.ssd_to_ssd)
        Write-Host ("    ssd_to_hdd             : {0}" -f $Config.mt_rules.ssd_to_hdd)
        Write-Host ("    hdd_to_ssd             : {0}" -f $Config.mt_rules.hdd_to_ssd)
        Write-Host ("    hdd_to_hdd_diff_volume : {0}" -f $Config.mt_rules.hdd_to_hdd_diff_volume)
        Write-Host ("    hdd_to_hdd_same_volume : {0}" -f $Config.mt_rules.hdd_to_hdd_same_volume)
        Write-Host ("    network_any            : {0}" -f $Config.mt_rules.network_any)
        Write-Host ("    unknown_local          : {0}" -f $Config.mt_rules.unknown_local)
    }
    Write-Host "  extra_args: $((@($Config.extra_args) -join ' '))"
    $extraArgsCurrent = if ($Config.extra_args -and $Config.extra_args.Count -gt 0) { @($Config.extra_args) -join " " } else { "(none)" }
    $extraArgsDefault = if ($defaults.extra_args -and $defaults.extra_args.Count -gt 0) { @($defaults.extra_args) -join " " } else { "(none)" }
    $defaultMtCurrent = if ($null -eq $Config.default_mt) { "(auto)" } else { [string]$Config.default_mt }
    $defaultMtDefault = if ($null -eq $defaults.default_mt) { "(auto)" } else { [string]$defaults.default_mt }

    Write-Host ""
    Write-Host "Adjustable settings" -ForegroundColor Cyan
    $settings = @(
        [pscustomobject]@{
            Setting     = "benchmark_mode"
            Current     = [string]$Config.benchmark_mode
            Default     = [string]$defaults.benchmark_mode
            ControlledBy= "Menu 4"
            Effect      = "ON => benchmark + hold_window forced ON"
        },
        [pscustomobject]@{
            Setting     = "benchmark"
            Current     = [string]$Config.benchmark
            Default     = [string]$defaults.benchmark
            ControlledBy= "Auto/Menu 4"
            Effect      = "Show per-op and session benchmark lines"
        },
        [pscustomobject]@{
            Setting     = "hold_window"
            Current     = [string]$Config.hold_window
            Default     = [string]$defaults.hold_window
            ControlledBy= "Auto/Menu 4, Menu 6"
            Effect      = "Keep paste window open at end (Enter/Esc/T)"
        },
        [pscustomobject]@{
            Setting     = "debug_mode"
            Current     = [string]$Config.debug_mode
            Default     = [string]$defaults.debug_mode
            ControlledBy= "Menu 5"
            Effect      = "Enable detailed robocopy debug log + console echo"
        },
        [pscustomobject]@{
            Setting     = "default_mt"
            Current     = $defaultMtCurrent
            Default     = $defaultMtDefault
            ControlledBy= "Menu 2"
            Effect      = "Global MT override when env override missing"
        },
        [pscustomobject]@{
            Setting     = "mt_rules"
            Current     = "custom media-rule map"
            Default     = "built-in media defaults"
            ControlledBy= "Menu 7"
            Effect      = "Per media combo MT (SSD/HDD/network/same-volume)"
        },
        [pscustomobject]@{
            Setting     = "extra_args"
            Current     = $extraArgsCurrent
            Default     = $extraArgsDefault
            ControlledBy= "Menu 3"
            Effect      = "Extra robocopy flags (except /MT which is protected)"
        }
    )
    $settings | Format-Table -AutoSize

    Write-Host ""
    Write-Host "Auto MT fallback (when no default/env override):" -ForegroundColor DarkCyan
    Write-Host "  - 8  : HDD involved, network path, or same physical disk"
    Write-Host "  - 32 : SSD -> SSD"
    Write-Host "  - 16 : unknown/mixed local media"
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
        [int]$CurrentValue
    )

    while ($true) {
        $raw = Read-Host ("{0} [{1}] (blank=keep)" -f $PromptText, $CurrentValue)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $CurrentValue
        }
        if ($raw -match '^\d+$') {
            $candidate = [int]$raw
            if ($candidate -ge 1 -and $candidate -le 128) {
                return $candidate
            }
        }
        Write-Host "Invalid MT value. Use 1..128 or blank." -ForegroundColor Yellow
    }
}

$config = Load-Config -Path $configPath

while ($true) {
    Write-Host ""
    Write-Host "=== RoboTune Menu ===" -ForegroundColor Green
    Write-Host "1. View current config"
    Write-Host "2. Set global default MT"
    Write-Host "3. Set extra robocopy args"
    Write-Host "4. Toggle benchmark mode (ON = benchmark output)"
    Write-Host "5. Toggle debug mode (ON = /TEE + detailed robocopy log)"
    Write-Host "6. Toggle hold_window (keep window open at end)"
    Write-Host "7. Set media MT rules (SSD/HDD combos)"
    Write-Host "8. Save and exit"
    Write-Host "9. Exit without saving"
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" {
            Show-Config -Config $config
        }
        "2" {
            $val = Read-Host "Default MT (1..128) or blank to disable"
            if (-not $val) {
                $config.default_mt = $null
                Write-Host "default_mt cleared." -ForegroundColor Green
                continue
            }
            if (-not ($val -match '^\d+$')) {
                Write-Host "Invalid MT value." -ForegroundColor Red
                continue
            }
            $mt = [int]$val
            if ($mt -lt 1 -or $mt -gt 128) {
                Write-Host "MT must be between 1 and 128." -ForegroundColor Red
                continue
            }
            $config.default_mt = $mt
            Write-Host "default_mt updated." -ForegroundColor Green
        }
        "3" {
            $argLine = Read-Host "Extra args (space-separated), e.g. /R:0 /W:0 (blank to clear)"
            if (-not $argLine) {
                $config.extra_args = @()
                Write-Host "extra_args cleared." -ForegroundColor Green
                continue
            }
            $tokens = $argLine -split '\s+' | Where-Object { $_ }
            $config.extra_args = @($tokens)
            Write-Host "extra_args updated." -ForegroundColor Green
        }
        "4" {
            $next = -not [bool]$config.benchmark_mode
            Set-BenchmarkMode -Config $config -Enabled $next
            Write-Host "benchmark_mode = $($config.benchmark_mode)" -ForegroundColor Green
            Write-Host "benchmark      = $($config.benchmark)" -ForegroundColor Green
        }
        "5" {
            $config.debug_mode = -not [bool]$config.debug_mode
            Write-Host "debug_mode = $($config.debug_mode)" -ForegroundColor Green
            if ($config.debug_mode) {
                Write-Host "Debug output will be appended to logs\\robocopy_debug.log" -ForegroundColor DarkCyan
            }
        }
        "6" {
            $config.hold_window = -not [bool]$config.hold_window
            Write-Host "hold_window = $($config.hold_window)" -ForegroundColor Green
            if ($config.hold_window) {
                Write-Host "Paste window will stay open at end ([Enter]/[Esc]/[T])." -ForegroundColor DarkCyan
            }
        }
        "7" {
            if (-not $config.mt_rules) {
                $config.mt_rules = (New-DefaultConfig).mt_rules
            }

            Write-Host "Set MT by media combo (blank = keep current)" -ForegroundColor Cyan
            $config.mt_rules.ssd_to_ssd = Read-MtRuleInput -PromptText "SSD -> SSD" -CurrentValue ([int]$config.mt_rules.ssd_to_ssd)
            $config.mt_rules.ssd_to_hdd = Read-MtRuleInput -PromptText "SSD -> HDD" -CurrentValue ([int]$config.mt_rules.ssd_to_hdd)
            $config.mt_rules.hdd_to_ssd = Read-MtRuleInput -PromptText "HDD -> SSD" -CurrentValue ([int]$config.mt_rules.hdd_to_ssd)
            $config.mt_rules.hdd_to_hdd_diff_volume = Read-MtRuleInput -PromptText "HDD -> HDD (different volume/disk)" -CurrentValue ([int]$config.mt_rules.hdd_to_hdd_diff_volume)
            $config.mt_rules.hdd_to_hdd_same_volume = Read-MtRuleInput -PromptText "HDD -> HDD (same volume/disk)" -CurrentValue ([int]$config.mt_rules.hdd_to_hdd_same_volume)
            $config.mt_rules.network_any = Read-MtRuleInput -PromptText "NETWORK involved" -CurrentValue ([int]$config.mt_rules.network_any)
            $config.mt_rules.unknown_local = Read-MtRuleInput -PromptText "Unknown local media" -CurrentValue ([int]$config.mt_rules.unknown_local)
            Write-Host "mt_rules updated in memory." -ForegroundColor Green
        }
        "8" {
            Save-Config -Config $config -Path $configPath
            Write-Host "Saved to $configPath" -ForegroundColor Cyan
            return
        }
        "9" {
            Write-Host "Exit without saving." -ForegroundColor Yellow
            return
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
        }
    }
}
