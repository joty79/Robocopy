' Silent wrapper for rcopySingle.ps1 (Robo-Copy / Robo-Cut)
' Location: D:\Users\joty79\scripts\Robocopy
' Runs hidden, no profile, no wait.

Option Explicit

Dim objShell
Set objShell = CreateObject("WScript.Shell")

If WScript.Arguments.Count > 0 Then
    Dim mode, anchorPath, command
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

    command = "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
              """D:\Users\joty79\scripts\Robocopy\rcopySingle.ps1"" " & mode & " """ & anchorPath & """"

    objShell.Run command, 0, False
End If
