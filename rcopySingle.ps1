param(
    [Parameter(Position = 0)]
    [string]$Mode = "rc",
    [Parameter(Position = 1)]
    [string]$AnchorPath
)

[Console]::InputEncoding = [Text.UTF8Encoding]::UTF8
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$script:StageLogPath = Join-Path $PSScriptRoot "stage_log.txt"
$script:SessionWindowSeconds = 3
$script:SelectionRetryCount = 12
$script:SelectionRetryDelayMs = 100

function Write-StageLog {
    param([string]$Message)
    try {
        $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
        Add-Content -LiteralPath $script:StageLogPath -Value $line -Encoding UTF8
    }
    catch { }
}

function Resolve-NormalPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    try {
        return (Resolve-Path -LiteralPath $PathValue -ErrorAction Stop).ProviderPath
    }
    catch {
        return $null
    }
}

function Get-AnchorParentPath {
    param([string]$PathValue)

    $resolved = Resolve-NormalPath -PathValue $PathValue
    if (-not $resolved) { return $null }

    try {
        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $parent = Split-Path -Path $resolved -Parent
            if ([string]::IsNullOrWhiteSpace($parent)) { return $resolved }
            return $parent
        }
        return (Split-Path -Path $resolved -Parent)
    }
    catch {
        return $null
    }
}

function Get-ExplorerSelectionFromParent {
    param([string]$ParentPath)

    $parentNormalized = Resolve-NormalPath -PathValue $ParentPath
    if (-not $parentNormalized) { return @() }

    $results = New-Object System.Collections.Generic.List[string]

    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in @($shell.Windows())) {
            try {
                if (-not $window) { continue }
                $doc = $window.Document
                if (-not $doc) { continue }
                $folder = $doc.Folder
                if (-not $folder) { continue }

                $windowFolderPath = [string]$folder.Self.Path
                if ([string]::IsNullOrWhiteSpace($windowFolderPath)) { continue }

                $windowFolderNormalized = Resolve-NormalPath -PathValue $windowFolderPath
                if (-not $windowFolderNormalized) { continue }

                if (-not $windowFolderNormalized.Equals($parentNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                foreach ($entry in @($doc.SelectedItems())) {
                    $entryPath = [string]$entry.Path
                    if (-not [string]::IsNullOrWhiteSpace($entryPath)) {
                        [void]$results.Add($entryPath)
                    }
                }

                if ($results.Count -gt 0) { break }
            }
            catch { }
        }
    }
    catch { }

    return [string[]]$results.ToArray()
}

function Get-UniqueExistingPaths {
    param([string[]]$Candidates)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in @($Candidates)) {
        $resolved = Resolve-NormalPath -PathValue $candidate
        if (-not $resolved) { continue }
        if ($seen.Add($resolved)) {
            [void]$out.Add($resolved)
        }
    }

    return [string[]]$out.ToArray()
}

function Get-ExistingStagedPaths {
    param([string]$RegistryPath)

    if (-not (Test-Path -LiteralPath $RegistryPath)) { return @() }

    $item = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    if (-not $item) { return @() }

    $props = @($item.PSObject.Properties | Where-Object {
        $_.Name -notmatch '^PS' -and $_.Name -ne '(default)' -and -not $_.Name.StartsWith('__')
    } | Sort-Object Name)

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $props) {
        $candidate = [string]$prop.Value
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = [string]$prop.Name
        }
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        [void]$paths.Add($candidate)
    }

    return Get-UniqueExistingPaths -Candidates ([string[]]$paths.ToArray())
}

function Save-StagedPaths {
    param(
        [ValidateSet("rc", "mv")]
        [string]$CommandName,
        [string[]]$Paths
    )

    $regPath = "Registry::HKEY_CURRENT_USER\RCWM\$CommandName"
    $pathList = if ($null -eq $Paths) { @() } elseif ($Paths -is [string]) { @($Paths) } else { @($Paths) }
    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    $existing = @()
    $reuseSession = $false

    $item = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties.Name -contains "__last_stage_utc") {
        $lastText = [string]$item.__last_stage_utc
        try {
            $lastUtc = [DateTime]::Parse($lastText)
            $ageSeconds = ((Get-Date).ToUniversalTime() - $lastUtc.ToUniversalTime()).TotalSeconds
            if ($ageSeconds -ge 0 -and $ageSeconds -le $script:SessionWindowSeconds) {
                $reuseSession = $true
            }
        }
        catch { }
    }

    if ($reuseSession) {
        $existing = @(Get-ExistingStagedPaths -RegistryPath $regPath)
    }

    $combined = @(Get-UniqueExistingPaths -Candidates ([string[]](@($existing) + @($pathList))))

    Remove-ItemProperty -LiteralPath $regPath -Name * -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt @($combined).Count; $i++) {
        $valueName = "item_{0:D6}" -f ($i + 1)
        New-ItemProperty -LiteralPath $regPath -Name $valueName -PropertyType String -Value $combined[$i] -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $regPath -Name "__last_stage_utc" -PropertyType String -Value ((Get-Date).ToUniversalTime().ToString("o")) -Force | Out-Null

    return [pscustomobject]@{
        ReusedSession = $reuseSession
        TotalItems    = @($combined).Count
    }
}

$command = if ($Mode -and $Mode.ToLowerInvariant() -eq "mv") { "mv" } else { "rc" }
$anchorResolved = Resolve-NormalPath -PathValue $AnchorPath
if (-not $anchorResolved) {
    Write-StageLog ("ERROR | mode={0} | unresolved anchor='{1}'" -f $command, $AnchorPath)
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, "Global\MoveTo_RoboCopy_Stage")
$hasLock = $false
try {
    $hasLock = $mutex.WaitOne(5000)
    if (-not $hasLock) {
        Write-StageLog ("WARN | mode={0} | mutex timeout for anchor='{1}'" -f $command, $anchorResolved)
        exit 1
    }

    $parentPath = Get-AnchorParentPath -PathValue $anchorResolved
    $selectedPaths = @()

    if ($parentPath) {
        for ($attempt = 1; $attempt -le $script:SelectionRetryCount; $attempt++) {
            $selectionCandidates = Get-ExplorerSelectionFromParent -ParentPath $parentPath
            $selectedPaths = @(Get-UniqueExistingPaths -Candidates $selectionCandidates)

            if ($selectedPaths.Count -gt 1) { break }

            if ($selectedPaths.Count -eq 1) {
                $single = $selectedPaths[0]
                if (-not [string]::Equals($single, $anchorResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
                    break
                }
            }

            if ($attempt -lt $script:SelectionRetryCount) {
                Start-Sleep -Milliseconds $script:SelectionRetryDelayMs
            }
        }
    }

    if (-not $selectedPaths -or $selectedPaths.Count -eq 0) {
        $selectedPaths = @($anchorResolved)
    }

    $saveResult = Save-StagedPaths -CommandName $command -Paths $selectedPaths
    Write-StageLog ("OK | mode={0} | anchor='{1}' | selected={2} | total={3} | reused_session={4}" -f $command, $anchorResolved, $selectedPaths.Count, $saveResult.TotalItems, $saveResult.ReusedSession)

    if ($selectedPaths.Count -gt 1) {
        # Signal multi-item stage so VBS can suppress burst duplicate invokes.
        exit 10
    }
    exit 0
}
finally {
    if ($hasLock) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
