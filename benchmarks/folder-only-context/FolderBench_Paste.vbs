' FolderBench_Paste.vbs
' Opens visible PowerShell for temp folder-only paste benchmark.

Option Explicit

Dim fso, wsh, scriptRoot, pasteScript, targetPath, args, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set wsh = CreateObject("WScript.Shell")

scriptRoot = fso.GetParentFolderName(WScript.ScriptFullName)
pasteScript = scriptRoot & "\FolderBench_Paste.ps1"

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

targetPath = WScript.Arguments(0)
If Len(targetPath) = 0 Then
    WScript.Quit 1
End If

args = "-NoProfile -ExecutionPolicy Bypass -NoExit -File """ & pasteScript & """ """ & targetPath & """"
cmd = "pwsh.exe " & args
wsh.Run cmd, 1, False
WScript.Quit 0

