@echo off
echo === Test Weasis WITHOUT DICOMDIR (scan DICOM/ direct) ===
echo.

REM Copy disc contents to temp for testing (can't modify disc)
set TESTDIR=C:\Users\Fucking_User\AppData\Local\Temp\weasis-test2
if exist "%TESTDIR%" rmdir /s /q "%TESTDIR%"
echo Copying disc contents to temp (without DICOMDIR)...
xcopy F:\ "%TESTDIR%\" /E /I /Q /Y >nul 2>&1
if exist "%TESTDIR%\DICOMDIR" del "%TESTDIR%\DICOMDIR"
echo.
echo DICOMDIR removed from test copy.
if exist "%TESTDIR%\DICOM" (echo DICOM/ folder EXISTS) else (echo DICOM/ folder NOT FOUND!)
echo.

cd /d "%TESTDIR%"
echo Current directory: %CD%
echo.
echo Launching Weasis...
echo.
"%TESTDIR%\jre\windows\bin\java.exe" -Xms64m -Xmx768m -Dweasis.portable.dir="%TESTDIR%\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%TESTDIR%\weasis-launcher.jar;%TESTDIR%\felix.jar;%TESTDIR%\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
echo Exit code: %ERRORLEVEL%
pause
