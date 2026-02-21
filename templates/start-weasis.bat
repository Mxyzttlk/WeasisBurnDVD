@echo off
cd /d "%~dp0"

REM ============================================================================
REM  Weasis DICOM Viewer - Launch with GUI splash screen
REM  Detects architecture, launches PowerShell WPF splash for copy & load.
REM  Fallback: CMD-based direct DVD launch if PowerShell/WPF fails.
REM ============================================================================

REM Detect system architecture
set "ARCH=x86"
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "ARCH=x64"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=x64"

REM Select JRE path and memory based on architecture
if "%ARCH%"=="x64" if exist "%~dp0jre\windows-x64\bin\javaw.exe" (
    set "JRE_DIR=jre\windows-x64"
    set "JAVA_MEM=-Xms64m -Xmx2048m"
    set "ARCH_LABEL=64-bit"
    goto :LAUNCH_GUI
)

if exist "%~dp0jre\windows\bin\javaw.exe" (
    set "JRE_DIR=jre\windows"
    set "JAVA_MEM=-Xms64m -Xmx768m"
    set "ARCH_LABEL=32-bit"
    goto :LAUNCH_GUI
)

echo.
echo   Java nu a fost gasit pe disc.
echo   Contactati departamentul IT.
pause
exit /b 1

:LAUNCH_GUI
REM Launch PowerShell WPF splash screen (handles copy, progress, launch)
powershell -sta -nologo -noprofile -ExecutionPolicy Bypass -File "%~dp0splash-loader.ps1" -DiscPath "%~dp0" -JreDir "%JRE_DIR%" -JavaMem "%JAVA_MEM%" -ArchLabel "%ARCH_LABEL%" 2>nul

if %ERRORLEVEL% EQU 0 exit /b 0

REM ============================================================================
REM  FALLBACK: Direct launch from DVD (no GUI, CMD only)
REM  Reached only when: PowerShell unavailable, WPF fails, -sta not supported
REM ============================================================================
echo.
echo   -----------------------------------------------
echo     Lansare directa de pe disc (fara GUI).
echo     Poate dura 3-5 minute, va rugam asteptati...
echo   -----------------------------------------------
echo.

REM Clean old Weasis OSGI cache
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

REM Launch Weasis using full paths (required for optical media)
start "Weasis" "%~dp0%JRE_DIR%\bin\javaw.exe" %JAVA_MEM% -Dweasis.portable.dir="%~dp0." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%~dp0weasis-launcher.jar;%~dp0felix.jar;%~dp0substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable

timeout /t 5 /nobreak >nul
exit /b 0
