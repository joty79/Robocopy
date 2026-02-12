#Robocopy paste engine for staged files/folders from HKCU:\RCWM

#flags used when robocopying (overwrites files):

#/E :: copy subdirectories, including Empty ones
#/NP :: No Progress - don't display percentage copied
#/NJH :: No Job Header
#/NJS :: No Job Summary
#/NC :: No Class - don't log file classes
#/NS :: No Size - don't log file sizes
#/MT[:n] :: Do multi-threaded copies with n threads (default 8)


#when merging, these are added to not overwrite any files:

#/XC :: eXclude Changed files.
#/XN :: eXclude Newer files.
#/XO :: eXclude Older files.

#Set UTF-8 encoding
[console]::InputEncoding = [text.utf8encoding]::UTF8
[system.console]::OutputEncoding = [System.Text.Encoding]::UTF8

#set high process priority
$process = Get-Process -Id $pid
$process.PriorityClass = 'High'
$script:ThreadDecisionCache = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)


function NoListAvailable {
	if ($mode -eq "m") {
		echo "List of items to be $string1 does not exist!"
		Start-Sleep 1
		echo "Create the list by right-clicking on files/folders and selecting $string2."
		Start-Sleep 3
		Exit-Script -Code 1 -Reason "NoListAvailable (mode=m): list missing."
	}
 elseif ($mode -eq "s") {
		echo "Item to be $string1 does not exist!"
		Start-Sleep 1
		echo "Create one by right-clicking on a file/folder and selecting $string2."
		Start-Sleep 3
		Exit-Script -Code 1 -Reason "NoListAvailable (mode=s): single source missing."
	}
}

function Get-UniquePathList {
	param([string[]]$InputPaths)

	$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
	$out = New-Object System.Collections.Generic.List[string]

	foreach ($rawPath in @($InputPaths)) {
		if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }

		$candidate = $rawPath
		try {
			$candidate = (Resolve-Path -LiteralPath $rawPath -ErrorAction Stop).ProviderPath
		}
		catch { }

		if ($seen.Add($candidate)) {
			[void]$out.Add($candidate)
		}
	}

	return [string[]]$out.ToArray()
}

function Get-StagedPathList {
	param([string]$CommandName)

	$regPath = "Registry::HKEY_CURRENT_USER\RCWM\$CommandName"
	if (-not (Test-Path -LiteralPath $regPath)) { return @() }

	$item = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
	if (-not $item) { return @() }

	$ignore = @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider")
	$paths = New-Object System.Collections.Generic.List[string]

	foreach ($prop in $item.PSObject.Properties) {
		if ($ignore -contains $prop.Name) { continue }
		if ($prop.Name -eq "(default)") { continue }
		if ($prop.Name.StartsWith("__")) { continue }

		# New format: item_xxxxxx value contains full path.
		$candidate = [string]$prop.Value
		# Backward compatibility: old format used path as value name.
		if ([string]::IsNullOrWhiteSpace($candidate)) {
			$candidate = [string]$prop.Name
		}
		if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

		if (-not (Test-Path -LiteralPath $candidate)) { continue }
		[void]$paths.Add($candidate)
	}

	return Get-UniquePathList -InputPaths @($paths)
}

function Get-DriveLetterFromPath {
	param([string]$PathValue)

	if (-not $PathValue) { return $null }
	if ($PathValue -match '^[a-zA-Z]:') {
		return $PathValue.Substring(0, 1).ToUpperInvariant()
	}
	return $null
}

function Get-DiskNumberFromPath {
	param([string]$PathValue)

	$driveLetter = Get-DriveLetterFromPath -PathValue $PathValue
	if (-not $driveLetter) { return $null }
	if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) { return $null }

	try {
		$partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
		return [int]$partition.DiskNumber
	}
	catch {
		return $null
	}
}

function Get-PathMediaType {
	param([string]$PathValue)

	if (-not $PathValue) { return "Unknown" }
	if ($PathValue -match '^[\\/]{2}') { return "Network" }

	$driveLetter = Get-DriveLetterFromPath -PathValue $PathValue
	if (-not $driveLetter) { return "Unknown" }

	# Best-effort hardware detection (works on modern Windows/PowerShell)
	if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) { return "Unknown" }
	if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) { return "Unknown" }

	try {
		$partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
		$disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
		$mediaType = [string]$disk.MediaType
		if (-not [string]::IsNullOrWhiteSpace($mediaType) -and $mediaType -ne "Unspecified") {
			return $mediaType.ToUpperInvariant()
		}

		# Fallback: Get-PhysicalDisk usually reports accurate HDD/SSD media type
		if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
			try {
				$physical = Get-PhysicalDisk -FriendlyName $disk.FriendlyName -ErrorAction Stop | Select-Object -First 1
				$physicalMedia = [string]$physical.MediaType
				if (-not [string]::IsNullOrWhiteSpace($physicalMedia) -and $physicalMedia -ne "Unspecified") {
					return $physicalMedia.ToUpperInvariant()
				}
			}
			catch { }
		}

		# Final heuristic: NVMe is SSD-class for thread tuning purposes
		if ([string]$disk.BusType -eq "NVMe") {
			return "SSD"
		}
		return "Unknown"
	}
	catch {
		return "Unknown"
	}
}

