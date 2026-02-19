#Robocopy paste engine for staged files/folders (file backend)

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
$script:StageStateDir = Join-Path $PSScriptRoot "state"
$script:StageFilesDir = Join-Path $script:StageStateDir "staging"
$script:StageLockPath = Join-Path $script:StageStateDir "stage.lock"
$script:StageBurstPath = Join-Path $script:StageStateDir "stage.burst"
$script:StageBackendDefault = "file"
$script:StageLockStaleSeconds = 20
$script:StageResolveTimeoutMs = 4000
$script:StageResolveMaxTimeoutMs = 12000
$script:StageBurstStaleSeconds = 6
$script:StageResolvePollMs = 80
$script:SelectAllTokenPrefix = "?WILDCARD?|"
$script:ProtectedMoveRoots = @(
	("{0}\" -f $env:SystemDrive),
	$env:SystemRoot,
	$env:USERPROFILE,
	$env:ProgramFiles,
	${env:ProgramFiles(x86)},
	$env:ProgramData
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

function Normalize-ContextPathValue {
	param([string]$PathValue)

	if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
	$candidate = $PathValue.Trim()
	if ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
		$candidate = $candidate.Substring(1, $candidate.Length - 2)
	}
	if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

	if ($candidate -match '^[A-Za-z]:$') {
		return ($candidate + '\')
	}
	if ($candidate -match '^[A-Za-z]:\\\.$') {
		return ($candidate.Substring(0, 2) + '\')
	}
	if ($candidate.EndsWith('\.')) {
		return $candidate.Substring(0, $candidate.Length - 1)
	}
	return $candidate
}

function Get-PathForSafetyCompare {
	param([string]$PathValue)

	$candidate = Normalize-ContextPathValue -PathValue $PathValue
	if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
	try {
		$candidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
	}
	catch { }

	if ($candidate -match '^[A-Za-z]:\\$') {
		return ($candidate.Substring(0, 1).ToUpperInvariant() + ":\")
	}
	return $candidate.TrimEnd('\')
}

function Test-IsProtectedMovePath {
	param([string]$PathValue)

	$candidate = Get-PathForSafetyCompare -PathValue $PathValue
	if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }

	foreach ($protected in @($script:ProtectedMoveRoots)) {
		$target = Get-PathForSafetyCompare -PathValue $protected
		if ([string]::IsNullOrWhiteSpace($target)) { continue }
		if ([string]::Equals($candidate, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
			return $true
		}
	}
	return $false
}

function NoListAvailable {
	Remove-StageBurstMarker
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
		$candidate = $rawPath.Trim()
		if ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
			$candidate = $candidate.Substring(1, $candidate.Length - 2)
		}
		if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

		if ($seen.Add($candidate)) {
			[void]$out.Add($candidate)
		}
	}

	return [string[]]$out.ToArray()
}

function Test-IsStageWildcardToken {
	param([string]$PathValue)

	if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
	return $PathValue.StartsWith($script:SelectAllTokenPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-StageWildcardTokenMeta {
	param([string]$TokenPath)

	if (-not (Test-IsStageWildcardToken -PathValue $TokenPath)) { return $null }
	$payload = $TokenPath.Substring($script:SelectAllTokenPrefix.Length)
	if ([string]::IsNullOrWhiteSpace($payload)) { return $null }

	$selectedCount = 0
	$source = $payload
	$parts = $payload.Split('|', 2)
	if ($parts.Count -eq 2 -and $parts[0] -match '^\d+$' -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
		try { $selectedCount = [int]$parts[0] } catch { $selectedCount = 0 }
		$source = $parts[1]
	}

	if ([string]::IsNullOrWhiteSpace($source)) { return $null }
	return [pscustomobject]@{
		SelectedCount   = $selectedCount
		SourceDirectory = $source
	}
}

function Get-StageWildcardSourceFromToken {
	param([string]$TokenPath)

	$meta = Get-StageWildcardTokenMeta -TokenPath $TokenPath
	if (-not $meta) { return $null }
	return [string]$meta.SourceDirectory
}

function Remove-KeepRootMarkerFast {
	param([string]$MarkerPath)

	if ([string]::IsNullOrWhiteSpace($MarkerPath)) { return $true }

	# Keep runtime impact near-zero: immediate try first, then a few tiny retries only on failure.
	$retryDelaysMs = @(0, 15, 35, 75)
	foreach ($delayMs in $retryDelaysMs) {
		if ($delayMs -gt 0) {
			Start-Sleep -Milliseconds $delayMs
		}

		try {
			if (-not [System.IO.File]::Exists($MarkerPath)) {
				return $true
			}
			[System.IO.File]::Delete($MarkerPath)
			if (-not [System.IO.File]::Exists($MarkerPath)) {
				return $true
			}
		}
		catch { }
	}

	return (-not [System.IO.File]::Exists($MarkerPath))
}

function Try-DeleteFileTinyRetry {
	param([string]$Path)

	if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

	$retryDelaysMs = @(0, 20, 60, 120)
	foreach ($delayMs in $retryDelaysMs) {
		if ($delayMs -gt 0) {
			Start-Sleep -Milliseconds $delayMs
		}

		try {
			if (-not [System.IO.File]::Exists($Path)) {
				return $true
			}

			try {
				[System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
			}
			catch { }

			[System.IO.File]::Delete($Path)
			if (-not [System.IO.File]::Exists($Path)) {
				return $true
			}
		}
		catch { }
	}

	return (-not [System.IO.File]::Exists($Path))
}

function Resolve-TokenMoveRootLeftovers {
	param(
		[string]$SourceDirectory,
		[string]$DestinationDirectory
	)

	$stats = [pscustomobject]@{
		Checked  = 0
		Eligible = 0
		Cleaned  = 0
		Failed   = 0
		Skipped  = 0
	}

	if ([string]::IsNullOrWhiteSpace($SourceDirectory) -or [string]::IsNullOrWhiteSpace($DestinationDirectory)) {
		return $stats
	}
	if (-not [System.IO.Directory]::Exists($SourceDirectory)) {
		return $stats
	}
	if (-not [System.IO.Directory]::Exists($DestinationDirectory)) {
		return $stats
	}

	$failedSamples = New-Object System.Collections.Generic.List[string]
	$sourceFiles = @()
	try {
		$sourceFiles = @([System.IO.Directory]::EnumerateFiles($SourceDirectory, "*", [System.IO.SearchOption]::TopDirectoryOnly))
	}
	catch {
		return $stats
	}

	foreach ($sourcePath in $sourceFiles) {
		$name = [System.IO.Path]::GetFileName($sourcePath)
		if ([string]::IsNullOrWhiteSpace($name)) {
			continue
		}

		if ($name.StartsWith("__rcwm_keep_root_", [System.StringComparison]::OrdinalIgnoreCase) -and
			$name.EndsWith(".tmp", [System.StringComparison]::OrdinalIgnoreCase)) {
			continue
		}

		$stats.Checked++
		$destinationPath = Join-Path $DestinationDirectory $name
		if (-not [System.IO.File]::Exists($destinationPath)) {
			$stats.Skipped++
			continue
		}

		$sourceInfo = $null
		$destinationInfo = $null
		try {
			$sourceInfo = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
			$destinationInfo = Get-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
		}
		catch {
			$stats.Skipped++
			continue
		}

		if ($sourceInfo.PSIsContainer -or $destinationInfo.PSIsContainer) {
			$stats.Skipped++
			continue
		}

		$sameLength = ([int64]$sourceInfo.Length -eq [int64]$destinationInfo.Length)
		$sameWriteUtc = ($sourceInfo.LastWriteTimeUtc -eq $destinationInfo.LastWriteTimeUtc)
		if (-not ($sameLength -and $sameWriteUtc)) {
			$stats.Skipped++
			continue
		}

		$stats.Eligible++
		if (Try-DeleteFileTinyRetry -Path $sourcePath) {
			$stats.Cleaned++
		}
		else {
			$stats.Failed++
			if ($failedSamples.Count -lt 3) {
				[void]$failedSamples.Add($sourcePath)
			}
		}
	}

	if ($script:RunSettings.DebugMode) {
		Write-RunLog ("DEBUG | SelectAll token root-cleanup | Source='{0}' | Dest='{1}' | Checked={2} | Eligible={3} | Cleaned={4} | Failed={5} | Skipped={6}" -f $SourceDirectory, $DestinationDirectory, $stats.Checked, $stats.Eligible, $stats.Cleaned, $stats.Failed, $stats.Skipped)
	}
	if ($stats.Failed -gt 0) {
		$preview = if ($failedSamples.Count -gt 0) { [string]::Join(" | ", $failedSamples.ToArray()) } else { "" }
		Write-RunLog ("SelectAll token root-cleanup warning | Source='{0}' | Failed={1} | Samples='{2}'" -f $SourceDirectory, $stats.Failed, $preview)
	}

	return $stats
}

function Remove-StageBurstMarker {
	try {
		if (Test-Path -LiteralPath $script:StageBurstPath) {
			Remove-Item -LiteralPath $script:StageBurstPath -Force -ErrorAction SilentlyContinue
		}
	}
	catch { }
}

function Test-StageLockActive {
	try {
		if (-not (Test-Path -LiteralPath $script:StageLockPath)) { return $false }
		$lockItem = Get-Item -LiteralPath $script:StageLockPath -ErrorAction Stop
		$ageSeconds = ((Get-Date) - $lockItem.LastWriteTime).TotalSeconds
		if ($ageSeconds -gt $script:StageLockStaleSeconds) {
			Remove-Item -LiteralPath $script:StageLockPath -Force -ErrorAction SilentlyContinue
			return $false
		}
		return $true
	}
	catch {
		return $false
	}
}

function Test-StageBurstActive {
	try {
		if (-not (Test-Path -LiteralPath $script:StageBurstPath)) { return $false }
		$burstItem = Get-Item -LiteralPath $script:StageBurstPath -ErrorAction Stop
		$ageSeconds = ((Get-Date) - $burstItem.LastWriteTime).TotalSeconds
		if ($ageSeconds -gt $script:StageBurstStaleSeconds) {
			Remove-Item -LiteralPath $script:StageBurstPath -Force -ErrorAction SilentlyContinue
			return $false
		}
		return $true
	}
	catch {
		return $false
	}
}

function Convert-ToUtcDateOrNull {
	param([string]$Text)

	if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
	try {
		return [DateTime]::Parse($Text).ToUniversalTime()
	}
	catch {
		return $null
	}
}

function Get-StageBackend {
	param([object]$Config)
	# Safety lock: stage backend is fixed to file.
	return "file"
}

function Get-StagedFilePath {
	param([ValidateSet("rc", "mv")][string]$CommandName)

	return (Join-Path $script:StageFilesDir ("{0}.stage.json" -f $CommandName))
}

function Get-StagedSnapshotFromRegistry {
	param([ValidateSet("rc", "mv")][string]$CommandName)

	$regPath = "Registry::HKEY_CURRENT_USER\RCWM\$CommandName"
	if (-not (Test-Path -LiteralPath $regPath)) { return $null }

	$item = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
	if (-not $item) { return $null }

	$paths = New-Object System.Collections.Generic.List[string]
	$ignore = @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider")
	foreach ($prop in $item.PSObject.Properties) {
		if ($ignore -contains $prop.Name) { continue }
		if ($prop.Name -eq "(default)") { continue }
		if ($prop.Name.StartsWith("__")) { continue }

		$candidate = [string]$prop.Value
		if ([string]::IsNullOrWhiteSpace($candidate)) {
			$candidate = [string]$prop.Name
		}
		if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
		[void]$paths.Add($candidate)
	}

	$uniquePaths = @(Get-UniquePathList -InputPaths @($paths))
	$actualCount = @($uniquePaths).Count
	$expectedCount = -1
	$hasExpected = $false
	if ($item.PSObject.Properties.Name -contains "__expected_count") {
		$hasExpected = $true
		try { $expectedCount = [int]$item.__expected_count } catch { $expectedCount = -1 }
	}

	$readyFlag = $false
	if ($item.PSObject.Properties.Name -contains "__ready") {
		try { $readyFlag = ([int]$item.__ready -eq 1) } catch { $readyFlag = $false }
	}
	else {
		$readyFlag = ($actualCount -gt 0)
	}

	$lastStageUtc = $null
	if ($item.PSObject.Properties.Name -contains "__last_stage_utc") {
		$lastStageUtc = Convert-ToUtcDateOrNull -Text ([string]$item.__last_stage_utc)
	}

	$sessionId = ""
	if ($item.PSObject.Properties.Name -contains "__session_id") {
		$sessionId = [string]$item.__session_id
	}

	$isReady = $readyFlag -and ($actualCount -gt 0)
	if ($hasExpected -and $expectedCount -ge 0) {
		$isReady = $isReady -and ($actualCount -eq $expectedCount)
	}

	return [pscustomobject]@{
		CommandName   = $CommandName
		Backend       = "registry"
		StageFormat   = "registry-v1"
		StoragePath   = $regPath
		Paths         = $uniquePaths
		ActualCount   = $actualCount
		ExpectedCount = $expectedCount
		HasExpected   = $hasExpected
		ReadyFlag     = $readyFlag
		IsReady       = $isReady
		LastStageUtc  = $lastStageUtc
		SessionId     = $sessionId
	}
}

function Convert-FlatV2ToSnapshot {
	param(
		[ValidateSet("rc", "mv")][string]$CommandName,
		[string]$StageFile,
		[string]$Raw
	)

	if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
	$lines = [regex]::Split($Raw, "`r?`n")
	if ($lines.Count -eq 0) { return $null }

	$headerLine = [string]$lines[0]
	if ([string]::IsNullOrWhiteSpace($headerLine)) { return $null }
	$headerLine = $headerLine.TrimStart([char]0xFEFF).Trim()
	if (-not $headerLine.StartsWith("V2|", [System.StringComparison]::Ordinal)) { return $null }

	$parts = $headerLine.Split('|', 6)
	if ($parts.Count -lt 5) { return $null }
	if (-not [string]::Equals($parts[1], $CommandName, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $null
	}

	$sessionId = if ($parts.Count -ge 3) { [string]$parts[2] } else { "" }
	$lastStageUtc = if ($parts.Count -ge 4) { Convert-ToUtcDateOrNull -Text ([string]$parts[3]) } else { $null }
	$expectedCount = -1
	$hasExpected = $false
	if ($parts.Count -ge 5 -and -not [string]::IsNullOrWhiteSpace([string]$parts[4])) {
		$hasExpected = $true
		try { $expectedCount = [int]$parts[4] } catch { $expectedCount = -1 }
	}

	$pathLines = @()
	if ($lines.Count -gt 1) {
		$pathLines = @($lines[1..($lines.Count - 1)])
	}
	$uniquePaths = @(Get-UniquePathList -InputPaths $pathLines)
	$actualCount = @($uniquePaths).Count
	$readyFlag = $true
	$isReady = $readyFlag -and ($actualCount -gt 0)
	if ($hasExpected -and $expectedCount -ge 0) {
		$isReady = $isReady -and ($actualCount -eq $expectedCount)
	}

	return [pscustomobject]@{
		CommandName   = $CommandName
		Backend       = "file"
		StageFormat   = "file-v2"
		StoragePath   = $stageFile
		Paths         = $uniquePaths
		ActualCount   = $actualCount
		ExpectedCount = $expectedCount
		HasExpected   = $hasExpected
		ReadyFlag     = $readyFlag
		IsReady       = $isReady
		LastStageUtc  = $lastStageUtc
		SessionId     = $sessionId
	}
}

function Convert-LegacyJsonToSnapshot {
	param(
		[ValidateSet("rc", "mv")][string]$CommandName,
		[string]$StageFile,
		[object]$Data
	)

	$paths = @()
	if ($Data.items) {
		$paths = @($Data.items | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	}
	$uniquePaths = @(Get-UniquePathList -InputPaths $paths)
	$actualCount = @($uniquePaths).Count
	$expectedCount = -1
	$hasExpected = $false
	if ($Data.PSObject.Properties.Name -contains "expected_count") {
		$hasExpected = $true
		try { $expectedCount = [int]$Data.expected_count } catch { $expectedCount = -1 }
	}

	$readyFlag = $false
	if ($Data.PSObject.Properties.Name -contains "ready") {
		try { $readyFlag = [bool]$Data.ready } catch { $readyFlag = $false }
	}
	else {
		$readyFlag = ($actualCount -gt 0)
	}

	$lastStageUtc = Convert-ToUtcDateOrNull -Text ([string]$Data.last_stage_utc)
	$sessionId = ""
	if ($Data.PSObject.Properties.Name -contains "session_id") {
		$sessionId = [string]$Data.session_id
	}

	$isReady = $readyFlag -and ($actualCount -gt 0)
	if ($hasExpected -and $expectedCount -ge 0) {
		$isReady = $isReady -and ($actualCount -eq $expectedCount)
	}

	return [pscustomobject]@{
		CommandName   = $CommandName
		Backend       = "file"
		StageFormat   = "file-json-v1"
		StoragePath   = $stageFile
		Paths         = $uniquePaths
		ActualCount   = $actualCount
		ExpectedCount = $expectedCount
		HasExpected   = $hasExpected
		ReadyFlag     = $readyFlag
		IsReady       = $isReady
		LastStageUtc  = $lastStageUtc
		SessionId     = $sessionId
	}
}

function Get-StagedSnapshotFromFile {
	param([ValidateSet("rc", "mv")][string]$CommandName)

	$stageFile = Get-StagedFilePath -CommandName $CommandName
	if (-not (Test-Path -LiteralPath $stageFile)) { return $null }

	try {
		$raw = Get-Content -Raw -LiteralPath $stageFile -ErrorAction Stop
		if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

		$v2 = Convert-FlatV2ToSnapshot -CommandName $CommandName -StageFile $stageFile -Raw $raw
		if ($v2) { return $v2 }

		$data = $raw | ConvertFrom-Json -ErrorAction Stop
		$legacy = Convert-LegacyJsonToSnapshot -CommandName $CommandName -StageFile $stageFile -Data $data
		return $legacy
	}
	catch {
		return $null
	}
}

function Get-StagedSnapshot {
	param(
		[ValidateSet("rc", "mv")][string]$CommandName,
		[ValidateSet("file", "registry")][string]$Backend = "file"
	)

	if ($Backend -eq "registry") {
		return (Get-StagedSnapshotFromRegistry -CommandName $CommandName)
	}

	return (Get-StagedSnapshotFromFile -CommandName $CommandName)
}

function Resolve-StagedPayload {
	param(
		[string]$RequestedCommand = "auto",
		[ValidateSet("file", "registry")][string]$Backend = "file",
		[int]$TimeoutMs = $script:StageResolveTimeoutMs,
		[int]$PollMs = $script:StageResolvePollMs
	)

	$requested = if ([string]::IsNullOrWhiteSpace($RequestedCommand)) { "auto" } else { $RequestedCommand.ToLowerInvariant() }
	$commands = if ($requested -in @("rc", "mv")) { @($requested) } else { @("mv", "rc") }
	$timer = [System.Diagnostics.Stopwatch]::StartNew()
	$extended = $false
	$maxTimeout = [Math]::Max($TimeoutMs, $script:StageResolveMaxTimeoutMs)

	while ($true) {
		$snapshots = @()
		foreach ($cmd in $commands) {
			$snapshot = Get-StagedSnapshot -CommandName $cmd -Backend $Backend
			if ($snapshot) {
				$snapshots += $snapshot
			}
		}

		$ready = @($snapshots | Where-Object { $_.IsReady })
		if ($ready.Count -gt 0) {
			$selected = $ready |
				Sort-Object @{
					Expression = { if ($_.LastStageUtc) { $_.LastStageUtc } else { [datetime]::MinValue } }
					Descending = $true
				}, @{
					Expression = { $_.ActualCount }
					Descending = $true
				} |
				Select-Object -First 1
			return $selected
		}

		$lockActive = Test-StageLockActive
		$burstActive = Test-StageBurstActive
		$elapsed = $timer.ElapsedMilliseconds

		if ($elapsed -ge $TimeoutMs) {
			if (-not $extended -and ($lockActive -or $burstActive)) {
				$extended = $true
				Write-RunLog ("Stage resolve extending wait | Requested={0} | WaitMs={1} | LockActive={2} | BurstActive={3}" -f $requested, $elapsed, $lockActive, $burstActive)
			}

			if ($elapsed -ge $maxTimeout -or (-not $lockActive -and -not $burstActive)) {
				if ($snapshots.Count -gt 0) {
					$latest = $snapshots |
						Sort-Object @{
							Expression = { if ($_.LastStageUtc) { $_.LastStageUtc } else { [datetime]::MinValue } }
							Descending = $true
						} |
						Select-Object -First 1
					Write-RunLog ("Stage resolve timeout | Requested={0} | WaitMs={1} | Command={2} | Ready={3} | Expected={4} | Actual={5} | Session={6} | LockActive={7} | BurstActive={8}" -f $requested, $elapsed, $latest.CommandName, $latest.ReadyFlag, $latest.ExpectedCount, $latest.ActualCount, $latest.SessionId, $lockActive, $burstActive)
				}
				else {
					Write-RunLog ("Stage resolve timeout | Requested={0} | Backend={1} | WaitMs={2} | No stage snapshot found | LockActive={3} | BurstActive={4}" -f $requested, $Backend, $elapsed, $lockActive, $burstActive)
				}
				return $null
			}
		}

		Start-Sleep -Milliseconds $PollMs
	}
}

function Clear-StagedRegistryKey {
	param([ValidateSet("rc", "mv")][string]$CommandName)

	$regPath = "Registry::HKEY_CURRENT_USER\RCWM\$CommandName"
	try {
		if (Test-Path -LiteralPath $regPath) {
			Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
		}
		New-Item -Path $regPath -Force | Out-Null
	}
	catch { }
}

function Clear-StagedFile {
	param([ValidateSet("rc", "mv")][string]$CommandName)

	$stageFile = Get-StagedFilePath -CommandName $CommandName
	try {
		if (Test-Path -LiteralPath $stageFile) {
			Remove-Item -LiteralPath $stageFile -Force -ErrorAction SilentlyContinue
		}
	}
	catch { }
}

function Clear-StagedPayload {
	param(
		[ValidateSet("rc", "mv")][string]$CommandName,
		[ValidateSet("file", "registry")][string]$Backend = "file"
	)

	if ($Backend -eq "registry") {
		Clear-StagedRegistryKey -CommandName $CommandName
		return
	}

	Clear-StagedFile -CommandName $CommandName
	# Compatibility cleanup for VBS burst-suppression metadata mirror.
	Clear-StagedRegistryKey -CommandName $CommandName
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
	if ($PathValue -match '^[\\/]{2}') { return "LAN" }

	$driveLetter = Get-DriveLetterFromPath -PathValue $PathValue
	if (-not $driveLetter) { return "Unknown" }

	# Best-effort hardware detection (works on modern Windows/PowerShell)
	if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) { return "Unknown" }
	if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) { return "Unknown" }

	try {
		$partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
		$disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
		$busType = [string]$disk.BusType
		if (-not [string]::IsNullOrWhiteSpace($busType) -and $busType.ToUpperInvariant() -eq "USB") {
			return "USB"
		}
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

function Get-TuneConfig {
	param([string]$ConfigPath)

	$config = [ordered]@{
		benchmark_mode = $false
		benchmark      = $false
		hold_window    = $false
		debug_mode     = $false
		mt_rules       = [ordered]@{
			ssd_to_ssd              = 32
			ssd_hdd_any             = 8
			hdd_to_hdd_diff_volume  = 8
			hdd_to_hdd_same_volume  = 8
			lan_any                 = 8
			usb_any                 = 8
			unknown_local           = 8
		}
		extra_args     = @()
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
			if ($data.mt_rules) {
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
					$ruleValue = $data.mt_rules.$ruleName
					if ($null -ne $ruleValue -and "$ruleValue" -match '^\d+$') {
						$mtRule = [int]$ruleValue
						if ($mtRule -ge 1 -and $mtRule -le 128) {
							$config.mt_rules[$ruleName] = $mtRule
							if ($ruleName -eq "ssd_hdd_any") { $hasSsdHddAny = $true }
							elseif ($ruleName -eq "lan_any") { $hasLanAny = $true }
							elseif ($ruleName -eq "usb_any") { $hasUsbAny = $true }
						}
					}
				}

				if (-not $hasSsdHddAny) {
					$legacySsdToHdd = $data.mt_rules.ssd_to_hdd
					$legacyHddToSsd = $data.mt_rules.hdd_to_ssd
					$legacyMixed = $null
					if ($null -ne $legacySsdToHdd -and "$legacySsdToHdd" -match '^\d+$') {
						$legacyMixed = [int]$legacySsdToHdd
					}
					elseif ($null -ne $legacyHddToSsd -and "$legacyHddToSsd" -match '^\d+$') {
						$legacyMixed = [int]$legacyHddToSsd
					}
					if ($null -ne $legacyMixed -and $legacyMixed -ge 1 -and $legacyMixed -le 128) {
						$config.mt_rules.ssd_hdd_any = $legacyMixed
					}
				}

				if (-not $hasLanAny) {
					$legacyNetworkAny = $data.mt_rules.network_any
					if ($null -ne $legacyNetworkAny -and "$legacyNetworkAny" -match '^\d+$') {
						$legacyLan = [int]$legacyNetworkAny
						if ($legacyLan -ge 1 -and $legacyLan -le 128) {
							$config.mt_rules.lan_any = $legacyLan
						}
					}
				}

				if (-not $hasUsbAny) {
					$legacyUnknown = $data.mt_rules.unknown_local
					if ($null -ne $legacyUnknown -and "$legacyUnknown" -match '^\d+$') {
						$legacyUsb = [int]$legacyUnknown
						if ($legacyUsb -ge 1 -and $legacyUsb -le 128) {
							$config.mt_rules.usb_any = $legacyUsb
						}
					}
				}
			}

			if ($data.extra_args) {
				foreach ($arg in @($data.extra_args)) {
					$argText = [string]$arg
					if ($argText) { $config.extra_args += $argText }
				}
			}

		}
	}
	catch { }

	return $config
}

function Get-MtRuleValue {
	param(
		[object]$Config,
		[string]$RuleName,
		[int]$FallbackValue
	)

	if ($Config -and $Config.mt_rules) {
		$ruleCandidate = $Config.mt_rules.$RuleName
		if ($null -ne $ruleCandidate -and "$ruleCandidate" -match '^\d+$') {
			$mt = [int]$ruleCandidate
			if ($mt -ge 1 -and $mt -le 128) {
				return $mt
			}
		}
	}

	return $FallbackValue
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

	# Media-based rules (configurable via RoboTune mt_rules).
	if ($sourceMedia -eq "LAN" -or $destMedia -eq "LAN") {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "lan_any" -FallbackValue 8
		$reason = "RoboTune mt_rules: lan_any"
	}
	elseif ($sourceMedia -eq "USB" -or $destMedia -eq "USB") {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "usb_any" -FallbackValue 8
		$reason = "RoboTune mt_rules: usb_any"
	}
	elseif ($sourceMedia -eq "SSD" -and $destMedia -eq "SSD") {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "ssd_to_ssd" -FallbackValue 32
		$reason = "RoboTune mt_rules: ssd_to_ssd"
	}
	elseif (
		($sourceMedia -eq "SSD" -and $destMedia -eq "HDD") -or
		($sourceMedia -eq "HDD" -and $destMedia -eq "SSD")
	) {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "ssd_hdd_any" -FallbackValue 8
		$reason = "RoboTune mt_rules: ssd_hdd_any"
	}
	elseif ($sourceMedia -eq "HDD" -and $destMedia -eq "HDD") {
		if ($samePhysicalDisk -or $sameDriveLetter) {
			$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "hdd_to_hdd_same_volume" -FallbackValue 8
			$reason = "RoboTune mt_rules: hdd_to_hdd_same_volume"
		}
		else {
			$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "hdd_to_hdd_diff_volume" -FallbackValue 8
			$reason = "RoboTune mt_rules: hdd_to_hdd_diff_volume"
		}
	}
	elseif ($samePhysicalDisk) {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "unknown_local" -FallbackValue 8
		$reason = "RoboTune mt_rules: unknown_local (same physical disk)"
	}
	elseif ($sameDriveLetter) {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "unknown_local" -FallbackValue 8
		$reason = "RoboTune mt_rules: unknown_local (same drive letter)"
	}
	else {
		$threads = Get-MtRuleValue -Config $script:RoboTuneConfig -RuleName "unknown_local" -FallbackValue 8
		$reason = "RoboTune mt_rules: unknown_local"
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

function Test-IsSameVolumePath {
	param(
		[string]$SourcePath,
		[string]$DestinationPath
	)

	$sourceNormalized = Normalize-ContextPathValue -PathValue $SourcePath
	$destNormalized = Normalize-ContextPathValue -PathValue $DestinationPath
	if ([string]::IsNullOrWhiteSpace($sourceNormalized) -or [string]::IsNullOrWhiteSpace($destNormalized)) {
		return $false
	}

	try { $sourceNormalized = (Resolve-Path -LiteralPath $sourceNormalized -ErrorAction Stop).ProviderPath } catch { }
	try { $destNormalized = (Resolve-Path -LiteralPath $destNormalized -ErrorAction Stop).ProviderPath } catch { }

	$sourceRoot = [System.IO.Path]::GetPathRoot($sourceNormalized)
	$destRoot = [System.IO.Path]::GetPathRoot($destNormalized)
	if ([string]::IsNullOrWhiteSpace($sourceRoot) -or [string]::IsNullOrWhiteSpace($destRoot)) {
		return $false
	}

	return [string]::Equals($sourceRoot.TrimEnd('\'), $destRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsPathInside {
	param(
		[string]$ParentPath,
		[string]$CandidatePath
	)

	$parentNormalized = Normalize-ContextPathValue -PathValue $ParentPath
	$candidateNormalized = Normalize-ContextPathValue -PathValue $CandidatePath
	if ([string]::IsNullOrWhiteSpace($parentNormalized) -or [string]::IsNullOrWhiteSpace($candidateNormalized)) {
		return $false
	}

	try { $parentNormalized = (Resolve-Path -LiteralPath $parentNormalized -ErrorAction Stop).ProviderPath } catch { }
	try { $candidateNormalized = (Resolve-Path -LiteralPath $candidateNormalized -ErrorAction Stop).ProviderPath } catch { }

	$parentTrimmed = $parentNormalized.TrimEnd('\')
	$candidateTrimmed = $candidateNormalized.TrimEnd('\')
	if ([string]::IsNullOrWhiteSpace($parentTrimmed) -or [string]::IsNullOrWhiteSpace($candidateTrimmed)) {
		return $false
	}

	$parentPrefix = $parentTrimmed + "\"
	return $candidateTrimmed.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
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

function Get-ModeFlagTokens {
	param([object]$ModeFlag)

	if ($null -eq $ModeFlag) {
		return @()
	}

	$rawValues = @($ModeFlag)
	$tokens = New-Object System.Collections.Generic.List[string]
	foreach ($rawValue in $rawValues) {
		if ($null -eq $rawValue) { continue }
		$parts = @(([string]$rawValue -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		foreach ($part in $parts) {
			[void]$tokens.Add($part)
		}
	}

	return [string[]]$tokens.ToArray()
}

function Invoke-RobocopyTransfer {
	param(
		[string]$SourcePath,
		[string]$DestinationPath,
		[object]$ModeFlag,
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
	$modeTokens = @(Get-ModeFlagTokens -ModeFlag $ModeFlag)
	if ($modeTokens.Count -gt 0) {
		$robocopyArgs += $modeTokens
	}
	if ($script:RunSettings.DebugMode) {
		Write-RunLog ("DEBUG | TransferModeTokens | Count={0} | Tokens='{1}'" -f $modeTokens.Count, ([string]::Join(' ', $modeTokens)))
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
		if ($IsMove -and (Test-IsPathInside -ParentPath $SourcePath -CandidatePath $destination)) {
			$message = ("Blocked move: destination is inside source. Source='{0}' | Dest='{1}'" -f $SourcePath, $destination)
			Write-Host $message -ForegroundColor Red
			Write-RunLog ("Safety guard blocked move | Reason=DestinationInsideSource | Source='{0}' | Dest='{1}'" -f $SourcePath, $destination)
			return [pscustomobject]@{
				ItemName = $itemName
				Result   = [pscustomobject]@{
					ExitCode       = 16
					Succeeded      = $false
					ThreadCount    = 0
					Reason         = "Destination inside source blocked"
					SourceMedia    = "-"
					DestMedia      = "-"
					Files          = 0
					Bytes          = [int64]0
					ElapsedSeconds = 0
				}
			}
		}

		$canUseNativeMove = $IsMove -and -not $MergeMode -and (-not (Test-Path -LiteralPath $destination)) -and (Test-IsSameVolumePath -SourcePath $SourcePath -DestinationPath $destination)
		if ($canUseNativeMove) {
			$fastTimer = [System.Diagnostics.Stopwatch]::StartNew()
			$stats = [pscustomobject]@{ Files = 0; Bytes = [int64]0 }
			if ($script:RunSettings.BenchmarkOutput) {
				$stats = Get-DirectoryStats -PathValue $SourcePath
			}
			try {
				Move-Item -LiteralPath $SourcePath -Destination $destination -Force -ErrorAction Stop
				$fastTimer.Stop()
				$elapsedSeconds = [Math]::Round($fastTimer.Elapsed.TotalSeconds, 3)
				Write-RunLog ("FastPath native-move used | Type=Directory | Source='{0}' | Dest='{1}' | Elapsed={2}s" -f $SourcePath, $destination, $elapsedSeconds)
				$result = [pscustomobject]@{
					ExitCode       = 1
					Succeeded      = $true
					ThreadCount    = 0
					Reason         = "Same-volume native move fast path"
					SourceMedia    = "-"
					DestMedia      = "-"
					Files          = $stats.Files
					Bytes          = $stats.Bytes
					ElapsedSeconds = $elapsedSeconds
				}
				return [pscustomobject]@{
					ItemName = $itemName
					Result   = $result
				}
			}
			catch {
				Write-RunLog ("FastPath native-move fallback | Type=Directory | Source='{0}' | Dest='{1}' | Error='{2}'" -f $SourcePath, $destination, $_.Exception.Message)
			}
		}

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

	$fileDestination = Join-Path $PasteIntoDirectory $itemName
	$canUseNativeMove = $IsMove -and -not $MergeMode -and (-not (Test-Path -LiteralPath $fileDestination)) -and (Test-IsSameVolumePath -SourcePath $SourcePath -DestinationPath $fileDestination)
	if ($canUseNativeMove) {
		$fastTimer = [System.Diagnostics.Stopwatch]::StartNew()
		$fileBytes = [int64]0
		if ($script:RunSettings.BenchmarkOutput) {
			$fileBytes = [int64]$sourceItem.Length
		}
		try {
			Move-Item -LiteralPath $SourcePath -Destination $fileDestination -Force -ErrorAction Stop
			$fastTimer.Stop()
			$elapsedSeconds = [Math]::Round($fastTimer.Elapsed.TotalSeconds, 3)
			Write-RunLog ("FastPath native-move used | Type=File | Source='{0}' | Dest='{1}' | Elapsed={2}s" -f $SourcePath, $fileDestination, $elapsedSeconds)
			$result = [pscustomobject]@{
				ExitCode       = 1
				Succeeded      = $true
				ThreadCount    = 0
				Reason         = "Same-volume native move fast path"
				SourceMedia    = "-"
				DestMedia      = "-"
				Files          = 1
				Bytes          = $fileBytes
				ElapsedSeconds = $elapsedSeconds
			}
			return [pscustomobject]@{
				ItemName = $itemName
				Result   = $result
			}
		}
		catch {
			Write-RunLog ("FastPath native-move fallback | Type=File | Source='{0}' | Dest='{1}' | Error='{2}'" -f $SourcePath, $fileDestination, $_.Exception.Message)
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

function Test-IsFullTopLevelFileSelection {
	param(
		[string]$SourceDirectory,
		[string[]]$SelectedFileNames
	)

	if ([string]::IsNullOrWhiteSpace($SourceDirectory)) { return $false }
	$selected = @($SelectedFileNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	if (@($selected).Count -eq 0) { return $false }

	$allTopFiles = @(Get-ChildItem -LiteralPath $SourceDirectory -File -Force -ErrorAction SilentlyContinue)
	if (@($allTopFiles).Count -eq 0) { return $false }
	if (@($allTopFiles).Count -ne @($selected).Count) { return $false }

	$selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($name in $selected) {
		[void]$selectedSet.Add($name)
	}

	foreach ($file in $allTopFiles) {
		$name = [string]$file.Name
		if (-not $selectedSet.Contains($name)) {
			return $false
		}
	}

	return $true
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
	$canUseNativeMoveBatch = $IsMove -and -not $MergeMode -and (Test-IsSameVolumePath -SourcePath $sourceDirectory -DestinationPath $PasteIntoDirectory)
	if ($canUseNativeMoveBatch) {
		$hasConflict = $false
		foreach ($name in [string[]]$fileNames.ToArray()) {
			$destPath = Join-Path $PasteIntoDirectory $name
			if (Test-Path -LiteralPath $destPath) {
				$hasConflict = $true
				break
			}
		}

		if (-not $hasConflict) {
			$fastTimer = [System.Diagnostics.Stopwatch]::StartNew()
			$totalBytes = [int64]0
			if ($script:RunSettings.BenchmarkOutput) {
				foreach ($sourceFile in [string[]]$resolvedFilePaths.ToArray()) {
					$item = Get-Item -LiteralPath $sourceFile -Force -ErrorAction SilentlyContinue
					if ($item -and -not $item.PSIsContainer) {
						$totalBytes += [int64]$item.Length
					}
				}
			}

			$movedCount = 0
			try {
				foreach ($sourceFile in [string[]]$resolvedFilePaths.ToArray()) {
					Move-Item -LiteralPath $sourceFile -Destination $PasteIntoDirectory -Force -ErrorAction Stop
					$movedCount++
				}
				$fastTimer.Stop()
				$elapsedSeconds = [Math]::Round($fastTimer.Elapsed.TotalSeconds, 3)
				Write-RunLog ("FastPath native-move used | Type=FileBatch | Source='{0}' | Dest='{1}' | Count={2} | Elapsed={3}s" -f $sourceDirectory, $PasteIntoDirectory, $movedCount, $elapsedSeconds)
				$results += [pscustomobject]@{
					ExitCode       = 1
					Succeeded      = $true
					ThreadCount    = 0
					Reason         = "Same-volume native move fast path"
					SourceMedia    = "-"
					DestMedia      = "-"
					Files          = $movedCount
					Bytes          = $totalBytes
					ElapsedSeconds = $elapsedSeconds
				}
				return [pscustomobject]@{
					ItemName = ("{0} files from '{1}'" -f $movedCount, $sourceDirectory)
					Results  = @($results)
				}
			}
			catch {
				Write-RunLog ("FastPath native-move fallback | Type=FileBatch | Source='{0}' | Dest='{1}' | Error='{2}'" -f $sourceDirectory, $PasteIntoDirectory, $_.Exception.Message)
			}
		}
	}

	$useWildcardAllFiles = Test-IsFullTopLevelFileSelection -SourceDirectory $sourceDirectory -SelectedFileNames ([string[]]$fileNames.ToArray())
	if ($useWildcardAllFiles) {
		$result = Invoke-RobocopyTransfer -SourcePath $sourceDirectory -DestinationPath $PasteIntoDirectory -ModeFlag $ModeFlag -MergeMode:$MergeMode -SourceIsFile -FileFilters @("*")
		if ($result) {
			$results += $result
			if (-not $result.Succeeded) { $allSucceeded = $false }
		}
		Write-RunLog ("FastPath wildcard-all-files used | Source='{0}' | Count={1}" -f $sourceDirectory, $fileNames.Count)
	}
	else {
		$batches = @(Split-FileNameBatches -FileNames ([string[]]$fileNames.ToArray()))
		foreach ($fileBatch in $batches) {
			$result = Invoke-RobocopyTransfer -SourcePath $sourceDirectory -DestinationPath $PasteIntoDirectory -ModeFlag $ModeFlag -MergeMode:$MergeMode -SourceIsFile -FileFilters ([string[]]$fileBatch)
			if ($result) {
				$results += $result
				if (-not $result.Succeeded) { $allSucceeded = $false }
			}
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

	if ($pathList.Count -eq 1 -and (Test-IsStageWildcardToken -PathValue $pathList[0])) {
		$tokenPath = [string]$pathList[0]
		$tokenMeta = Get-StageWildcardTokenMeta -TokenPath $tokenPath
		$sourceDirectory = if ($tokenMeta) { [string]$tokenMeta.SourceDirectory } else { $null }
		$tokenSelectedCount = if ($tokenMeta) { [int]$tokenMeta.SelectedCount } else { 0 }
		if ([string]::IsNullOrWhiteSpace($sourceDirectory) -or -not [System.IO.Directory]::Exists($sourceDirectory)) {
			Write-Host "Source directory from staged token does not exist: $sourceDirectory" -ForegroundColor Yellow
			Write-RunLog ("SelectAll token rejected | Reason=MissingSource | Token='{0}'" -f $tokenPath)
			return @()
		}

		$modeTokens = @(Get-ModeFlagTokens -ModeFlag $ModeFlag)

		$filteredTokens = New-Object System.Collections.Generic.List[string]
		$tokenSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($token in $modeTokens) {
			if ($token -match '^(?i)/(MOV|MOVE)$') { continue }
			if ($tokenSet.Add($token)) {
				[void]$filteredTokens.Add($token)
			}
		}
		if ($IsMove) {
			if ($tokenSet.Add('/MOVE')) {
				[void]$filteredTokens.Add('/MOVE')
			}
			# For tokenized select-all moves, include /IS so same-name/same-content files are processed
			# and removed from source as part of move semantics.
			if ($tokenSet.Add('/IS')) {
				[void]$filteredTokens.Add('/IS')
			}
		}

		$rootKeepFilePath = $null
		if ($IsMove) {
			try {
				$rootKeepFileName = ("__rcwm_keep_root_{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
				$rootKeepFilePath = Join-Path $sourceDirectory $rootKeepFileName
				[System.IO.File]::WriteAllText($rootKeepFilePath, "")
				if ($tokenSet.Add('/XF')) {
					[void]$filteredTokens.Add('/XF')
				}
				[void]$filteredTokens.Add($rootKeepFileName)
				Write-RunLog ("SelectAll token move guard | Keep-root marker='{0}'" -f $rootKeepFileName)
			}
			catch {
				$rootKeepFilePath = $null
				Write-RunLog ("SelectAll token move guard warning | Failed to create keep-root marker in '{0}' | {1}" -f $sourceDirectory, $_.Exception.Message)
			}
		}

		$effectiveModeTokens = [string[]]$filteredTokens.ToArray()
		$effectiveModeText = [string]::Join(' ', $effectiveModeTokens)

		Write-RunLog ("SelectAll token transfer | Source='{0}' | Dest='{1}' | ModeFlag='{2}' | IsMove={3} | MergeMode={4} | SelectedCount={5}" -f $sourceDirectory, $PasteIntoDirectory, $effectiveModeText, $IsMove, [bool]$MergeMode, $tokenSelectedCount)
		$tokenResult = $null
		try {
			$tokenResult = Invoke-RobocopyTransfer -SourcePath $sourceDirectory -DestinationPath $PasteIntoDirectory -ModeFlag $effectiveModeTokens -MergeMode:$MergeMode
		}
		finally {
			if ($rootKeepFilePath) {
				$markerRemoved = Remove-KeepRootMarkerFast -MarkerPath $rootKeepFilePath
				if (-not $markerRemoved) {
					Write-RunLog ("SelectAll token move guard warning | Marker still exists after retries '{0}'" -f $rootKeepFilePath)
				}
				elseif ($script:RunSettings.DebugMode) {
					Write-RunLog ("DEBUG | SelectAll token move guard cleanup | Marker removed '{0}'" -f $rootKeepFilePath)
				}
			}
		}
		if ($IsMove -and $tokenResult -and $tokenResult.Succeeded) {
			[void](Resolve-TokenMoveRootLeftovers -SourceDirectory $sourceDirectory -DestinationDirectory $PasteIntoDirectory)
		}
		if ($tokenResult) {
			$results += $tokenResult
		}
		if ($ActionLabel) {
			Write-Output ("Finished {0} all items from '{1}'" -f $ActionLabel, $sourceDirectory)
		}
		return @($results)
	}

	if ($pathList.Count -gt 1) {
		$tokenCount = @($pathList | Where-Object { Test-IsStageWildcardToken -PathValue $_ }).Count
		if ($tokenCount -gt 0) {
			Write-RunLog ("SelectAll token ignored in mixed payload | TokenCount={0} | PathCount={1}" -f $tokenCount, $pathList.Count)
			$pathList = @($pathList | Where-Object { -not (Test-IsStageWildcardToken -PathValue $_) })
		}
	}

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
$script:LogsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path -LiteralPath $script:LogsDir)) {
	New-Item -ItemType Directory -Path $script:LogsDir -Force | Out-Null
}
$errorLogPath = Join-Path $script:LogsDir "error_log.txt"
$script:RunLogPath = Join-Path $script:LogsDir "run_log.txt"
$script:RobocopyDebugLogPath = Join-Path $script:LogsDir "robocopy_debug.log"
$tuneConfigPath = Join-Path $PSScriptRoot "RoboTune.json"
$script:RoboTuneConfig = Get-TuneConfig -ConfigPath $tuneConfigPath
$script:StageBackend = Get-StageBackend -Config $script:RoboTuneConfig
$script:RunSettings = Get-RunSettings -Config $script:RoboTuneConfig
Write-RunLog "===== START ====="
Write-RunLog ("Config path: {0}" -f $tuneConfigPath)
Write-RunLog ("BenchmarkMode={0} | BenchmarkOutput={1} | HoldWindow={2} | DebugMode={3} | StageBackend={4}" -f $script:RunSettings.BenchmarkMode, $script:RunSettings.BenchmarkOutput, $script:RunSettings.HoldWindow, $script:RunSettings.DebugMode, $script:StageBackend)
if ($script:RunSettings.BenchmarkMode) {
	Write-Host "Benchmark mode is ON (window will stay open at end)." -ForegroundColor Cyan
	Write-Host ("Run log: {0}" -f $script:RunLogPath) -ForegroundColor DarkCyan
}
if ($script:RunSettings.DebugMode) {
	Write-Host ("Debug mode is ON. Robocopy debug log: {0}" -f $script:RobocopyDebugLogPath) -ForegroundColor DarkYellow
	Write-RunLog ("Debug log path: {0}" -f $script:RobocopyDebugLogPath)
}

try {
	# Clear stale copy burst marker once paste flow starts.
	Remove-StageBurstMarker
	$phaseFlowTimer = [System.Diagnostics.Stopwatch]::StartNew()
	$phaseStageResolveMs = 0
	$phasePayloadPrepMs = 0
	$phaseExecuteMs = 0
	$payloadPrepStartMs = $null

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

	$requestedCommand = if ($args.Count -ge 1) { [string]$args[0] } else { "auto" }
	$requestedMode = if ($args.Count -ge 2) { [string]$args[1] } else { "auto" }
	$requestedCommand = if ([string]::IsNullOrWhiteSpace($requestedCommand)) { "auto" } else { $requestedCommand.ToLowerInvariant() }
	$requestedMode = if ([string]::IsNullOrWhiteSpace($requestedMode)) { "auto" } else { $requestedMode.ToLowerInvariant() }

	# copy / move logic setup
	if ($args.Count -lt 3 -or [string]::IsNullOrWhiteSpace([string]$args[2])) {
		throw "Paste target path is missing."
	}
	$pasteIntoDirectory = Normalize-ContextPathValue -PathValue ([string]$args[2])
	if ([string]::IsNullOrWhiteSpace($pasteIntoDirectory)) {
		throw "Paste target path is missing."
	}
	if (-not (Test-Path -LiteralPath $pasteIntoDirectory)) {
		throw "Paste target path does not exist: $pasteIntoDirectory"
	}

	$pasteDirectoryDisplay = "'" + $pasteIntoDirectory + "'"

	$stageResolveStartMs = $phaseFlowTimer.ElapsedMilliseconds
	$resolvedSnapshot = Resolve-StagedPayload -RequestedCommand $requestedCommand -Backend $script:StageBackend
	if ($resolvedSnapshot) {
		$command = $resolvedSnapshot.CommandName
		$resolvedStageFormat = if ($resolvedSnapshot.PSObject.Properties.Name -contains "StageFormat") { [string]$resolvedSnapshot.StageFormat } else { "unknown" }
		Write-RunLog ("Stage resolved | Requested={0} | Backend={1} | Command={2} | StageFormat={3} | Expected={4} | Actual={5} | Session={6}" -f $requestedCommand, $script:StageBackend, $resolvedSnapshot.CommandName, $resolvedStageFormat, $resolvedSnapshot.ExpectedCount, $resolvedSnapshot.ActualCount, $resolvedSnapshot.SessionId)
	}
	else {
		$command = if ($requestedCommand -eq "mv") { "mv" } else { "rc" }
		Write-RunLog ("Stage unresolved | Requested={0} | Backend={1} | FallbackCommand={2}" -f $requestedCommand, $script:StageBackend, $command)
	}
	$mode = if ($requestedMode -in @("m", "s")) { $requestedMode } else { "s" }
	$phaseStageResolveMs = [int]([Math]::Max(0, $phaseFlowTimer.ElapsedMilliseconds - $stageResolveStartMs))
	$payloadPrepStartMs = $phaseFlowTimer.ElapsedMilliseconds

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

	# Read staged files/folders from validated snapshot.
	$array = @()
	$activeSnapshot = $null
	if ($resolvedSnapshot -and $resolvedSnapshot.CommandName -eq $command) {
		$array = @($resolvedSnapshot.Paths)
		$activeSnapshot = $resolvedSnapshot
	}
	else {
		$fallbackSnapshot = Get-StagedSnapshot -CommandName $command -Backend $script:StageBackend
		if ($fallbackSnapshot -and $fallbackSnapshot.IsReady) {
			$array = @($fallbackSnapshot.Paths)
			$activeSnapshot = $fallbackSnapshot
		}
	}
	$arrayLength = @($array).Count
	if ($arrayLength -eq 0) {
		NoListAvailable
	}

	$stageFormat = "unknown"
	$snapshotSession = ""
	if ($activeSnapshot) {
		if ($activeSnapshot.PSObject.Properties.Name -contains "StageFormat") {
			$stageFormat = [string]$activeSnapshot.StageFormat
		}
		if ($activeSnapshot.PSObject.Properties.Name -contains "SessionId") {
			$snapshotSession = [string]$activeSnapshot.SessionId
		}
	}
	$missingAtPasteCount = 0
	$hasWildcardToken = $false
	$blockedMovePaths = New-Object System.Collections.Generic.List[string]
	$effectivePaths = New-Object System.Collections.Generic.List[string]
	foreach ($candidatePath in @($array)) {
		if ([string]::IsNullOrWhiteSpace($candidatePath)) { continue }
		if (Test-IsStageWildcardToken -PathValue $candidatePath) {
			$hasWildcardToken = $true
			$tokenSource = Get-StageWildcardSourceFromToken -TokenPath $candidatePath
			if ($command -eq "mv" -and (Test-IsProtectedMovePath -PathValue $tokenSource)) {
				[void]$blockedMovePaths.Add($tokenSource)
				continue
			}
			if ([string]::IsNullOrWhiteSpace($tokenSource) -or -not [System.IO.Directory]::Exists($tokenSource)) {
				$missingAtPasteCount++
			}
			[void]$effectivePaths.Add($candidatePath)
			continue
		}
		if ($command -eq "mv" -and (Test-IsProtectedMovePath -PathValue $candidatePath)) {
			[void]$blockedMovePaths.Add($candidatePath)
			continue
		}
		if (-not [System.IO.Directory]::Exists($candidatePath) -and -not [System.IO.File]::Exists($candidatePath)) {
			$missingAtPasteCount++
		}
		[void]$effectivePaths.Add($candidatePath)
	}
	if ($blockedMovePaths.Count -gt 0) {
		$blockedUnique = @($blockedMovePaths | Select-Object -Unique)
		$blockedPreview = @($blockedUnique | Select-Object -First 5)
		Write-RunLog ("Safety guard blocked move path(s) | Count={0} | Paths='{1}'" -f $blockedUnique.Count, ([string]::Join(" | ", $blockedPreview)))
		Write-Host ("[BLOCKED] Safety guard skipped {0} protected move item(s)." -f $blockedUnique.Count) -ForegroundColor Red
	}
	$array = @($effectivePaths.ToArray())
	$arrayLength = @($array).Count
	if ($arrayLength -eq 0) {
		if ($command -eq "mv" -and $blockedMovePaths.Count -gt 0) {
			throw "Safety guard blocked move of protected path(s)."
		}
		NoListAvailable
	}
	Write-RunLog ("Stage payload ready | Command={0} | Mode={1} | StageFormat={2} | StagedCount={3} | MissingAtPasteCount={4} | Session={5} | WildcardToken={6}" -f $command, $mode, $stageFormat, $arrayLength, $missingAtPasteCount, $snapshotSession, $hasWildcardToken)

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
								Clear-StagedPayload -CommandName $command -Backend $script:StageBackend
								Remove-StageBurstMarker
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
		if ($null -ne $payloadPrepStartMs) {
			$phasePayloadPrepMs = [int]([Math]::Max(0, $phaseFlowTimer.ElapsedMilliseconds - $payloadPrepStartMs))
		}
		else {
			$phasePayloadPrepMs = 0
		}

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
							Clear-StagedPayload -CommandName $command -Backend $script:StageBackend
							Remove-StageBurstMarker
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
		$phaseExecuteMs = [int]$sessionTimer.ElapsedMilliseconds
		$phasePreExecMs = [int]($phaseStageResolveMs + $phasePayloadPrepMs)
		$phaseTotalMs = [int]($phasePreExecMs + $phaseExecuteMs)
		$totalSeconds = [Math]::Round($sessionTimer.Elapsed.TotalSeconds, 3)
		$completedOps = @($sessionResults | Where-Object {
			$null -ne $_ -and $_.PSObject -and $_.PSObject.Properties.Match("Succeeded").Count -gt 0
		})

		if ($script:RunSettings.BenchmarkOutput -and $sessionResults.Count -gt 0) {
			# Defensive filtering: count only structured transfer result objects.
			$totalBytes = [int64](($completedOps | Measure-Object -Property Bytes -Sum).Sum)
			$totalFiles = [int](($completedOps | Measure-Object -Property Files -Sum).Sum)
			$failedOps = @($completedOps | Where-Object { -not $_.Succeeded }).Count
			$aggregateThroughput = "-"
			if ($sessionTimer.Elapsed.TotalSeconds -gt 0 -and $totalBytes -gt 0) {
				$aggregateThroughput = ("{0:N2} MB/s" -f (($totalBytes / 1MB) / $sessionTimer.Elapsed.TotalSeconds))
			}

			Write-Host ""
			Write-Host "=== Session Benchmark ===" -ForegroundColor Cyan
			Write-Host ("Operations: {0} | Failed: {1}" -f $completedOps.Count, $failedOps) -ForegroundColor Cyan
			Write-Host ("Total files: {0} | Total data: {1}" -f $totalFiles, (Format-ByteSize -Bytes $totalBytes)) -ForegroundColor Cyan
			Write-Host ("Total time: {0}s | Avg throughput~{1}" -f $totalSeconds, $aggregateThroughput) -ForegroundColor Cyan
			Write-Host ("Phase timing: Resolve={0}ms | Prep={1}ms | Execute={2}ms | Total~{3}ms" -f $phaseStageResolveMs, $phasePayloadPrepMs, $phaseExecuteMs, $phaseTotalMs) -ForegroundColor DarkCyan
			Write-RunLog ("Session benchmark | Ops={0} | Failed={1} | Files={2} | Bytes={3} | Time={4}s | Throughput={5}" -f $completedOps.Count, $failedOps, $totalFiles, $totalBytes, $totalSeconds, $aggregateThroughput)
		}
		else {
			Write-Host ("Elapsed: {0}s | Operations: {1}" -f $totalSeconds, $completedOps.Count) -ForegroundColor Cyan
			Write-Host ("Phase timing: Resolve={0}ms | Prep={1}ms | Execute={2}ms | Total~{3}ms" -f $phaseStageResolveMs, $phasePayloadPrepMs, $phaseExecuteMs, $phaseTotalMs) -ForegroundColor DarkCyan
			Write-RunLog ("Session timing | Ops={0} | Time={1}s | PhaseResolve={2}ms | PhasePrep={3}ms | PhaseExecute={4}ms | PhaseTotal={5}ms" -f $completedOps.Count, $totalSeconds, $phaseStageResolveMs, $phasePayloadPrepMs, $phaseExecuteMs, $phaseTotalMs)
		}

		Clear-StagedPayload -CommandName $command -Backend $script:StageBackend
		Remove-StageBurstMarker
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
	Remove-StageBurstMarker
    
	# Display error to user
	Write-Host "`n[ERROR] Something went wrong!" -ForegroundColor Red
	Write-Host $_.Exception.Message -ForegroundColor Red
	Write-Host "`nError has been logged to: $errorLogPath" -ForegroundColor Yellow
	Write-Host "Run log: $script:RunLogPath" -ForegroundColor Yellow
	Write-Host "Press any key to exit..." -ForegroundColor Yellow
	[Console]::ReadKey($true) | Out-Null
}
