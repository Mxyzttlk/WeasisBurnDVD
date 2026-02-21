@echo off
echo === Test Weasis with -Dweasis.portable.dir from disc F: ===
echo.
cd /d "F:\"
echo Current directory: %CD%
echo.
echo Checking DICOM folder...
if exist "DICOM" (echo   DICOM/ folder EXISTS) else (echo   DICOM/ folder NOT FOUND!)
if exist "DICOMDIR" (echo   DICOMDIR file EXISTS) else (echo   DICOMDIR file NOT FOUND!)
echo.
echo Launching Weasis with portable.dir set to F:\...
echo.
F:\jre\windows\bin\java.exe -Xms64m -Xmx768m -Dweasis.portable.dir="F:\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "F:\weasis-launcher.jar;F:\felix.jar;F:\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
echo Exit code: %ERRORLEVEL%
pause
