#Requires AutoHotkey v2.0
#SingleInstance Force

; Deterministic hotkeys for Robo-Copy / Robo-Paste benchmarking.
; Uses the same wrappers as context-menu entries, but avoids manual menu latency.

COPY_WRAPPER := "D:\Users\joty79\scripts\Robocopy\RoboCopy_Silent.vbs"
PASTE_WRAPPER := "D:\Users\joty79\scripts\Robocopy\RoboPaste_Admin.vbs"

; F1 -> stage COPY from active Explorer selection (anchor item)
F1:: {
    anchorPath := GetSelectionAnchorPath()
    if (anchorPath = "") {
        FlashTip("Robo-Copy: no selection in active Explorer window.")
        return
    }

    cmd := Format('wscript.exe "{1}" "{2}"', COPY_WRAPPER, anchorPath)
    Run cmd, , "Hide"
    FlashTip("Robo-Copy staged.")
}

; F2 -> paste into active Explorer folder (admin WT window)
F2:: {
    targetPath := GetActiveExplorerFolderPath()
    if (targetPath = "") {
        FlashTip("Robo-Paste: no active Explorer folder.")
        return
    }

    cmd := Format('wscript.exe "{1}" "{2}"', PASTE_WRAPPER, targetPath)
    Run cmd, , "Hide"
    FlashTip("Robo-Paste launched.")
}

; Ctrl+Alt+B -> one-shot benchmark trigger (copy then paste)
^!b:: {
    anchorPath := GetSelectionAnchorPath()
    targetPath := GetActiveExplorerFolderPath()
    if (anchorPath = "" || targetPath = "") {
        FlashTip("Benchmark: need active Explorer + selection.")
        return
    }

    Run Format('wscript.exe "{1}" "{2}"', COPY_WRAPPER, anchorPath), , "Hide"
    Sleep 180
    Run Format('wscript.exe "{1}" "{2}"', PASTE_WRAPPER, targetPath), , "Hide"
    FlashTip("Benchmark trigger: copy->paste.")
}

GetActiveExplorerWindow() {
    activeHwnd := WinActive("A")
    if (!activeHwnd) {
        return 0
    }

    shell := ComObject("Shell.Application")
    for win in shell.Windows {
        try {
            if (win.HWND = activeHwnd) {
                return win
            }
        }
    }
    return 0
}

GetSelectionAnchorPath() {
    win := GetActiveExplorerWindow()
    if (!win) {
        return ""
    }

    try {
        sel := win.Document.SelectedItems
        if (sel.Count < 1) {
            return ""
        }
        return sel.Item(0).Path
    } catch {
        return ""
    }
}

GetActiveExplorerFolderPath() {
    win := GetActiveExplorerWindow()
    if (!win) {
        return ""
    }

    try {
        return win.Document.Folder.Self.Path
    } catch {
        return ""
    }
}

FlashTip(text) {
    ToolTip text
    SetTimer () => ToolTip(), -900
}
