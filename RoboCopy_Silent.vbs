' Silent wrapper for rcopySingle.ps1 (Robo-Copy / Robo-Cut)
' Location: D:\Users\joty79\scripts\Robocopy
' Runs hidden, no profile.
' Uses a lightweight lock file to avoid clone storms on Explorer multi-select bursts.

Option Explicit

Const SCRIPT_ROOT = "D:\Users\joty79\scripts\Robocopy"
Const STALE_LOCK_SECONDS = 120

Dim STATE_DIR, LOCK_FILE
STATE_DIR = SCRIPT_ROOT & "\state"
LOCK_FILE = STATE_DIR & "\stage.lock"

Dim objShell
Set objShell = CreateObject("WScript.Shell")

Dim fso
Set fso = CreateObject("Scripting.FileSystemObject")

Sub EnsureStateDir()
    On Error Resume Next
    If Not fso.FolderExists(STATE_DIR) Then
        fso.CreateFolder STATE_DIR
    End If
    On Error GoTo 0
End Sub

Sub CleanupStaleLock()
    On Error Resume Next
    If fso.FileExists(LOCK_FILE) Then
        Dim lockObj, ageSec
        Set lockObj = fso.GetFile(LOCK_FILE)
        If Err.Number = 0 Then
            ageSec = DateDiff("s", lockObj.DateLastModified, Now)
            If ageSec > STALE_LOCK_SECONDS Then
                lockObj.Delete True
            End If
        End If
        Err.Clear
    End If
    On Error GoTo 0
End Sub

Function TryAcquireLock()
    On Error Resume Next
    Dim ts
    Set ts = fso.CreateTextFile(LOCK_FILE, False, True)
    If Err.Number = 0 Then
        ts.WriteLine CStr(Now)
        ts.Close
        TryAcquireLock = True
    Else
        TryAcquireLock = False
        Err.Clear
    End If
    On Error GoTo 0
End Function

Sub ReleaseLock()
    On Error Resume Next
    If fso.FileExists(LOCK_FILE) Then
        fso.DeleteFile LOCK_FILE, True
    End If
    On Error GoTo 0
End Sub

If WScript.Arguments.Count = 0 Then
    WScript.Quit 0
End If

Dim mode, anchorPath, command, safeAnchor
mode = "rc"

If LCase(WScript.Arguments(0)) = "mv" Then
    mode = "mv"
    If WScript.Arguments.Count < 2 Then
        WScript.Quit 0
    End If
    anchorPath = WScript.Arguments(1)
Else
    anchorPath = WScript.Arguments(0)
End If

If Len(anchorPath) = 0 Then
    WScript.Quit 0
End If

EnsureStateDir
CleanupStaleLock
If Not TryAcquireLock() Then
    ' Another invoke in the same selection burst is already handling staging.
    WScript.Quit 0
End If

safeAnchor = Replace(anchorPath, """", """""")
command = "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
          """" & SCRIPT_ROOT & "\rcopySingle.ps1"" " & mode & " """ & safeAnchor & """"

On Error Resume Next
objShell.Run command, 0, True
ReleaseLock
On Error GoTo 0
