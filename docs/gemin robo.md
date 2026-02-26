The reason your menu items are "rolling the dice" and scattering is due to how Windows prioritizes different Registry keys.

### The Problem

You currently have:

1. **Cut/Copy** in `AllFilesystemObjects` (This key loads **first** and sits high in the menu).
2. **Paste** in `Directory` (This key loads **later** and sits lower in the menu).

Because they reside in different "parent" branches of the registry, Windows renders them in two separate blocks. No amount of alphabetical naming (`Y_10`, `Y_11`) will force items from `Directory` to merge into the block of items from `AllFilesystemObjects`.

### The Solution

To group them perfectly with separators wrapping the whole group, they must exist in the **same registry branch**.

Since "Paste" only applies to Folders (you can't paste *into* a file), we cannot put everything in `AllFilesystemObjects`. Instead, we must split the logic:

1. **For Files:** Put Cut/Copy in `HKCU\Software\Classes\*\shell`.
2. **For Folders:** Put Cut/Copy/Paste all together in `HKCU\Software\Classes\Directory\shell`.

This guarantees that when you right-click a folder, all three items are "peers" and will sort correctly (10, 11, 12).

Here is the fixed Registry Script:

```registry
Windows Registry Editor Version 5.00

; -------- CLEANUP OLD KEYS --------
; Removes the old AllFilesystemObjects keys that were causing the split
[-HKEY_CURRENT_USER\Software\Classes\AllFilesystemObjects\shell\Y_10_RoboCut]
[-HKEY_CURRENT_USER\Software\Classes\AllFilesystemObjects\shell\Y_11_RoboCopy]
[-HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_12_RoboPaste]
[-HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\Y_12_RoboPaste]

; ============================================================================
; GROUP 1: FILES ONLY (Context: *)
; Contains: Cut, Copy
; Separator logic: Before Cut, After Copy (since Paste doesn't exist for files)
; ============================================================================

[HKEY_CURRENT_USER\Software\Classes\*\shell\Y_10_RoboCut]
"MUIVerb"="Robo-Cut"
"Icon"="d:\\Users\\joty79\\Documents\\Icons\\Cut.ico"
"SeparatorBefore"=""

[HKEY_CURRENT_USER\Software\Classes\*\shell\Y_10_RoboCut\command]
@="wscript.exe \"D:\\Users\\joty79\\scripts\\Robocopy\\RoboCopy_Silent.vbs\" mv \"%1\""

[HKEY_CURRENT_USER\Software\Classes\*\shell\Y_11_RoboCopy]
"MUIVerb"="Robo-Copy"
"Icon"="d:\\Users\\joty79\\Documents\\Icons\\Copy.ico"
"SeparatorAfter"=""

[HKEY_CURRENT_USER\Software\Classes\*\shell\Y_11_RoboCopy\command]
@="wscript.exe \"D:\\Users\\joty79\\scripts\\Robocopy\\RoboCopy_Silent.vbs\" \"%1\""

; ============================================================================
; GROUP 2: FOLDERS (Context: Directory)
; Contains: Cut, Copy, Paste
; Separator logic: Before Cut, After Paste.
; This puts them all in the same "bucket" so they stay attached.
; ============================================================================

; --- 1. Cut (Folder) ---
[HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_10_RoboCut]
"MUIVerb"="Robo-Cut"
"Icon"="d:\\Users\\joty79\\Documents\\Icons\\Cut.ico"
"SeparatorBefore"=""

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_10_RoboCut\command]
@="wscript.exe \"D:\\Users\\joty79\\scripts\\Robocopy\\RoboCopy_Silent.vbs\" mv \"%1\""

; --- 2. Copy (Folder) ---
[HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_11_RoboCopy]
"MUIVerb"="Robo-Copy"
"Icon"="d:\\Users\\joty79\\Documents\\Icons\\Copy.ico"

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_11_RoboCopy\command]
@="wscript.exe \"D:\\Users\\joty79\\scripts\\Robocopy\\RoboCopy_Silent.vbs\" \"%1\""

; --- 3. Paste (Folder) ---
[HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_12_RoboPaste]
"MUIVerb"="Robo-Paste"
"Icon"="d:\\Users\\joty79\\Documents\\Icons\\Paste.ico"
"HasLUAShield"=""
"SeparatorAfter"=""

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\Y_12_RoboPaste\command]
@="wscript.exe \"D:\\Users\\joty79\\scripts\\Robocopy\\RoboPaste_Admin.vbs\" \"%V\""

; ============================================================================
; GROUP 3: BACKGROUND (Context: Directory\Background)
; Contains: Paste Only (Usually you don't cut/copy the background itself)
; ============================================================================

[HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\Y_12_RoboPaste]
"MUIVerb"="Robo-Paste"
"Icon"="d:\\Users\\joty79\\Documents\\Icons\\Paste.ico"
"HasLUAShield"=""
"SeparatorBefore"=""
"SeparatorAfter"=""

[HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\Y_12_RoboPaste\command]
@="wscript.exe \"D:\\Users\\joty79\\scripts\\Robocopy\\RoboPaste_Admin.vbs\" \"%V\""
```

### Key Changes Made:

1. **Removed `AllFilesystemObjects`:** I stopped using this key entirely. It creates items that float to the top, separating them from the `Directory` (Paste) items.
2. **Duplicated Cut/Copy:**
   * I added Cut/Copy to `*\shell` (so they appear when you right-click **files**).
   * I added Cut/Copy to `Directory\shell` (so they appear when you right-click **folders**).
3. **Unified Sorting:** Now that Cut, Copy, and Paste are ALL inside `Directory\shell` when you click a folder, the keys `Y_10`, `Y_11`, and `Y_12` will actually work to keep them strictly adjacent.
4. **Separator Fix:**
   * On Files: Separator is Before Cut and After Copy.
   * On Folders: Separator is Before Cut and After Paste.
