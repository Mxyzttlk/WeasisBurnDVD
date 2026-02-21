@echo off
cd /d "%~dp0"

REM ============================================================================
REM  Weasis DICOM Viewer - Auto-launch with architecture detection
REM  Detects 64-bit vs 32-bit Windows and selects appropriate JRE
REM ============================================================================

REM Detect system architecture
set "ARCH=x86"
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "ARCH=x64"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=x64"

REM Select JRE: prefer x64 on 64-bit systems, fallback to x86
if "%ARCH%"=="x64" if exist "%~dp0jre\windows-x64\bin\javaw.exe" goto :USE_X64

REM Fallback to x86
if exist "%~dp0jre\windows\bin\javaw.exe" goto :USE_X86

echo.
echo   Java nu a fost gasit pe disc.
echo   Contactati departamentul IT.
pause
exit /b 1

:USE_X64
set "JAVA_EXE=%~dp0jre\windows-x64\bin\javaw.exe"
set "JAVA_MEM=-Xms64m -Xmx2048m"
set "ARCH_LABEL=64-bit"
goto :LAUNCH

:USE_X86
set "JAVA_EXE=%~dp0jre\windows\bin\javaw.exe"
set "JAVA_MEM=-Xms64m -Xmx768m"
set "ARCH_LABEL=32-bit"
goto :LAUNCH

:LAUNCH
echo.
echo   ===============================================
echo     Weasis DICOM Viewer
echo   ===============================================
echo.
echo     Se incarca, va rugam asteptati...
echo     Poate dura 1-3 minute de pe disc.
echo.
echo     JRE: %ARCH_LABEL%
echo.

REM Clean old Weasis cache to avoid slow startup from corrupted bundles
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

REM Launch Weasis using full paths (required for optical media)
start "Weasis" "%JAVA_EXE%" %JAVA_MEM% -Dweasis.portable.dir="%~dp0." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%~dp0weasis-launcher.jar;%~dp0felix.jar;%~dp0substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable

REM Keep window open so user sees the loading message
timeout /t 5 /nobreak >nul
