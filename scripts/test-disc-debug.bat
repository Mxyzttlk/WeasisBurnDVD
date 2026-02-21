@echo off
echo === Debug: launch Weasis from disc F: ===
echo.
cd /d "F:\"
echo Current directory: %CD%
echo.
echo Checking files...
if exist "start-weasis.bat" (echo   start-weasis.bat EXISTS) else (echo   start-weasis.bat NOT FOUND!)
if exist "jre\windows\bin\java.exe" (echo   java.exe EXISTS) else (echo   java.exe NOT FOUND!)
if exist "jre\windows\bin\javaw.exe" (echo   javaw.exe EXISTS) else (echo   javaw.exe NOT FOUND!)
if exist "weasis-launcher.jar" (echo   weasis-launcher.jar EXISTS) else (echo   weasis-launcher.jar NOT FOUND!)
if exist "felix.jar" (echo   felix.jar EXISTS) else (echo   felix.jar NOT FOUND!)
if exist "substance.jar" (echo   substance.jar EXISTS) else (echo   substance.jar NOT FOUND!)
if exist "DICOM" (echo   DICOM/ EXISTS) else (echo   DICOM/ NOT FOUND!)
if exist "DICOMDIR" (echo   DICOMDIR EXISTS - this will cause path errors!) else (echo   DICOMDIR not present - good)
echo.
echo Content of start-weasis.bat on disc:
type "F:\start-weasis.bat"
echo.
echo.
echo Now launching with java.exe (console) to see errors...
echo.
"F:\jre\windows\bin\java.exe" -Xms64m -Xmx768m -Dweasis.portable.dir="F:\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "F:\weasis-launcher.jar;F:\felix.jar;F:\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
echo Exit code: %ERRORLEVEL%
pause
