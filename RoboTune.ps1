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
        stage_backend  = "file"
        default_mt     = $null
        extra_args     = @()
        routes         = @()
    }
}

function Normalize-StageBackend {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -in @("file", "registry")) { return $normalized }
    return $null
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
            if ($null -ne $obj.stage_backend) {
                $backend = Normalize-StageBackend -Value ([string]$obj.stage_backend)
                if ($backend) { $cfg.stage_backend = $backend }
            }
            if ($null -ne $obj.default_mt -and "$($obj.default_mt)" -match '^\d+$') {
                $mt = [int]$obj.default_mt
                if ($mt -ge 1 -and $mt -le 128) { $cfg.default_mt = $mt }
            }
            if ($obj.extra_args) {
                $cfg.extra_args = @($obj.extra_args | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
            if ($obj.routes) {
                $cfg.routes = @()
                foreach ($r in @($obj.routes)) {
                    $s = [string]$r.source
                    $d = [string]$r.destination
                    $m = [string]$r.mt
                    if ($s -and $d -and $m -match '^\d+$') {
                        $mi = [int]$m
                        if ($mi -ge 1 -and $mi -le 128) {
                            $cfg.routes += [ordered]@{ source = $s; destination = $d; mt = $mi }
                        }
                    }
                }
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
    Write-Host "  stage_backend : $($Config.stage_backend)"
    Write-Host "  default_mt: $($Config.default_mt)"
    Write-Host "  extra_args: $((@($Config.extra_args) -join ' '))"
    Write-Host "  routes:"
    if (-not $Config.routes -or $Config.routes.Count -eq 0) {
        Write-Host "    (none)"
    }
    else {
        for ($i = 0; $i -lt $Config.routes.Count; $i++) {
            $r = $Config.routes[$i]
            Write-Host ("    [{0}] {1} -> {2} : MT={3}" -f ($i + 1), $r.source, $r.destination, $r.mt)
        }
    }

    $routeCount = if ($Config.routes) { $Config.routes.Count } else { 0 }
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
            ControlledBy= "Menu 6"
            Effect      = "ON => benchmark + hold_window forced ON"
        },
        [pscustomobject]@{
            Setting     = "benchmark"
            Current     = [string]$Config.benchmark
            Default     = [string]$defaults.benchmark
            ControlledBy= "Auto/Menu 6"
            Effect      = "Show per-op and session benchmark lines"
        },
        [pscustomobject]@{
            Setting     = "hold_window"
            Current     = [string]$Config.hold_window
            Default     = [string]$defaults.hold_window
            ControlledBy= "Auto/Menu 6"
            Effect      = "Keep paste window open at end (Enter/Esc/T)"
        },
        [pscustomobject]@{
            Setting     = "debug_mode"
            Current     = [string]$Config.debug_mode
            Default     = [string]$defaults.debug_mode
            ControlledBy= "Menu 7"
            Effect      = "Enable detailed robocopy debug log + console echo"
        },
        [pscustomobject]@{
            Setting     = "stage_backend"
            Current     = [string]$Config.stage_backend
            Default     = [string]$defaults.stage_backend
            ControlledBy= "Menu 8"
            Effect      = "Staging storage backend (file/registry)"
        },
        [pscustomobject]@{
            Setting     = "default_mt"
            Current     = $defaultMtCurrent
            Default     = $defaultMtDefault
            ControlledBy= "Menu 4"
            Effect      = "Global MT override when route override missing"
        },
        [pscustomobject]@{
            Setting     = "extra_args"
            Current     = $extraArgsCurrent
            Default     = $extraArgsDefault
            ControlledBy= "Menu 5"
            Effect      = "Extra robocopy flags (except /MT which is protected)"
        },
        [pscustomobject]@{
            Setting     = "routes"
            Current     = "$routeCount rule(s)"
            Default     = "0 rule(s)"
            ControlledBy= "Menu 2/3"
            Effect      = "Per-route MT override, highest priority"
        }
    )
    $settings | Format-Table -AutoSize

    Write-Host ""
    Write-Host "Auto MT fallback (when no route/default/env override):" -ForegroundColor DarkCyan
    Write-Host "  - 8  : HDD involved, network path, or same physical disk"
    Write-Host "  - 32 : SSD -> SSD"
    Write-Host "  - 16 : unknown/mixed local media"
    Write-Host "  - env override: RCWM_MT=1..128"
}

function Read-DriveToken {
    param([string]$PromptText)

    while ($true) {
        $token = (Read-Host $PromptText).Trim()
        if (-not $token) { return $null }
        if ($token -match '^[a-zA-Z]:?$') { return $token.Substring(0, 1).ToUpperInvariant() }
        if ($token -in @("ANY", "*", "UNC", "NETWORK")) {
            if ($token -eq "NETWORK") { return "UNC" }
            return $token.ToUpperInvariant()
        }
        Write-Host "Use drive letter (e.g. D), ANY/*, or UNC." -ForegroundColor Yellow
    }
}

