' Copyright (c) 2026 Mxyzttlk. All rights reserved.
Dim _bvt : _bvt = "Q29weXJpZ2h0IDIwMjYgTXh5enR0bGs="
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell -sta -nologo -noprofile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & Replace(WScript.ScriptFullName, "launch.vbs", "pacs-burner.ps1") & """", 0, False