function Normalize-RouteToken {
	param([string]$Token)

	if (-not $Token) { return $null }
	$normalized = $Token.Trim().ToUpperInvariant()
	if (-not $normalized) { return $null }
	if ($normalized -eq "*" -or $normalized -eq "ANY") { return "*" }
	if ($normalized -eq "UNC" -or $normalized -eq "NETWORK") { return "UNC" }
	if ($normalized -match '^[A-Z]:?$') { return $normalized.Substring(0, 1) }
	return $normalized.TrimEnd('\')
}

function Test-RouteMatch {
	param(
		[string]$Token,
		[string]$PathValue
	)

	$normalizedToken = Normalize-RouteToken -Token $Token
	if (-not $normalizedToken) { return $false }
	if ($normalizedToken -eq "*") { return $true }
	if ($normalizedToken -eq "UNC") { return ($PathValue -match '^[\\/]{2}') }

	$driveLetter = Get-DriveLetterFromPath -PathValue $PathValue
	if ($normalizedToken -match '^[A-Z]$') {
		return ($driveLetter -eq $normalizedToken)
	}

	$normalizedPath = $PathValue.TrimEnd('\').ToUpperInvariant()
	return $normalizedPath.StartsWith($normalizedToken)
}

function Get-TuneConfig {
	param([string]$ConfigPath)

	$config = [ordered]@{
		benchmark_mode = $false
		benchmark      = $false
		hold_window    = $false
		debug_mode     = $false
		default_mt     = $null
		extra_args     = @()
		routes         = @()
	}

	if (-not (Test-Path -LiteralPath $ConfigPath)) {
		return $config
	}

	try {
		$raw = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop
		if (-not [string]::IsNullOrWhiteSpace($raw)) {
			$data = $raw | ConvertFrom-Json -ErrorAction Stop

			# Backward compatibility: mode="benchmark"
			if ($data.mode -and ([string]$data.mode).ToLowerInvariant() -eq "benchmark") {
				$config.benchmark_mode = $true
			}

			if ($null -ne $data.benchmark_mode) {
				$config.benchmark_mode = [bool]$data.benchmark_mode
			}

			if ($null -ne $data.benchmark) {
				$config.benchmark = [bool]$data.benchmark
			}

			if ($null -ne $data.hold_window) {
				$config.hold_window = [bool]$data.hold_window
			}
			if ($null -ne $data.debug_mode) {
				$config.debug_mode = [bool]$data.debug_mode
			}

			if ($null -ne $data.default_mt -and "$($data.default_mt)" -match '^\d+$') {
				$defaultMtValue = [int]$data.default_mt
				if ($defaultMtValue -ge 1 -and $defaultMtValue -le 128) {
					$config.default_mt = $defaultMtValue
				}
			}

			if ($data.extra_args) {
				foreach ($arg in @($data.extra_args)) {
					$argText = [string]$arg
					if ($argText) { $config.extra_args += $argText }
				}
			}

			if ($data.routes) {
				foreach ($route in @($data.routes)) {
					$source = [string]$route.source
					$destination = [string]$route.destination
					$mtText = [string]$route.mt
					if ($source -and $destination -and $mtText -match '^\d+$') {
						$mtValue = [int]$mtText
						if ($mtValue -ge 1 -and $mtValue -le 128) {
							$config.routes += [pscustomobject]@{
								source      = $source
								destination = $destination
								mt          = $mtValue
							}
						}
					}
				}
			}
		}
	}
	catch { }

	return $config
}

function Get-RunSettings {
	param([object]$Config)

	$benchmarkMode = $false
	$debugMode = $false
	if ($Config -and $null -ne $Config.benchmark_mode) {
		$benchmarkMode = [bool]$Config.benchmark_mode
	}
	if ($Config -and $null -ne $Config.debug_mode) {
		$debugMode = [bool]$Config.debug_mode
	}

	if ($benchmarkMode) {
		return [pscustomobject]@{
			BenchmarkMode   = $true
			BenchmarkOutput = $true
			HoldWindow      = $true
			DebugMode       = $debugMode
		}
	}

	$benchmarkOutput = $false
	$holdWindow = $false
	if ($Config -and $null -ne $Config.benchmark) {
		$benchmarkOutput = [bool]$Config.benchmark
	}
	if ($Config -and $null -ne $Config.hold_window) {
		$holdWindow = [bool]$Config.hold_window
	}
	if ($Config -and $null -ne $Config.debug_mode) {
		$debugMode = [bool]$Config.debug_mode
	}

	return [pscustomobject]@{
		BenchmarkMode   = $false
		BenchmarkOutput = $benchmarkOutput
		HoldWindow      = $holdWindow
		DebugMode       = $debugMode
	}
}

function Get-RouteThreadOverride {
	param(
		[object]$Config,
		[string]$SourcePath,
		[string]$DestinationPath
	)

	if (-not $Config -or -not $Config.routes) { return $null }

	foreach ($route in $Config.routes) {
		if ((Test-RouteMatch -Token $route.source -PathValue $SourcePath) -and
			(Test-RouteMatch -Token $route.destination -PathValue $DestinationPath)) {
			return [int]$route.mt
		}
	}

	return $null
}

function Get-ThreadDecision {
	param(
		[string]$SourcePath,
		[string]$DestinationPath
	)

	$sourceMedia = Get-PathMediaType -PathValue $SourcePath
	$destMedia = Get-PathMediaType -PathValue $DestinationPath
	$sourceDrive = Get-DriveLetterFromPath -PathValue $SourcePath
	$destDrive = Get-DriveLetterFromPath -PathValue $DestinationPath
	$sourceDisk = Get-DiskNumberFromPath -PathValue $SourcePath
	$destDisk = Get-DiskNumberFromPath -PathValue $DestinationPath
	$sameDriveLetter = ($sourceDrive -and $destDrive -and $sourceDrive -eq $destDrive)
	$samePhysicalDisk = ($null -ne $sourceDisk -and $null -ne $destDisk -and $sourceDisk -eq $destDisk)

	# Optional per-process override
	if ($env:RCWM_MT -and $env:RCWM_MT -match '^\d+$') {
		$forced = [int]$env:RCWM_MT
		if ($forced -ge 1 -and $forced -le 128) {
			return [pscustomobject]@{
				ThreadCount = $forced
				Reason      = "RCWM_MT env override"
				SourceMedia = $sourceMedia
				DestMedia   = $destMedia
				SourceDisk  = $sourceDisk
				DestDisk    = $destDisk
			}
		}
	}

	$routeOverride = Get-RouteThreadOverride -Config $script:RoboTuneConfig -SourcePath $SourcePath -DestinationPath $DestinationPath
	if ($routeOverride) {
		return [pscustomobject]@{
			ThreadCount = $routeOverride
			Reason      = "RoboTune route override"
			SourceMedia = $sourceMedia
			DestMedia   = $destMedia
			SourceDisk  = $sourceDisk
			DestDisk    = $destDisk
		}
	}

	if ($script:RoboTuneConfig.default_mt) {
		return [pscustomobject]@{
			ThreadCount = [int]$script:RoboTuneConfig.default_mt
			Reason      = "RoboTune default_mt"
			SourceMedia = $sourceMedia
			DestMedia   = $destMedia
			SourceDisk  = $sourceDisk
			DestDisk    = $destDisk
		}
	}

	# Conservative defaults for slow or seek-heavy paths
	if ($sourceMedia -eq "NETWORK" -or $destMedia -eq "NETWORK") {
		$threads = 8
		$reason = "Network path"
	}
	elseif ($sourceMedia -eq "HDD" -or $destMedia -eq "HDD") {
		$threads = 8
		$reason = "HDD involved"
	}
	elseif ($samePhysicalDisk) {
		$threads = 8
		$reason = "Same physical disk"
	}
	elseif ($sameDriveLetter) {
		$threads = 8
		$reason = "Same drive letter"
	}
	elseif ($sourceMedia -eq "SSD" -and $destMedia -eq "SSD") {
		$threads = 32
		$reason = "SSD -> SSD"
	}
	else {
		$threads = 16
		$reason = "Unknown/mixed local media"
	}

	return [pscustomobject]@{
		ThreadCount = $threads
		Reason      = $reason
		SourceMedia = $sourceMedia
		DestMedia   = $destMedia
		SourceDisk  = $sourceDisk
		DestDisk    = $destDisk
	}
}

function Get-DirectoryStats {
	param(
		[string]$PathValue,
		[switch]$SourceIsFile,
		[string[]]$FileFilters
	)

	if (-not (Test-Path -LiteralPath $PathValue)) {
		return [pscustomobject]@{ Files = 0; Bytes = [int64]0 }
	}

	if ($SourceIsFile) {
		$filters = @($FileFilters | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if (@($filters).Count -gt 0) {
			$seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
			$fileCount = 0
			$totalBytes = [int64]0

			foreach ($name in $filters) {
				if (-not $seenNames.Add($name)) { continue }
				$filePath = Join-Path $PathValue $name
				$fileItem = Get-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
				if (-not $fileItem -or $fileItem.PSIsContainer) { continue }
				$fileCount++
				$totalBytes += [int64]$fileItem.Length
			}

			return [pscustomobject]@{ Files = $fileCount; Bytes = $totalBytes }
		}

		$item = Get-Item -LiteralPath $PathValue -Force -ErrorAction SilentlyContinue
		if (-not $item -or $item.PSIsContainer) {
			return [pscustomobject]@{ Files = 0; Bytes = [int64]0 }
		}
		return [pscustomobject]@{ Files = 1; Bytes = [int64]$item.Length }
	}

	$measure = Get-ChildItem -LiteralPath $PathValue -Recurse -File -Force -ErrorAction SilentlyContinue |
		Measure-Object -Property Length -Sum
	$bytes = if ($null -eq $measure.Sum) { [int64]0 } else { [int64]$measure.Sum }
	return [pscustomobject]@{ Files = [int]$measure.Count; Bytes = $bytes }
}

function Format-ByteSize {
	param([Int64]$Bytes)

	if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
	if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
	if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
	if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
	return "$Bytes B"
}

function Get-RobocopyExitDescription {
	param([int]$ExitCode)

	switch ($ExitCode) {
		0 { return "No files copied (nothing to do)" }
		1 { return "Files copied successfully" }
		2 { return "Extra files/dirs detected" }
		3 { return "Files copied + extra files/dirs detected" }
		4 { return "Mismatched files/dirs detected" }
		5 { return "Files copied + mismatches detected" }
		6 { return "Extra files/dirs + mismatches detected" }
		7 { return "Files copied + extra + mismatches detected" }
		default { return "Failure (robocopy exit code >= 8)" }
	}
}

function Write-RunLog {
	param([string]$Message)

	if (-not $script:RunLogPath) { return }
	try {
		$line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
		Add-Content -LiteralPath $script:RunLogPath -Value $line -Encoding UTF8
	}
	catch { }
}

function Open-RoboTuneWindow {
	$roboTunePath = Join-Path $PSScriptRoot "RoboTune.ps1"
	if (-not (Test-Path -LiteralPath $roboTunePath)) {
		Write-Host "RoboTune.ps1 not found: $roboTunePath" -ForegroundColor Yellow
		return
	}

	$argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$roboTunePath`""
	Start-Process -FilePath "pwsh.exe" -ArgumentList $argLine | Out-Null
}

function Wait-ForCloseOrTune {
	param([bool]$Enabled)

	if (-not $Enabled) { return }

	Write-Host ""
	Write-Host "[Enter]=Close  [T]=Open RoboTune  [Esc]=Close" -ForegroundColor Yellow
	while ($true) {
		$keyInfo = [Console]::ReadKey($true)
		switch ($keyInfo.Key) {
			"Enter" { return }
			"Escape" { return }
			"T" {
				Open-RoboTuneWindow
				Write-Host "Opened RoboTune.ps1 in a new PowerShell window." -ForegroundColor Cyan
			}
			default {
				Write-Host "Use Enter, T, or Esc." -ForegroundColor DarkGray
			}
		}
	}
}

function Exit-Script {
	param(
		[int]$Code = 0,
		[string]$Reason = ""
	)

	if ($Reason) {
		Write-RunLog ("Exit requested | Code={0} | Reason={1}" -f $Code, $Reason)
	}
	$hold = $false
	if ($script:RunSettings -and $null -ne $script:RunSettings.HoldWindow) {
		$hold = [bool]$script:RunSettings.HoldWindow
	}
	Wait-ForCloseOrTune -Enabled $hold
	exit $Code
}

function Invoke-RobocopyTransfer {
	param(
		[string]$SourcePath,
		[string]$DestinationPath,
		[string]$ModeFlag,
		[switch]$MergeMode,
		[switch]$SourceIsFile,
		[string[]]$FileFilters
	)

	[object]$decision = $null
	$cacheKey = "$SourcePath|$DestinationPath"
	if ($script:ThreadDecisionCache -and $script:ThreadDecisionCache.TryGetValue($cacheKey, [ref]$decision)) {
		# cached decision reused
	}
	else {
		$decision = Get-ThreadDecision -SourcePath $SourcePath -DestinationPath $DestinationPath
		if ($script:ThreadDecisionCache) {
			$script:ThreadDecisionCache[$cacheKey] = $decision
		}
	}
	$threadCount = [int]$decision.ThreadCount

	$robocopyArgs = @($SourcePath, $DestinationPath)
	if ($SourceIsFile) {
		$effectiveFilters = @($FileFilters | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if (@($effectiveFilters).Count -eq 0) {
			throw "Invoke-RobocopyTransfer: FileFilters are required when SourceIsFile is set."
		}
		$robocopyArgs += $effectiveFilters
	}
	else {
		$robocopyArgs += "/E"
	}
	$robocopyArgs += @("/NP", "/NJH", "/NJS", "/NC", "/NS")
	if (-not $script:RunSettings.DebugMode) {
		# In normal mode suppress per-file/per-dir lines for faster large multi-select operations.
		$robocopyArgs += @("/NFL", "/NDL")
	}
	if ($ModeFlag) {
		$robocopyArgs += $ModeFlag
	}
	if ($MergeMode) {
		$robocopyArgs += @("/XC", "/XN", "/XO")
	}

	if ($script:RoboTuneConfig -and $script:RoboTuneConfig.extra_args) {
		foreach ($extraArg in $script:RoboTuneConfig.extra_args) {
			$argText = [string]$extraArg
			if (-not $argText) { continue }
			if ($argText -match '^/MT(:|$)') { continue }
			$robocopyArgs += $argText
		}
	}

	if ($script:RunSettings.DebugMode) {
		$hasTee = @($robocopyArgs | Where-Object { $_ -match '^/TEE$' }).Count -gt 0
		$hasLog = @($robocopyArgs | Where-Object { $_ -match '^/(LOG|LOG\+|UNILOG|UNILOG\+):' }).Count -gt 0
		$hasVerbose = @($robocopyArgs | Where-Object { $_ -match '^/V$' }).Count -gt 0
		$hasTs = @($robocopyArgs | Where-Object { $_ -match '^/TS$' }).Count -gt 0
		$hasFp = @($robocopyArgs | Where-Object { $_ -match '^/FP$' }).Count -gt 0
		$hasBytes = @($robocopyArgs | Where-Object { $_ -match '^/BYTES$' }).Count -gt 0

		if (-not $hasTee) { $robocopyArgs += "/TEE" }
		if (-not $hasLog) { $robocopyArgs += "/LOG+:$script:RobocopyDebugLogPath" }
		if (-not $hasVerbose) { $robocopyArgs += "/V" }
		if (-not $hasTs) { $robocopyArgs += "/TS" }
		if (-not $hasFp) { $robocopyArgs += "/FP" }
		if (-not $hasBytes) { $robocopyArgs += "/BYTES" }
	}

	$robocopyArgs += "/MT:$threadCount"

	$benchmarkEnabled = [bool]$script:RunSettings.BenchmarkOutput

	$sourceStats = [pscustomobject]@{ Files = 0; Bytes = [int64]0 }
	if ($benchmarkEnabled) {
		$sourceStats = Get-DirectoryStats -PathValue $SourcePath -SourceIsFile:$SourceIsFile -FileFilters $FileFilters
	}

	$showTransferInfo = ([bool]$script:RunSettings.DebugMode -or [bool]$script:RunSettings.BenchmarkOutput)
	$sourceDiskText = if ($null -eq $decision.SourceDisk) { "?" } else { "$($decision.SourceDisk)" }
	$destDiskText = if ($null -eq $decision.DestDisk) { "?" } else { "$($decision.DestDisk)" }
	if ($showTransferInfo) {
		Write-Host "Using /MT:$threadCount [$($decision.Reason)]" -ForegroundColor DarkGray
		Write-Host "Media: $($decision.SourceMedia) (Disk $sourceDiskText) -> $($decision.DestMedia) (Disk $destDiskText)" -ForegroundColor DarkGray
	}
	$writeDetailedRunLog = ([bool]$script:RunSettings.DebugMode -or [bool]$script:RunSettings.BenchmarkOutput)
	if ($writeDetailedRunLog) {
		Write-RunLog ("Transfer start | Source='{0}' | Dest='{1}' | MT={2} | Reason='{3}' | Media={4}->{5}" -f $SourcePath, $DestinationPath, $threadCount, $decision.Reason, $decision.SourceMedia, $decision.DestMedia)
	}

	$timer = [System.Diagnostics.Stopwatch]::StartNew()
	if ($showTransferInfo) {
		$null = (& C:\Windows\System32\robocopy.exe @robocopyArgs | Out-Host)
	}
	else {
		$null = (& C:\Windows\System32\robocopy.exe @robocopyArgs | Out-Null)
	}
	$exitCode = $LASTEXITCODE
	$timer.Stop()

	$elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
	$throughput = "-"
	if ($benchmarkEnabled -and $timer.Elapsed.TotalSeconds -gt 0 -and $sourceStats.Bytes -gt 0) {
		$mbPerSec = ($sourceStats.Bytes / 1MB) / $timer.Elapsed.TotalSeconds
		$throughput = ("{0:N2} MB/s" -f $mbPerSec)
	}

	$exitDescription = Get-RobocopyExitDescription -ExitCode $exitCode
	$statusColor = if ($exitCode -lt 8) { "Green" } else { "Red" }
	if ($showTransferInfo -or $exitCode -ge 8) {
		Write-Host ("Result: ExitCode={0} | {1}" -f $exitCode, $exitDescription) -ForegroundColor $statusColor
	}
	if ($writeDetailedRunLog -or $exitCode -ge 8) {
		Write-RunLog ("Transfer result | ExitCode={0} | Desc='{1}' | Elapsed={2}s | Files={3} | Bytes={4}" -f $exitCode, $exitDescription, $elapsedSeconds, $sourceStats.Files, $sourceStats.Bytes)
	}
	if ($benchmarkEnabled) {
		Write-Host ("Benchmark: Files={0} | Data={1} | Time={2}s | Throughput~{3}" -f $sourceStats.Files, (Format-ByteSize -Bytes $sourceStats.Bytes), $elapsedSeconds, $throughput) -ForegroundColor Cyan
	}

	return [pscustomobject]@{
		ExitCode       = $exitCode
		Succeeded      = ($exitCode -lt 8)
		ThreadCount    = $threadCount
		Reason         = $decision.Reason
		SourceMedia    = $decision.SourceMedia
		DestMedia      = $decision.DestMedia
		Files          = $sourceStats.Files
		Bytes          = $sourceStats.Bytes
		ElapsedSeconds = $elapsedSeconds
	}
}

function Invoke-StagedTransfer {
	param(
		[string]$SourcePath,
		[string]$PasteIntoDirectory,
		[string]$ModeFlag,
		[bool]$IsMove,
		[switch]$MergeMode
	)

	$sourceItem = Get-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
	if (-not $sourceItem) {
		Write-Host "Source item '$SourcePath' does not exist." -ForegroundColor Yellow
		return [pscustomobject]@{
			ItemName = (Split-Path -Path $SourcePath -Leaf)
			Result   = $null
		}
	}

	$itemName = [string]$sourceItem.Name
	if ([string]::IsNullOrWhiteSpace($itemName)) {
		$itemName = Split-Path -Path $SourcePath -Leaf
	}

	if ($sourceItem.PSIsContainer) {
		$destination = Join-Path $PasteIntoDirectory $itemName
		if (-not (Test-Path -LiteralPath $destination)) {
			New-Item -Path $destination -ItemType Directory -Force | Out-Null
		}

		$result = Invoke-RobocopyTransfer -SourcePath $SourcePath -DestinationPath $destination -ModeFlag $ModeFlag -MergeMode:$MergeMode
		if ($IsMove) {
			if ($result.Succeeded) {
				cmd.exe /c rd /s /q "$SourcePath"
			}
			else {
				Write-Host "Skip delete for '$SourcePath' due to robocopy errors." -ForegroundColor Red
			}
		}

		return [pscustomobject]@{
			ItemName = $itemName
			Result   = $result
		}
	}

	$sourceDirectory = [string]$sourceItem.DirectoryName
	if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
		$sourceDirectory = Split-Path -Path $SourcePath -Parent
	}
	if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
		Write-Host "Cannot resolve source directory for file '$SourcePath'." -ForegroundColor Red
		return [pscustomobject]@{
			ItemName = $itemName
			Result   = $null
		}
	}
	$result = Invoke-RobocopyTransfer -SourcePath $sourceDirectory -DestinationPath $PasteIntoDirectory -ModeFlag $ModeFlag -MergeMode:$MergeMode -SourceIsFile -FileFilters @($itemName)

	if ($IsMove) {
		if ($result.Succeeded) {
			Remove-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
		}
		else {
			Write-Host "Skip delete for '$SourcePath' due to robocopy errors." -ForegroundColor Red
		}
	}

	return [pscustomobject]@{
		ItemName = $itemName
		Result   = $result
	}
}

function Split-FileNameBatches {
	param(
		[string[]]$FileNames,
		[int]$MaxChars = 26000
	)

	$allNames = @($FileNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	if (@($allNames).Count -eq 0) { return @() }

	$batches = New-Object System.Collections.Generic.List[object]
	$current = New-Object System.Collections.Generic.List[string]
	$currentChars = 0

	foreach ($name in $allNames) {
		$estimate = [int]$name.Length + 4
		if ($current.Count -gt 0 -and ($currentChars + $estimate) -gt $MaxChars) {
			[void]$batches.Add([string[]]$current.ToArray())
			$current.Clear()
			$currentChars = 0
		}

		[void]$current.Add($name)
		$currentChars += $estimate
	}

	if ($current.Count -gt 0) {
		[void]$batches.Add([string[]]$current.ToArray())
	}

	return [object[]]$batches.ToArray()
}

function Invoke-StagedFileBatchTransfer {
	param(
		[string[]]$FilePaths,
		[string]$PasteIntoDirectory,
		[string]$ModeFlag,
		[bool]$IsMove,
		[switch]$MergeMode
	)

	$paths = @($FilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	if (@($paths).Count -eq 0) {
		return [pscustomobject]@{
			ItemName = ""
			Results  = @()
		}
	}

	$resolvedFilePaths = New-Object System.Collections.Generic.List[string]
	$fileNames = New-Object System.Collections.Generic.List[string]
	$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
	$seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
	$sourceDirectory = $null

	foreach ($path in $paths) {
		if ([string]::IsNullOrWhiteSpace($path)) { continue }

		$itemDirectory = Split-Path -Path $path -Parent
		if ([string]::IsNullOrWhiteSpace($itemDirectory)) { continue }

		if (-not $sourceDirectory) {
			$sourceDirectory = $itemDirectory
		}
		if (-not [string]::Equals($sourceDirectory, $itemDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
			continue
		}

		$fullPath = [string]$path
		if ($seenPaths.Add($fullPath)) {
			[void]$resolvedFilePaths.Add($fullPath)
		}

		$name = Split-Path -Path $path -Leaf
		if ([string]::IsNullOrWhiteSpace($name)) { continue }
		if ($seenNames.Add($name)) {
			[void]$fileNames.Add($name)
		}
	}

	if (-not $sourceDirectory -or $fileNames.Count -eq 0) {
		return [pscustomobject]@{
			ItemName = ""
			Results  = @()
		}
	}

	$results = @()
	$allSucceeded = $true
	$batches = @(Split-FileNameBatches -FileNames ([string[]]$fileNames.ToArray()))
	foreach ($fileBatch in $batches) {
		$result = Invoke-RobocopyTransfer -SourcePath $sourceDirectory -DestinationPath $PasteIntoDirectory -ModeFlag $ModeFlag -MergeMode:$MergeMode -SourceIsFile -FileFilters ([string[]]$fileBatch)
		if ($result) {
			$results += $result
			if (-not $result.Succeeded) { $allSucceeded = $false }
		}
	}

	if ($IsMove) {
		if ($allSucceeded) {
			foreach ($sourceFile in [string[]]$resolvedFilePaths.ToArray()) {
				Remove-Item -LiteralPath $sourceFile -Force -ErrorAction SilentlyContinue
			}
		}
		else {
			Write-Host "Skip delete for file batch in '$sourceDirectory' due to robocopy errors." -ForegroundColor Red
		}
	}

	return [pscustomobject]@{
		ItemName = ("{0} files from '{1}'" -f $resolvedFilePaths.Count, $sourceDirectory)
		Results  = @($results)
	}
}

function Invoke-StagedPathCollection {
	param(
		[string[]]$Paths,
		[string]$PasteIntoDirectory,
		[string]$ModeFlag,
		[bool]$IsMove,
		[switch]$MergeMode,
		[string]$ActionLabel
	)

	$results = @()
	$fileGroups = @{}
	$pathList = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

	foreach ($path in $pathList) {
		$isDirectory = [System.IO.Directory]::Exists($path)
		$isFile = $false
		if (-not $isDirectory) {
			$isFile = [System.IO.File]::Exists($path)
		}

		if (-not $isDirectory -and -not $isFile) {
			Write-Host "Source item '$path' does not exist." -ForegroundColor Yellow
			continue
		}

		if ($isDirectory) {
			$transfer = Invoke-StagedTransfer -SourcePath $path -PasteIntoDirectory $PasteIntoDirectory -ModeFlag $ModeFlag -IsMove:$IsMove -MergeMode:$MergeMode
			if ($transfer.Result) {
				$results += $transfer.Result
			}
			if ($ActionLabel) {
				Write-Output ("Finished {0} {1}" -f $ActionLabel, $transfer.ItemName)
			}
			continue
		}

		$sourceDirectory = Split-Path -Path $path -Parent
		if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
			Write-Host "Cannot resolve source directory for file '$path'." -ForegroundColor Red
			continue
		}

		if (-not $fileGroups.ContainsKey($sourceDirectory)) {
			$fileGroups[$sourceDirectory] = New-Object System.Collections.Generic.List[string]
		}
		[void]$fileGroups[$sourceDirectory].Add($path)
	}

	foreach ($sourceDirectory in @($fileGroups.Keys | Sort-Object)) {
		$fileBatch = Invoke-StagedFileBatchTransfer -FilePaths ([string[]]$fileGroups[$sourceDirectory].ToArray()) -PasteIntoDirectory $PasteIntoDirectory -ModeFlag $ModeFlag -IsMove:$IsMove -MergeMode:$MergeMode
		if ($fileBatch -and $fileBatch.Results) {
			$results += @($fileBatch.Results)
		}
		if ($ActionLabel -and $fileBatch.ItemName) {
			Write-Output ("Finished {0} {1}" -f $ActionLabel, $fileBatch.ItemName)
		}
	}

	return @($results)
}

# Error log file path
$errorLogPath = "$PSScriptRoot\error_log.txt"
$script:RunLogPath = "$PSScriptRoot\run_log.txt"
$script:RobocopyDebugLogPath = "$PSScriptRoot\robocopy_debug.log"
$tuneConfigPath = Join-Path $PSScriptRoot "RoboTune.json"
$script:RoboTuneConfig = Get-TuneConfig -ConfigPath $tuneConfigPath
$script:RunSettings = Get-RunSettings -Config $script:RoboTuneConfig
Write-RunLog "===== START ====="
Write-RunLog ("Config path: {0}" -f $tuneConfigPath)
Write-RunLog ("BenchmarkMode={0} | BenchmarkOutput={1} | HoldWindow={2} | DebugMode={3}" -f $script:RunSettings.BenchmarkMode, $script:RunSettings.BenchmarkOutput, $script:RunSettings.HoldWindow, $script:RunSettings.DebugMode)
if ($script:RunSettings.BenchmarkMode) {
	Write-Host "Benchmark mode is ON (window will stay open at end)." -ForegroundColor Cyan
	Write-Host ("Run log: {0}" -f $script:RunLogPath) -ForegroundColor DarkCyan
}
if ($script:RunSettings.DebugMode) {
	Write-Host ("Debug mode is ON. Robocopy debug log: {0}" -f $script:RobocopyDebugLogPath) -ForegroundColor DarkYellow
	Write-RunLog ("Debug log path: {0}" -f $script:RobocopyDebugLogPath)
}

try {
	# Quick probe mode for tuning/tests without copy operations
	if ($args.Count -ge 3 -and $args[0] -eq "__mtprobe") {
		$probeSource = $args[1]
		$probeDestination = $args[2]
		$probeDecision = Get-ThreadDecision -SourcePath $probeSource -DestinationPath $probeDestination
		Write-Host ("Recommended /MT:{0} [{1}] for '{2}' -> '{3}'" -f $probeDecision.ThreadCount, $probeDecision.Reason, $probeSource, $probeDestination)
		Write-Host ("Detected media: {0} -> {1}" -f $probeDecision.SourceMedia, $probeDecision.DestMedia)
		Write-Host ("Benchmark mode: {0}" -f $script:RunSettings.BenchmarkMode)
		Write-RunLog ("Probe | Source='{0}' | Dest='{1}' | MT={2} | Reason='{3}' | Media={4}->{5}" -f $probeSource, $probeDestination, $probeDecision.ThreadCount, $probeDecision.Reason, $probeDecision.SourceMedia, $probeDecision.DestMedia)
		exit 0
	}

	# Auto-detect mode based on registry keys (check if they have properties, not just exist)
	$mvKey = Get-Item -Path "HKCU:\RCWM\mv" -ErrorAction SilentlyContinue
	$rcKey = Get-Item -Path "HKCU:\RCWM\rc" -ErrorAction SilentlyContinue

	if ($mvKey -and $mvKey.Property.Count -gt 0) {
		$command = "mv"
		$mode = "s"
	}
	elseif ($rcKey -and $rcKey.Property.Count -gt 0) {
		$command = "rc"
		$mode = "s"
	}
	else {
		# Default fallback or error if neither has properties
		$command = $args[0]
		$mode = $args[1]
	}


	# copy / move logic setup
	if ($args.Count -lt 3 -or [string]::IsNullOrWhiteSpace([string]$args[2])) {
		throw "Paste target path is missing."
	}
	$pasteIntoDirectory = [string]$args[2]
	if (-not (Test-Path -LiteralPath $pasteIntoDirectory)) {
		throw "Paste target path does not exist: $pasteIntoDirectory"
	}

	$pasteDirectoryDisplay = "'" + $pasteIntoDirectory + "'"

	if ($command -eq "mv") {
		$flag = "/MOV"
		$string1 = "moved"
		$string2 = "'Robo-Cut'"
		$string3 = "moving"
		$string4 = "move"
	}
	elseif ($command -eq "rc") {
		#rc
		$flag = ""
		$string1 = "copied"
		$string2 = "'Robo-Copy'"
		$string3 = "copying"
		$string4 = "copy"
	}

	# Read staged files/folders from registry list.
	$array = Get-StagedPathList -CommandName $command
	$arrayLength = @($array).Count
	if ($arrayLength -eq 0) {
		NoListAvailable
	}

	#skip prompt on single mode
	if ($mode -eq "m") {

		if ( $arrayLength -eq 1 ) {
			Write-host "You're about to $string4 the following item into" $pasteDirectoryDisplay":"
		}
		else {
			Write-host "You're about to $string4 the following" $array.length "items into" $pasteDirectoryDisplay":"
		}

		$previewLimit = if ($script:RunSettings.DebugMode -or $script:RunSettings.BenchmarkOutput) { 100 } else { 25 }
		$previewItems = @($array | Select-Object -First $previewLimit)
		$previewItems
		$remainingItems = @($array).Count - @($previewItems).Count
		if ($remainingItems -gt 0) {
			Write-Host ("... and {0} more items (hidden for performance)." -f $remainingItems) -ForegroundColor DarkGray
		}

		#Prompt
		Do {
			$Valid = $True
			[string]$prompt = Read-Host -Prompt "Is this okay? (Y/N)"
			Switch ($prompt) {

				default {
					Write-Host "Not a valid entry."
					$Valid = $False
				}	

				{ "y", "yes" -contains $_ } {
					$copy = $True
				}
			
				{ "n", "no" -contains $_ } {

					Do {
						[string]$prompt = Read-Host -Prompt "Delete list of items? (Y/N)"
						Switch ($prompt) {
					
							default {
								Write-Host "Not a valid entry."
								$Valid = $False
							}	

							{ "y", "yes" -contains $_ } {
								Remove-ItemProperty -Path "HKCU:\RCWM\$command" -Name * | Out-Null
								Write-Host "List deleted."
								Start-Sleep 2
								Exit-Script -Code 0 -Reason "User deleted source list."
							}

							{ "n", "no" -contains $_ } {
								Write-Host "Aborting."
								Start-Sleep 3
								Exit-Script -Code 0 -Reason "User aborted copy confirmation."
							}

						}
					} Until ($Valid)
				}
			}
		} Until ($Valid)
	
	}
	else {
		#on single mode just set $copy to $True
		$copy = $True
	}

	If ( $copy -eq $True ) {

		write-host "Begin $string3 ..."
		write-host ""
		$sessionTimer = [System.Diagnostics.Stopwatch]::StartNew()
		$sessionResults = @()
		$isMove = ($command -eq "mv")

		if ($mode -eq "s") {
			# Context-menu fast path: skip pre-scan conflict classification and execute directly.
			$directResults = @(Invoke-StagedPathCollection -Paths $array -PasteIntoDirectory $pasteIntoDirectory -ModeFlag $flag -IsMove:$isMove)
			if ($directResults.Count -gt 0) {
				$sessionResults += $directResults
			}
		}
		else {
			$merge = New-Object System.Collections.Generic.List[string]
			$ready = New-Object System.Collections.Generic.List[string]
			$destinationNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
			foreach ($destItem in @(Get-ChildItem -LiteralPath $pasteIntoDirectory -Force -ErrorAction SilentlyContinue)) {
				if (-not $destItem) { continue }
				$name = [string]$destItem.Name
				if ([string]::IsNullOrWhiteSpace($name)) { continue }
				[void]$destinationNameSet.Add($name)
			}

			foreach ($path in $array) {
				$itemName = Split-Path -Path $path -Leaf
				if ([string]::IsNullOrWhiteSpace($itemName)) {
					continue
				}
				if ($destinationNameSet.Contains($itemName)) {
					[void]$merge.Add($path)
				}
				else {
					[void]$ready.Add($path)
					# Track names that will be created in this run so duplicates in the same selection are treated as conflicts.
					[void]$destinationNameSet.Add($itemName)
				}
			}

			if ($ready.Count -gt 0) {
				$readyResults = @(Invoke-StagedPathCollection -Paths ([string[]]$ready.ToArray()) -PasteIntoDirectory $pasteIntoDirectory -ModeFlag $flag -IsMove:$isMove -ActionLabel $string3)
				if ($readyResults.Count -gt 0) {
					$sessionResults += $readyResults
				}
			}

			#if merge array exists
			if ($merge.Count -gt 0) {
				$mergedPaths = [string[]]$merge.ToArray()
				Write-host "Successfully $string1" $($arrayLength - $merge.Count) "out of" $arrayLength "items."

				if ($merge.Count -eq 1) {
					Write-host "The following item already exists inside" $pasteDirectoryDisplay":"
				}
				else {
					Write-host "The following" $merge.Count "items already exist inside" $pasteDirectoryDisplay":"
				}
				$previewLimit = if ($script:RunSettings.DebugMode -or $script:RunSettings.BenchmarkOutput) { 100 } else { 25 }
				$previewItems = @($mergedPaths | Select-Object -First $previewLimit)
				$previewItems
				$remainingItems = @($mergedPaths).Count - @($previewItems).Count
				if ($remainingItems -gt 0) {
					Write-Host ("... and {0} more conflict items (hidden for performance)." -f $remainingItems) -ForegroundColor DarkGray
				}

				Write-Host ""
				Write-Host "[Enter] = Overwrite | [M] = Merge | [ESC] = Abort" -ForegroundColor Yellow
			
				Do {
					$Valid = $True
					$keyInfo = [Console]::ReadKey($true)
					$key = $keyInfo.Key
				
					Switch ($key) {
						"Enter" {
							Write-Output "Overwriting ..."
							$overwriteResults = @(Invoke-StagedPathCollection -Paths $mergedPaths -PasteIntoDirectory $pasteIntoDirectory -ModeFlag $flag -IsMove:$isMove -ActionLabel "overwriting")
							if ($overwriteResults.Count -gt 0) {
								$sessionResults += $overwriteResults
							}
						}
						"M" {
							Write-Host "Merging ..."
							$mergeResults = @(Invoke-StagedPathCollection -Paths $mergedPaths -PasteIntoDirectory $pasteIntoDirectory -ModeFlag $flag -IsMove:$isMove -MergeMode -ActionLabel "merging")
							if ($mergeResults.Count -gt 0) {
								$sessionResults += $mergeResults
							}
						}
						"Escape" {
							Write-Host "Aborted $string3 the remaining items."
							Remove-ItemProperty -Path "HKCU:\RCWM\$command" -Name * -ErrorAction SilentlyContinue | Out-Null
							Start-Sleep 2
							Exit-Script -Code 2 -Reason "User pressed Escape in merge prompt."
						}
						default {
							Write-Host "Not a valid key. Press Enter, M, or ESC."
							$Valid = $False
						}
					}
				} Until ($Valid)
			}
		}




		$sessionTimer.Stop()
		if ($script:RunSettings.BenchmarkOutput -and $sessionResults.Count -gt 0) {
			# Defensive filtering: count only structured transfer result objects.
			$completedOps = @($sessionResults | Where-Object {
				$null -ne $_ -and $_.PSObject -and $_.PSObject.Properties.Match("Succeeded").Count -gt 0
			})
			$totalBytes = [int64](($completedOps | Measure-Object -Property Bytes -Sum).Sum)
			$totalFiles = [int](($completedOps | Measure-Object -Property Files -Sum).Sum)
			$failedOps = @($completedOps | Where-Object { -not $_.Succeeded }).Count
			$totalSeconds = [Math]::Round($sessionTimer.Elapsed.TotalSeconds, 3)
			$aggregateThroughput = "-"
			if ($sessionTimer.Elapsed.TotalSeconds -gt 0 -and $totalBytes -gt 0) {
				$aggregateThroughput = ("{0:N2} MB/s" -f (($totalBytes / 1MB) / $sessionTimer.Elapsed.TotalSeconds))
			}

			Write-Host ""
			Write-Host "=== Session Benchmark ===" -ForegroundColor Cyan
			Write-Host ("Operations: {0} | Failed: {1}" -f $completedOps.Count, $failedOps) -ForegroundColor Cyan
			Write-Host ("Total files: {0} | Total data: {1}" -f $totalFiles, (Format-ByteSize -Bytes $totalBytes)) -ForegroundColor Cyan
			Write-Host ("Total time: {0}s | Avg throughput~{1}" -f $totalSeconds, $aggregateThroughput) -ForegroundColor Cyan
			Write-RunLog ("Session benchmark | Ops={0} | Failed={1} | Files={2} | Bytes={3} | Time={4}s | Throughput={5}" -f $completedOps.Count, $failedOps, $totalFiles, $totalBytes, $totalSeconds, $aggregateThroughput)
		}

		Remove-ItemProperty -Path "HKCU:\RCWM\$command" -Name * -ErrorAction SilentlyContinue | Out-Null
		Write-Output ""
		Write-Host "Finished!" -ForegroundColor Blue
		Write-RunLog "Finished main flow."
		Wait-ForCloseOrTune -Enabled $script:RunSettings.HoldWindow
	}

}
catch {
	# Log error to file
	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$errorMessage = "[$timestamp] ERROR: $($_.Exception.Message)`nStack Trace: $($_.ScriptStackTrace)`n---`n"
	Add-Content -Path $errorLogPath -Value $errorMessage
	Write-RunLog ("ERROR: {0}" -f $_.Exception.Message)
    
	# Display error to user
	Write-Host "`n[ERROR] Something went wrong!" -ForegroundColor Red
	Write-Host $_.Exception.Message -ForegroundColor Red
	Write-Host "`nError has been logged to: $errorLogPath" -ForegroundColor Yellow
	Write-Host "Run log: $script:RunLogPath" -ForegroundColor Yellow
	Write-Host "Press any key to exit..." -ForegroundColor Yellow
	[Console]::ReadKey($true) | Out-Null
}
