
# Determine mode (copy or move) based on first argument
if ($args[0] -eq "mv") {
    $regPath = "HKCU:\RCWM\mv"
    # Reconstruct path from remaining arguments (handling spaces)
    $folderPath = $args[1..($args.Count - 1)] -join " "
}
else {
    $regPath = "HKCU:\RCWM\rc"
    # Reconstruct path from all arguments (handling spaces just in case)
    $folderPath = $args -join " "
}


# Check if key exists, if not create it
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
else {
    # If key exists, clear previous entries
    Remove-ItemProperty -Path $regPath -Name * -ErrorAction SilentlyContinue
}

# Write the new path
New-ItemProperty -Path $regPath -Name "$folderPath" -Force | Out-Null
