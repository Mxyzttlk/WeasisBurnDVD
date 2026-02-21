@echo off
echo === Test lansare Weasis de pe disc ===
echo.
cd /d "F:\"
echo Dir: %CD%

REM Clean cache
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do (
    echo Sterg cache: %%D
    rmdir /s /q "%%D" 2>nul
)

echo.
echo Lansez Weasis cu java.exe (consola vizibila)...
echo.
"F:\jre\windows\bin\java.exe" -Xms64m -Xmx768m -Dweasis.portable.dir="F:\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "F:\weasis-launcher.jar;F:\felix.jar;F:\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
echo Exit code: %ERRORLEVEL%
pause
