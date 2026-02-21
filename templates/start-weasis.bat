@echo off
cd /d "%~dp0"

REM ============================================================================
REM  Weasis DICOM Viewer - Auto-launch with architecture detection
REM  Default: copies Weasis to local HDD for fast launch
REM  Fallback: launches directly from DVD if copy fails
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
    goto :START
)

if exist "%~dp0jre\windows\bin\javaw.exe" (
    set "JRE_DIR=jre\windows"
    set "JAVA_MEM=-Xms64m -Xmx768m"
    set "ARCH_LABEL=32-bit"
    goto :START
)

echo.
echo   Java nu a fost gasit pe disc.
echo   Contactati departamentul IT.
pause
exit /b 1

:START
set "TEMP_DIR=%TEMP%\weasis-dvd"
set "DISC=%~dp0"
set "NEED_MB=500"

echo.
echo   ===============================================
echo     Weasis DICOM Viewer
echo   ===============================================
echo.
echo     JRE: %ARCH_LABEL%
echo.
echo   Se pregateste lansarea rapida...
echo.

REM ============================================================================
REM  STEP 1: Check free disk space on TEMP drive
REM ============================================================================
set "FREE_MB="
for /f %%A in ('powershell -nologo -noprofile -command "[math]::Floor((Get-PSDrive '%TEMP:~0,1%').Free / 1MB)" 2^>nul') do set "FREE_MB=%%A"

if not defined FREE_MB (
    echo   [!] Nu s-a putut verifica spatiul liber.
    echo       Se continua oricum...
    goto :STEP2
)

if %FREE_MB% LSS %NEED_MB% (
    echo   [X] Spatiu insuficient pe %TEMP:~0,2%\
    echo       Necesar: %NEED_MB% MB / Disponibil: %FREE_MB% MB
    goto :DVD_FALLBACK
)
echo   [OK] Spatiu disponibil: %FREE_MB% MB

REM ============================================================================
REM  STEP 2: Clean old temp folder
REM ============================================================================
:STEP2
if exist "%TEMP_DIR%" (
    echo   [..] Se sterge copia veche...
    REM Remove junction first to avoid touching DVD data
    if exist "%TEMP_DIR%\DICOM" rmdir "%TEMP_DIR%\DICOM" 2>nul
    rmdir /s /q "%TEMP_DIR%" 2>nul
)

REM Check if old folder is still there (locked by running Weasis?)
if exist "%TEMP_DIR%" (
    echo   [X] Folderul temporar este blocat (alt Weasis ruleaza?)
    echo       Inchideti Weasis si incercati din nou, sau asteptati...
    goto :DVD_FALLBACK
)

REM ============================================================================
REM  STEP 3: Create temp folder
REM ============================================================================
mkdir "%TEMP_DIR%" 2>nul
if not exist "%TEMP_DIR%" (
    echo   [X] Nu s-a putut crea folderul temporar.
    goto :DVD_FALLBACK
)

REM ============================================================================
REM  STEP 4: Copy files from DVD to local HDD (sequential read = fast)
REM ============================================================================
echo   [..] Se copiaza de pe disc (~1-2 minute)...
echo.

echo         [1/6] Fisiere JAR...
copy /Y "%DISC%weasis-launcher.jar" "%TEMP_DIR%\" >nul 2>nul
copy /Y "%DISC%felix.jar" "%TEMP_DIR%\" >nul 2>nul
copy /Y "%DISC%substance.jar" "%TEMP_DIR%\" >nul 2>nul

echo         [2/6] Bundle OSGI...
xcopy /E /I /Q /Y "%DISC%bundle" "%TEMP_DIR%\bundle" >nul 2>nul
xcopy /E /I /Q /Y "%DISC%bundle-i18n" "%TEMP_DIR%\bundle-i18n" >nul 2>nul

echo         [3/6] Configuratie...
xcopy /E /I /Q /Y "%DISC%conf" "%TEMP_DIR%\conf" >nul 2>nul

echo         [4/6] Resurse...
if exist "%DISC%resources" xcopy /E /I /Q /Y "%DISC%resources" "%TEMP_DIR%\resources" >nul 2>nul

echo         [5/6] JRE %ARCH_LABEL%...
xcopy /E /I /Q /Y "%DISC%%JRE_DIR%" "%TEMP_DIR%\%JRE_DIR%" >nul 2>nul

echo         [6/6] DICOM...
if exist "%DISC%DICOM" (
    mklink /J "%TEMP_DIR%\DICOM" "%DISC%DICOM" >nul 2>nul
    if not exist "%TEMP_DIR%\DICOM" (
        echo               Junction nu a reusit, se copiaza DICOM...
        xcopy /E /I /Q /Y "%DISC%DICOM" "%TEMP_DIR%\DICOM" >nul 2>nul
    )
)

REM ============================================================================
REM  STEP 5: Verify essential files exist
REM ============================================================================
echo.
echo   [..] Verificare fisiere...

set "COPY_OK=1"
if not exist "%TEMP_DIR%\weasis-launcher.jar" set "COPY_OK=0"
if not exist "%TEMP_DIR%\felix.jar" set "COPY_OK=0"
if not exist "%TEMP_DIR%\substance.jar" set "COPY_OK=0"
if not exist "%TEMP_DIR%\%JRE_DIR%\bin\javaw.exe" set "COPY_OK=0"
if not exist "%TEMP_DIR%\conf\config.properties" set "COPY_OK=0"

if "%COPY_OK%"=="0" (
    echo   [X] Copierea a esuat! Fisiere lipsa.
    echo       Se curata folderul temporar...
    if exist "%TEMP_DIR%\DICOM" rmdir "%TEMP_DIR%\DICOM" 2>nul
    rmdir /s /q "%TEMP_DIR%" 2>nul
    goto :DVD_FALLBACK
)

REM ============================================================================
REM  STEP 6: Launch Weasis from local copy (FAST)
REM ============================================================================
echo   [OK] Toate fisierele copiate cu succes!
echo.
echo   Se lanseaza Weasis...
echo.

REM Clean old Weasis OSGI cache
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

start "Weasis" "%TEMP_DIR%\%JRE_DIR%\bin\javaw.exe" %JAVA_MEM% -Dweasis.portable.dir="%TEMP_DIR%\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%TEMP_DIR%\weasis-launcher.jar;%TEMP_DIR%\felix.jar;%TEMP_DIR%\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable

REM Wait and verify javaw.exe actually started (antivirus may block execution from TEMP)
timeout /t 3 /nobreak >nul
tasklist /fi "imagename eq javaw.exe" 2>nul | find /i "javaw.exe" >nul 2>nul
if errorlevel 1 (
    echo   [X] Weasis nu a pornit! (posibil blocat de antivirus)
    echo       Antivirusul poate bloca executia din %TEMP%
    goto :DVD_FALLBACK
)

echo   [OK] Weasis pornit cu succes!
timeout /t 2 /nobreak >nul
exit /b 0

REM ============================================================================
REM  FALLBACK: Direct launch from DVD (slow but always works)
REM ============================================================================
:DVD_FALLBACK
echo.
echo   -----------------------------------------------
echo     Se trece la lansare directa de pe disc.
echo     Poate dura 3-5 minute, va rugam asteptati...
echo   -----------------------------------------------
echo.

REM Clean old Weasis OSGI cache
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

start "Weasis" "%~dp0%JRE_DIR%\bin\javaw.exe" %JAVA_MEM% -Dweasis.portable.dir="%~dp0." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%~dp0weasis-launcher.jar;%~dp0felix.jar;%~dp0substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable

timeout /t 5 /nobreak >nul
exit /b 0
