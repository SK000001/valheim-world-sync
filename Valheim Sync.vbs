' Launches the Valheim Sync GUI with no console window. Double-click this.
Set fso = CreateObject("Scripting.FileSystemObject")
strFolder = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = strFolder
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strFolder & "\ValheimSync-GUI.ps1""", 0, False
