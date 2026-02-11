' Elevated wrapper for rcp.ps1 (Robo-Paste) using Windows Terminal
' Location: D:\Users\joty79\scripts\Robocopy
' This runs in Windows Terminal with admin rights (pwsh 7 default profile)

Set objShell = CreateObject("Shell.Application")

' Get the folder path from arguments
If WScript.Arguments.Count > 0 Then
    folderPath = WScript.Arguments(0)
    
    ' Build the argument string for wt
    ' wt new-tab pwsh -NoProfile -ExecutionPolicy Bypass -File "script.ps1" args
    args = "new-tab pwsh -NoProfile -ExecutionPolicy Bypass -File ""D:\Users\joty79\scripts\Robocopy\rcp.ps1"" auto auto """ & folderPath & """"
    
    ' Run wt.exe as admin (runas)
    ' Parameters: file, arguments, directory, operation, show
    ' show: 1 = normal window
    objShell.ShellExecute "wt.exe", args, "", "runas", 1
End If