function Set-BenchmarkMode {
    param(
        [System.Collections.IDictionary]$Config,
        [bool]$Enabled
    )

    $Config.benchmark_mode = $Enabled
    if ($Enabled) {
        $Config.benchmark = $true
        $Config.hold_window = $true
    }
    else {
        $Config.benchmark = $false
        $Config.hold_window = $false
    }
}

$config = Load-Config -Path $configPath

while ($true) {
    Write-Host ""
    Write-Host "=== RoboTune Menu ===" -ForegroundColor Green
    Write-Host "1. View current config"
    Write-Host "2. Add/Update route MT override"
    Write-Host "3. Remove route override"
    Write-Host "4. Set global default MT"
    Write-Host "5. Set extra robocopy args"
    Write-Host "6. Toggle benchmark mode (ON = benchmark+hold window)"
    Write-Host "7. Toggle debug mode (ON = /TEE + detailed robocopy log)"
    Write-Host "8. Toggle stage backend (file/registry)"
    Write-Host "9. Save and exit"
    Write-Host "10. Exit without saving"
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" {
            Show-Config -Config $config
        }
        "2" {
            $src = Read-DriveToken -PromptText "Source token (e.g. E, ANY, UNC)"
            $dst = Read-DriveToken -PromptText "Destination token (e.g. D, ANY, UNC)"
            if (-not $src -or -not $dst) {
                Write-Host "Cancelled." -ForegroundColor Yellow
                continue
            }

            $mtText = Read-Host "MT value (1..128)"
            if (-not ($mtText -match '^\d+$')) {
                Write-Host "Invalid MT value." -ForegroundColor Red
                continue
            }
            $mt = [int]$mtText
            if ($mt -lt 1 -or $mt -gt 128) {
                Write-Host "MT must be between 1 and 128." -ForegroundColor Red
                continue
            }

            $updated = $false
            for ($i = 0; $i -lt $config.routes.Count; $i++) {
                $r = $config.routes[$i]
                if ($r.source -eq $src -and $r.destination -eq $dst) {
                    $config.routes[$i].mt = $mt
                    $updated = $true
                    break
                }
            }
            if (-not $updated) {
                $config.routes += [ordered]@{ source = $src; destination = $dst; mt = $mt }
            }
            Write-Host "Route override saved in memory." -ForegroundColor Green
        }
        "3" {
            if (-not $config.routes -or $config.routes.Count -eq 0) {
                Write-Host "No routes to remove." -ForegroundColor Yellow
                continue
            }
            Show-Config -Config $config
            $idxText = Read-Host "Route number to remove"
            if (-not ($idxText -match '^\d+$')) {
                Write-Host "Invalid input." -ForegroundColor Red
                continue
            }
            $idx = [int]$idxText
            if ($idx -lt 1 -or $idx -gt $config.routes.Count) {
                Write-Host "Invalid route index." -ForegroundColor Red
                continue
            }
            $removeAt = $idx - 1
            $routeList = New-Object System.Collections.ArrayList
            foreach ($route in $config.routes) {
                [void]$routeList.Add($route)
            }
            $routeList.RemoveAt($removeAt)
            $config.routes = @($routeList)
            Write-Host "Route removed." -ForegroundColor Green
        }
        "4" {
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
        "5" {
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
        "6" {
            $next = -not [bool]$config.benchmark_mode
            Set-BenchmarkMode -Config $config -Enabled $next
            Write-Host "benchmark_mode = $($config.benchmark_mode)" -ForegroundColor Green
            Write-Host "benchmark      = $($config.benchmark)" -ForegroundColor Green
            Write-Host "hold_window    = $($config.hold_window)" -ForegroundColor Green
        }
        "7" {
            $config.debug_mode = -not [bool]$config.debug_mode
            Write-Host "debug_mode = $($config.debug_mode)" -ForegroundColor Green
            if ($config.debug_mode) {
                Write-Host "Debug output will be appended to logs\\robocopy_debug.log" -ForegroundColor DarkCyan
            }
        }
        "8" {
            if ($config.stage_backend -eq "registry") {
                $config.stage_backend = "file"
            }
            else {
                $config.stage_backend = "registry"
            }
            Write-Host "stage_backend = $($config.stage_backend)" -ForegroundColor Green
            Write-Host "Tip: env RCWM_STAGE_BACKEND overrides config per-process." -ForegroundColor DarkCyan
        }
        "9" {
            Save-Config -Config $config -Path $configPath
            Write-Host "Saved to $configPath" -ForegroundColor Cyan
            return
        }
        "10" {
            Write-Host "Exit without saving." -ForegroundColor Yellow
            return
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
        }
    }
}
