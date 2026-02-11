#if folder name begins with "0", registry doesn't work ..... (\0) == "newline"

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


function NoListAvailable {
	if ($mode -eq "m") {
		echo "List of folders to be $string1 does not exist!"
		Start-Sleep 1
		echo "Create the list by right-clicking on folders and selecting $string2."
		Start-Sleep 3
		exit
	}
 elseif ($mode -eq "s") {
		echo "Folder to be $string1 does not exist!"
		Start-Sleep 1
		echo "Create one by right-clicking on a folder and selecting $string2."
		Start-Sleep 3
		exit
	}
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
	if ($Config -and $null -ne $Config.benchmark_mode) {
		$benchmarkMode = [bool]$Config.benchmark_mode
	}

	if ($benchmarkMode) {
		return [pscustomobject]@{
			BenchmarkMode   = $true
			BenchmarkOutput = $true
			HoldWindow      = $true
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

	return [pscustomobject]@{
		BenchmarkMode   = $false
		BenchmarkOutput = $benchmarkOutput
		HoldWindow      = $holdWindow
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
	param([string]$PathValue)

	if (-not (Test-Path -LiteralPath $PathValue)) {
		return [pscustomobject]@{ Files = 0; Bytes = [int64]0 }
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

function Invoke-RobocopyTransfer {
	param(
		[string]$SourcePath,
		[string]$DestinationPath,
		[string]$ModeFlag,
		[switch]$MergeMode
	)

	$decision = Get-ThreadDecision -SourcePath $SourcePath -DestinationPath $DestinationPath
	$threadCount = [int]$decision.ThreadCount

	$robocopyArgs = @($SourcePath, $DestinationPath, "/E", "/NP", "/NJH", "/NJS", "/NC", "/NS")
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

	$robocopyArgs += "/MT:$threadCount"

	$benchmarkEnabled = [bool]$script:RunSettings.BenchmarkOutput

	$sourceStats = [pscustomobject]@{ Files = 0; Bytes = [int64]0 }
	if ($benchmarkEnabled) {
		$sourceStats = Get-DirectoryStats -PathValue $SourcePath
	}

	$sourceDiskText = if ($null -eq $decision.SourceDisk) { "?" } else { "$($decision.SourceDisk)" }
	$destDiskText = if ($null -eq $decision.DestDisk) { "?" } else { "$($decision.DestDisk)" }
	Write-Host "Using /MT:$threadCount [$($decision.Reason)]" -ForegroundColor DarkGray
	Write-Host "Media: $($decision.SourceMedia) (Disk $sourceDiskText) -> $($decision.DestMedia) (Disk $destDiskText)" -ForegroundColor DarkGray

	$timer = [System.Diagnostics.Stopwatch]::StartNew()
	& C:\Windows\System32\robocopy.exe @robocopyArgs
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
	Write-Host ("Result: ExitCode={0} | {1}" -f $exitCode, $exitDescription) -ForegroundColor $statusColor
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

# Error log file path
$errorLogPath = "$PSScriptRoot\error_log.txt"
$tuneConfigPath = Join-Path $PSScriptRoot "RoboTune.json"
$script:RoboTuneConfig = Get-TuneConfig -ConfigPath $tuneConfigPath
$script:RunSettings = Get-RunSettings -Config $script:RoboTuneConfig

try {
	# Quick probe mode for tuning/tests without copy operations
	if ($args.Count -ge 3 -and $args[0] -eq "__mtprobe") {
		$probeSource = $args[1]
		$probeDestination = $args[2]
		$probeDecision = Get-ThreadDecision -SourcePath $probeSource -DestinationPath $probeDestination
		Write-Host ("Recommended /MT:{0} [{1}] for '{2}' -> '{3}'" -f $probeDecision.ThreadCount, $probeDecision.Reason, $probeSource, $probeDestination)
		Write-Host ("Detected media: {0} -> {1}" -f $probeDecision.SourceMedia, $probeDecision.DestMedia)
		Write-Host ("Benchmark mode: {0}" -f $script:RunSettings.BenchmarkMode)
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
	if ($args[2] -eq $null) {
		#pwsh 4 and less
		$regInsert = (Get-itemproperty -Path "HKCU:\RCWM\$command").dir #must not be string, but string array
		# ... (rest of the block remains same logic but adapted if needed) ...
		# Simplified logic for standalone: Just read the property we know exists

		# Robust way to get the first property name which is our folder path
		$regKey = Get-Item -Path "HKCU:\RCWM\$command"
		$properties = $regKey.Property
    
		if ($properties -and $properties.Count -gt 0) {
			$pasteIntoDirectory = $properties[0]
		}
		else {
			# Fallback if no properties found (should not happen if copy succeeded)
			$pasteIntoDirectory = $null
		}

	}
	else {

		#fix issues with trailing backslash (keep original logic)
		If (($args[2][-1] -eq "'" ) -and ($args[2][-2] -eq "\" )) {
			#pwsh v5
			$pasteIntoDirectory = $args[2].substring(1, 2)
		}
		elseif (($args[2][-1] -eq '"' ) -and ($args[2][-2] -eq ':' )) {
			#pwsh v7
			$pasteIntoDirectory = $args[2].substring(0, 2)
		}
		else {
			$pasteIntoDirectory = $args[2]
		}

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



	#add mirror command


	#get array of contents of paths inside HKCU\RCWM\command
	$array = (Get-Item -Path Registry::HKCU\RCWM\$command).property 2> $null


	$arrayLength = ($array | measure).count

	#delete '(default)' in first place
	try {
		if ( $array[0] -eq "(default)" ) {
			if ($arrayLength -eq 1) {
				$array = $null
			}
			else {
				$array = $array[1..($array.Length - 1)]
			}
		}
		elseif ( $array -eq "(default)" ) {
			#empty registry and powershell v2
			NoListAvailable
		}
	}
	catch {
		NoListAvailable
	}

	#check if list of folders to be copied exist
	if ( $arrayLength -eq 0 ) {
		NoListAvailable
	}

	#skip prompt on single mode
	if ($mode -eq "m") {

		if ( $arrayLength -eq 1 ) {
			Write-host "You're about to $string4 the following folder into" $pasteDirectoryDisplay":"
		}
		else {
			Write-host "You're about to $string4 the following" $array.length "folders into" $pasteDirectoryDisplay":"
		}

		$array

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
						[string]$prompt = Read-Host -Prompt "Delete list of folders? (Y/N)"
						Switch ($prompt) {
					
							default {
								Write-Host "Not a valid entry."
								$Valid = $False
							}	

							{ "y", "yes" -contains $_ } {
								Remove-ItemProperty -Path "HKCU:\RCWM\$command" -Name * | Out-Null
								Write-Host "List deleted."
								Start-Sleep 2
								exit
							}

							{ "n", "no" -contains $_ } {
								Write-Host "Aborting."
								Start-Sleep 3
								exit
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

		foreach ($path in $array) {

			#get folder name

			if ($psversiontable.PSVersion.Major -eq 2) {
				$folder = ($path -split "\\")[-1]
			}
			else {
				$folder = $path.split("\")[-1]
			}



			#concatenation has to be done like this
			[string]$destination = [string]$pasteIntoDirectory + "\" + [string]$folder

			#does source folder exist?
			if (-not ( Test-Path -literalpath "$path" )) {
				echo "Source folder" $path "does not exist."
				continue
			}

			#if exist folder (or file)

			If (Test-Path -literalPath "$destination") {
				#store folders for merge prompt
				#overwrite - or just copy
				[string[]]$merge += $path
			}
			else {
				#make new directory with the same name as the folder being copied

				New-Item -Path "$destination" -ItemType Directory > $null

				$result = Invoke-RobocopyTransfer -SourcePath $path -DestinationPath $destination -ModeFlag $flag
				$sessionResults += $result
			
				if ($command -eq "mv") { 
					if ($result.Succeeded) {
						cmd.exe /c rd /s /q "$path"
					}
					else {
						Write-Host "Skip delete for '$path' due to robocopy errors." -ForegroundColor Red
					}
				}

				echo "Finished $string3 $folder"
			}
		}

		#if merge array exists
		if ($merge) {

			Write-host "Successfully copied" $($arrayLength - $merge.length) "out of" $arrayLength "folders."

			if ($merge.length -eq 1) {
				Write-host "The following folder already exists inside" $pasteDirectoryDisplay":"
			}
			else {
				Write-host "The following" $merge.length "folders already exist inside" $pasteDirectoryDisplay":"
			}
			$merge

			Write-Host ""
			Write-Host "[Enter] = Overwrite | [M] = Merge | [ESC] = Abort" -ForegroundColor Yellow
		
			Do {
				$Valid = $True
				$keyInfo = [Console]::ReadKey($true)
				$key = $keyInfo.Key
			
				Switch ($key) {
					"Enter" {
						Write-Output "Overwriting ..."

						for ($i = 0; $i -lt $merge.length; $i++) {
							$path = $merge[$i]
							$folder = $path.split("\")[-1]
							$destination = $pasteIntoDirectory + "\" + $folder

							$result = Invoke-RobocopyTransfer -SourcePath $path -DestinationPath $destination -ModeFlag $flag
							$sessionResults += $result

							if ($command -eq "mv") { 
								if ($result.Succeeded) {
									cmd.exe /c rd /s /q "$path"
								}
								else {
									Write-Host "Skip delete for '$path' due to robocopy errors." -ForegroundColor Red
								}
							}

							Write-Output "Finished overwriting $folder"
						}

					}
					"M" {
						Write-Host "Merging ..."

						for ($i = 0; $i -lt $merge.length; $i++) {
							$path = $merge[$i]
							$folder = $path.split("\")[-1]
							$destination = $pasteIntoDirectory + "\" + $folder

							$result = Invoke-RobocopyTransfer -SourcePath $path -DestinationPath $destination -ModeFlag $flag -MergeMode
							$sessionResults += $result
								
							if ($command -eq "mv") { 
								if ($result.Succeeded) {
									cmd.exe /c rd /s /q "$path"
								}
								else {
									Write-Host "Skip delete for '$path' due to robocopy errors." -ForegroundColor Red
								}
							}
							Write-Output "Finished merging $folder"
						}


					}
					"Escape" {
						Write-Host "Aborted $string3 the remaining folders."
						Remove-ItemProperty -Path "HKCU:\RCWM\$command" -Name * -ErrorAction SilentlyContinue | Out-Null
						Start-Sleep 2
						exit
					}
					default {
						Write-Host "Not a valid key. Press Enter, M, or ESC."
						$Valid = $False
					}
				}
			} Until ($Valid)
		}




		$sessionTimer.Stop()
		if ($script:RunSettings.BenchmarkOutput -and $sessionResults.Count -gt 0) {
			$totalBytes = [int64](($sessionResults | Measure-Object -Property Bytes -Sum).Sum)
			$totalFiles = [int](($sessionResults | Measure-Object -Property Files -Sum).Sum)
			$failedOps = @($sessionResults | Where-Object { -not $_.Succeeded }).Count
			$totalSeconds = [Math]::Round($sessionTimer.Elapsed.TotalSeconds, 3)
			$aggregateThroughput = "-"
			if ($sessionTimer.Elapsed.TotalSeconds -gt 0 -and $totalBytes -gt 0) {
				$aggregateThroughput = ("{0:N2} MB/s" -f (($totalBytes / 1MB) / $sessionTimer.Elapsed.TotalSeconds))
			}

			Write-Host ""
			Write-Host "=== Session Benchmark ===" -ForegroundColor Cyan
			Write-Host ("Operations: {0} | Failed: {1}" -f $sessionResults.Count, $failedOps) -ForegroundColor Cyan
			Write-Host ("Total files: {0} | Total data: {1}" -f $totalFiles, (Format-ByteSize -Bytes $totalBytes)) -ForegroundColor Cyan
			Write-Host ("Total time: {0}s | Avg throughput~{1}" -f $totalSeconds, $aggregateThroughput) -ForegroundColor Cyan
		}

		Remove-ItemProperty -Path "HKCU:\RCWM\$command" -Name * -ErrorAction SilentlyContinue | Out-Null
		Write-Output ""
		Write-Host "Finished!" -ForegroundColor Blue
		Wait-ForCloseOrTune -Enabled $script:RunSettings.HoldWindow
	}

}
catch {
	# Log error to file
	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$errorMessage = "[$timestamp] ERROR: $($_.Exception.Message)`nStack Trace: $($_.ScriptStackTrace)`n---`n"
	Add-Content -Path $errorLogPath -Value $errorMessage
    
	# Display error to user
	Write-Host "`n[ERROR] Something went wrong!" -ForegroundColor Red
	Write-Host $_.Exception.Message -ForegroundColor Red
	Write-Host "`nError has been logged to: $errorLogPath" -ForegroundColor Yellow
	Write-Host "Press any key to exit..." -ForegroundColor Yellow
	[Console]::ReadKey($true) | Out-Null
}
