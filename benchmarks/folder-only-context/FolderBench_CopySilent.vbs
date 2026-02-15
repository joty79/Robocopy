' FolderBench_CopySilent.vbs
' Stages one selected folder for temp benchmark paste flow.

Option Explicit

Dim fso, wsh, scriptRoot, stageScript, sourcePath, args, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set wsh = CreateObject("WScript.Shell")

scriptRoot = fso.GetParentFolderName(WScript.ScriptFullName)
stageScript = scriptRoot & "\FolderBench_CopyStage.ps1"

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

sourcePath = WScript.Arguments(0)
If Len(sourcePath) = 0 Then
    WScript.Quit 1
End If

args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & stageScript & """ """ & sourcePath & """"
cmd = "pwsh.exe " & args
wsh.Run cmd, 0, False
WScript.Quit 0

