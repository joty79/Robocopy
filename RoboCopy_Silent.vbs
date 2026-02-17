' Silent wrapper for rcopySingle.ps1 (Robo-Copy / Robo-Cut)
' Location: D:\Users\joty79\scripts\Robocopy
' Runs hidden, no profile.
' Uses a lightweight lock file to avoid clone storms on Explorer multi-select bursts.

Option Explicit

Const SCRIPT_ROOT = "C:\Users\joty79\AppData\Local\RoboCopyContext"
Const STALE_LOCK_SECONDS = 20
Const BURST_SUPPRESS_SECONDS = 2
Const LOCK_RETRY_COUNT = 40
Const LOCK_RETRY_DELAY_MS = 75
Const MULTI_STAGE_EXIT_CODE = 10

Dim STATE_DIR, LOCK_FILE
STATE_DIR = SCRIPT_ROOT & "\state"
LOCK_FILE = STATE_DIR & "\stage.lock"
Dim BURST_FILE
BURST_FILE = STATE_DIR & "\stage.burst"

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

Sub CleanupStaleBurst()
    On Error Resume Next
    If fso.FileExists(BURST_FILE) Then
        Dim burstObj, burstAgeSec
        Set burstObj = fso.GetFile(BURST_FILE)
        If Err.Number = 0 Then
            burstAgeSec = DateDiff("s", burstObj.DateLastModified, Now)
            If burstAgeSec > BURST_SUPPRESS_SECONDS Then
                burstObj.Delete True
            End If
        End If
        Err.Clear
    End If
    On Error GoTo 0
End Sub

Function GetAnchorParentLower(ByVal pathValue)
    On Error Resume Next
    Dim parent
    parent = ""

    If Len(pathValue) > 0 Then
        parent = fso.GetParentFolderName(pathValue)
        If Len(parent) = 0 Then
            parent = pathValue
        End If
    End If

    GetAnchorParentLower = LCase(parent)
    On Error GoTo 0
End Function

Function IsSuppressedBurst(ByVal modeValue, ByVal parentValue)
    On Error Resume Next
    IsSuppressedBurst = False

    If Len(parentValue) = 0 Then Exit Function
    If Not fso.FileExists(BURST_FILE) Then Exit Function

    Dim burstObj, ageSec
    Set burstObj = fso.GetFile(BURST_FILE)
    If Err.Number <> 0 Then
        Err.Clear
        Exit Function
    End If

    ageSec = DateDiff("s", burstObj.DateLastModified, Now)
    If ageSec < 0 Or ageSec > BURST_SUPPRESS_SECONDS Then
        Exit Function
    End If

    Dim ts, payload, sepPos, lastMode, lastParent
    Set ts = fso.OpenTextFile(BURST_FILE, 1, False, 0)
    If Err.Number <> 0 Then
        Err.Clear
        Exit Function
    End If
    payload = ts.ReadAll
    ts.Close

    sepPos = InStr(1, payload, "|", vbTextCompare)
    If sepPos <= 0 Then Exit Function

    lastMode = LCase(Trim(Left(payload, sepPos - 1)))
    lastParent = LCase(Trim(Mid(payload, sepPos + 1)))

    If (lastMode = LCase(modeValue)) And (lastParent = parentValue) Then
        If StageReadyForParent(modeValue, parentValue) Then
            IsSuppressedBurst = True
        Else
            On Error Resume Next
            If fso.FileExists(BURST_FILE) Then
                fso.DeleteFile BURST_FILE, True
            End If
            On Error GoTo 0
        End If
    End If

    On Error GoTo 0
End Function

Function StageReadyForParent(ByVal modeValue, ByVal parentValue)
    On Error Resume Next
    StageReadyForParent = False

    Dim baseKey, readyValue, expectedValue, stageParent
    baseKey = "HKCU\RCWM\" & modeValue & "\"

    readyValue = CLng(objShell.RegRead(baseKey & "__ready"))
    If Err.Number <> 0 Then
        Err.Clear
        Exit Function
    End If
    If readyValue <> 1 Then Exit Function

    expectedValue = 0
    expectedValue = CLng(objShell.RegRead(baseKey & "__expected_count"))
    If Err.Number <> 0 Then
        expectedValue = 0
        Err.Clear
    End If
    If expectedValue <= 1 Then Exit Function

    stageParent = ""
    stageParent = LCase(CStr(objShell.RegRead(baseKey & "__anchor_parent")))
    If Err.Number <> 0 Then
        Err.Clear
        StageReadyForParent = True
        Exit Function
    End If

    If Len(stageParent) = 0 Then
        StageReadyForParent = True
    ElseIf stageParent = LCase(parentValue) Then
        StageReadyForParent = True
    End If

    On Error GoTo 0
End Function

Sub WriteBurstMarker(ByVal modeValue, ByVal parentValue)
    On Error Resume Next
    Dim ts
    Set ts = fso.CreateTextFile(BURST_FILE, True, True)
    If Err.Number = 0 Then
        ts.Write modeValue & "|" & parentValue
        ts.Close
    Else
        Err.Clear
    End If
    On Error GoTo 0
End Sub

Function TryAcquireLock()
    On Error Resume Next
    Dim attempt, ts
    TryAcquireLock = False

    For attempt = 1 To LOCK_RETRY_COUNT
        Set ts = fso.CreateTextFile(LOCK_FILE, False, True)
        If Err.Number = 0 Then
            ts.WriteLine CStr(Now)
            ts.Close
            TryAcquireLock = True
            Exit For
        End If

        Err.Clear
        CleanupStaleLock
        WScript.Sleep LOCK_RETRY_DELAY_MS
    Next

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
Dim anchorParent, exitCode
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
CleanupStaleBurst

anchorParent = GetAnchorParentLower(anchorPath)
If IsSuppressedBurst(mode, anchorParent) Then
    WScript.Quit 0
End If

If Not TryAcquireLock() Then
    ' Another invoke in the same selection burst is already handling staging.
    WScript.Quit 0
End If

' Re-check after lock acquire: queued duplicate invokes may have passed pre-lock check.
If IsSuppressedBurst(mode, anchorParent) Then
    ReleaseLock
    WScript.Quit 0
End If

safeAnchor = Replace(anchorPath, """", """""")
command = "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
          """" & SCRIPT_ROOT & "\rcopySingle.ps1"" " & mode & " """ & safeAnchor & """"

On Error Resume Next
exitCode = objShell.Run(command, 0, True)
If Err.Number = 0 Then
    If exitCode = MULTI_STAGE_EXIT_CODE Then
        WriteBurstMarker mode, anchorParent
    End If
Else
    Err.Clear
End If
ReleaseLock
On Error GoTo 0

