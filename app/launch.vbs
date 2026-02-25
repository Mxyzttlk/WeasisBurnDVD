' Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell -sta -nologo -noprofile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & Replace(WScript.ScriptFullName, "launch.vbs", "pacs-burner.ps1") & """", 0, False
