# Desktop Selection Diagnostic
# Demonstrates WHY Shell.Application.Windows() cannot see Desktop selection
# and HOW FindWindowSW(SWC_DESKTOP=8) solves it.
#
# Run this, then switch to Desktop and select files during the 7-second countdown.
# Usage: pwsh -NoProfile -File desktop_diag.ps1

[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

Write-Host "`n=== Desktop Selection Diagnostic ===" -ForegroundColor Cyan
Write-Host ""
Write-Host ">>> SWITCH TO DESKTOP NOW and SELECT your files! <<<" -ForegroundColor Red
Write-Host ""
for ($sec = 7; $sec -ge 1; $sec--) {
    Write-Host "`r  Scanning in $sec seconds... " -NoNewline -ForegroundColor Yellow
    Start-Sleep -Seconds 1
}
Write-Host "`r  Scanning NOW!              " -ForegroundColor Green
Write-Host ""

# ==================================================================
# METHOD A: FindWindowSW (SWC_DESKTOP=8)  *** THE WORKING METHOD ***
# ==================================================================
# WHY IT WORKS:
#   The Desktop is hosted by Progman.exe, NOT a regular Explorer window.
#   Shell.Application.Windows() only returns Explorer/IE windows.
#   FindWindowSW with SWC_DESKTOP=8 directly queries the Progman shell view.
#
# COM DETAILS:
#   CLSID 9BA05972-F6A8-11CF-A442-00A0C90A8F39 = ShellWindows class
#   FindWindowSW(pvarloc=0, pvarlocRoot=$null, swClass=8, phwnd=[ref], swfwOptions=1)
#     pvarloc=0     → CSIDL_DESKTOP (Desktop namespace)
#     swClass=8     → SWC_DESKTOP (target the Desktop window specifically)
#     swfwOptions=1 → SWFO_NEEDDISPATCH (return IDispatch object)
# ==================================================================
Write-Host "--- Method A: FindWindowSW SWC_DESKTOP=8 [THE FIX] ---" -ForegroundColor Green
try {
    $sw = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([guid]"9BA05972-F6A8-11CF-A442-00A0C90A8F39"))
    $hwnd = [int]0
    $desktop = $sw.FindWindowSW(0, $null, 8, [ref]$hwnd, 1)
    Write-Host "  SUCCESS! HWND=$hwnd" -ForegroundColor Green
    if ($desktop) {
        $doc = $desktop.Document
        if ($doc) {
            $sel = @($doc.SelectedItems())
            Write-Host "  Selected: $($sel.Count)" -ForegroundColor Green
            foreach ($item in $sel) { Write-Host "    - $($item.Path)" -ForegroundColor Green }
        } else { Write-Host "  Document is null" -ForegroundColor Red }
    } else { Write-Host "  Desktop object is null" -ForegroundColor Red }
}
catch {
    Write-Host "  FAILED: $_" -ForegroundColor Red
}

# ==================================================================
# METHOD B: Shell.Application.Windows()  *** DOES NOT SEE DESKTOP ***
# ==================================================================
# WHY IT FAILS:
#   This method only enumerates regular Explorer windows and IE windows.
#   The Desktop (Progman.exe) is a special shell window that is NOT
#   registered in the ShellWindows collection.
#   Result: Desktop is never in the list → 0 selected items found.
# ==================================================================
Write-Host ""
Write-Host "--- Method B: Shell.Application.Windows() [CANNOT see Desktop] ---" -ForegroundColor Red
$shell = New-Object -ComObject Shell.Application
$windows = @($shell.Windows())
Write-Host "  Total windows: $($windows.Count) (Desktop is NOT here)"
$desktopFound = $false
for ($i = 0; $i -lt $windows.Count; $i++) {
    $w = $windows[$i]
    if (-not $w) { Write-Host "  [$i] null"; continue }
    $name   = ""; try { $name   = $w.LocationName } catch { $name = "<error>" }
    $fPath  = ""; try { $fPath  = $w.Document.Folder.Self.Path } catch { $fPath = "<error>" }
    $selCnt = -1; try { $selCnt = @($w.Document.SelectedItems()).Count } catch { $selCnt = -1 }
    $isDesktop = $fPath -like "*Desktop*" -and $selCnt -gt 0
    if ($isDesktop) { $desktopFound = $true }
    Write-Host "  [$i] Name='$name' | FolderPath='$fPath' | Selected=$selCnt"
}
if (-not $desktopFound) {
    Write-Host "  >>> Desktop shell view is INVISIBLE to this API <<<" -ForegroundColor DarkRed
}

# ==================================================================
# METHOD C: ShellWindows CLSID iteration (same as B, different creation)
# ==================================================================
# WHY IT ALSO FAILS:
#   Creating ShellWindows via its CLSID and iterating with .Item()
#   gives the EXACT same collection as Shell.Application.Windows().
#   Same COM object underneath → same limitation → no Desktop.
# ==================================================================
Write-Host ""
Write-Host "--- Method C: ShellWindows CLSID iteration [Same limitation as B] ---" -ForegroundColor DarkYellow
try {
    $sw2 = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([guid]"9BA05972-F6A8-11CF-A442-00A0C90A8F39"))
    $cnt = $sw2.Count
    Write-Host "  ShellWindows.Count = $cnt (same $($windows.Count) as Method B)"
    for ($i = 0; $i -lt $cnt; $i++) {
        $w = $sw2.Item($i)
        if (-not $w) { Write-Host "  [$i] null"; continue }
        $name   = ""; try { $name   = $w.LocationName } catch { $name = "<err>" }
        $fPath  = ""; try { $fPath  = $w.Document.Folder.Self.Path } catch { $fPath = "<err>" }
        $selCnt = -1; try { $selCnt = @($w.Document.SelectedItems()).Count } catch { $selCnt = -1 }
        Write-Host "  [$i] Name='$name' | FolderPath='$fPath' | Selected=$selCnt"
    }
    Write-Host "  >>> Iterating the collection does NOT reveal Desktop <<<" -ForegroundColor DarkRed
}
catch {
    Write-Host "  FAILED: $_" -ForegroundColor Red
}

# ==================================================================
# SUMMARY
# ==================================================================
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Method A: FindWindowSW(SWC_DESKTOP=8)" -ForegroundColor Green -NoNewline
Write-Host " → WORKS. Direct access to Progman Desktop shell view."
Write-Host "  Method B: Shell.Application.Windows()" -ForegroundColor Red -NoNewline
Write-Host "  → FAILS. Desktop is not in the Windows() collection."
Write-Host "  Method C: ShellWindows CLSID .Item(i)" -ForegroundColor Red -NoNewline
Write-Host "  → FAILS. Same collection as B, just different creation."
Write-Host ""
Write-Host "  The Desktop is hosted by Progman.exe, not Explorer.exe." -ForegroundColor DarkCyan
Write-Host "  FindWindowSW is the ONLY COM method that can reach it." -ForegroundColor DarkCyan
Write-Host ""
Read-Host "Press Enter to exit"
