@echo off
echo Opresc toate procesele Java...
taskkill /f /im javaw.exe 2>nul
taskkill /f /im java.exe 2>nul
timeout /t 3 /nobreak >nul

echo Curatare cache Weasis...
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

REM Detect disc drive letter (check common optical drive letters)
set "DISC_DRIVE="
for %%L in (D E F G H I) do (
    if exist "%%L:\start-weasis.bat" (
        set "DISC_DRIVE=%%L:"
        goto :FOUND
    )
)

echo.
echo   Nu am gasit start-weasis.bat pe nicio unitate optica.
echo   Specifica litera discului manual:
set /p DISC_DRIVE="   Litera (ex: F:): "
if not exist "%DISC_DRIVE%\start-weasis.bat" (
    echo   [EROARE] start-weasis.bat nu exista pe %DISC_DRIVE%
    pause
    exit /b 1
)

:FOUND
echo Lansez start-weasis.bat de pe %DISC_DRIVE%\...
call "%DISC_DRIVE%\start-weasis.bat"
