' Silent wrapper for rcopySingle.ps1 (Robo-Copy / Robo-Cut)
' Location: D:\Users\joty79\scripts\Robocopy
' This runs the PowerShell 7 script without showing any window

Set objShell = CreateObject("WScript.Shell")

' Get the folder path from arguments
If WScript.Arguments.Count > 0 Then
    folderPath = WScript.Arguments(0)
    
    ' Check if this is a Move operation (first arg is "mv")
    If folderPath = "mv" Then
        If WScript.Arguments.Count > 1 Then
            actualPath = WScript.Arguments(1)
            command = "pwsh.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""D:\Users\joty79\scripts\Robocopy\rcopySingle.ps1"" mv """ & actualPath & """"
        End If
    Else
        ' Copy operation
        command = "pwsh.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""D:\Users\joty79\scripts\Robocopy\rcopySingle.ps1"" """ & folderPath & """"
    End If
    
    ' Run silently (0 = hidden, False = don't wait)
    objShell.Run command, 0, False
End If
