@echo off
cd /d "%~dp0"

if not exist "jre\windows\bin\javaw.exe" (
    echo Java nu a fost gasit pe disc.
    pause
    exit /b 1
)

REM Clean old Weasis cache to avoid slow startup from corrupted bundles
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

REM Launch Weasis using full paths (required for optical media)
start "Weasis" "%~dp0jre\windows\bin\javaw.exe" -Xms64m -Xmx1280m -Dweasis.portable.dir="%~dp0." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%~dp0weasis-launcher.jar;%~dp0felix.jar;%~dp0substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
