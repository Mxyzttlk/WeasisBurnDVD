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
powershell -sta -nologo -noprofile -ExecutionPolicy Bypass -File "%~dp0splash-loader.ps1" -DiscPath "%~dp0." -JreDir "%JRE_DIR%" -ArchLabel "%ARCH_LABEL%" 2>nul

if %ERRORLEVEL% EQU 0 exit /b 0

REM ============================================================================
REM  FALLBACK: CMD-based copy & launch (mirrors GUI splash logic)
REM  Reached when: PowerShell unavailable, WPF fails, -sta not supported
REM  Flow: copy to HDD -> launch from temp -> fallback to DVD on any error
REM ============================================================================

set "DISC=%~dp0"
set "TEMP_DIR=%TEMP%\weasis-dvd"
set "NEED_MB=500"

REM --- ANSI color codes (Windows 10+) ---
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "C_GREEN=%ESC%[92m"
set "C_RED=%ESC%[91m"
set "C_YELLOW=%ESC%[93m"
set "C_CYAN=%ESC%[96m"
set "C_GRAY=%ESC%[90m"
set "C_WHITE=%ESC%[97m"
set "C_R=%ESC%[0m"

REM --- Detect system language ---
set "LANG=en"
for /f "tokens=3" %%a in ('reg query "HKCU\Control Panel\International" /v LocaleName 2^>nul ^| findstr /i LocaleName') do set "LOCALE_FULL=%%a"
if defined LOCALE_FULL (
    set "LANG_CODE=%LOCALE_FULL:~0,2%"
    if /i "%LOCALE_FULL:~0,2%"=="ro" set "LANG=ro"
    if /i "%LOCALE_FULL:~0,2%"=="ru" set "LANG=ru"
)

REM --- Set localized strings ---
call :SET_STRINGS_%LANG%
goto :CMD_START

:SET_STRINGS_ro
set "S_WAIT=Va rugam asteptati cateva minute..."
set "S_SPACE_CHECK=Verificare spatiu disc..."
set "S_SPACE_OK=Spatiu disponibil:"
set "S_SPACE_FAIL=Spatiu insuficient!"
set "S_CLEANING=Se sterge copia veche..."
set "S_FOLDER_LOCKED=Folder blocat (alt Weasis ruleaza?)"
set "S_FOLDER_FAIL=Nu s-a putut crea folderul temporar"
set "S_COPYING=Se copiaza de pe disc..."
set "S_JAR=Fisiere JAR"
set "S_BUNDLE=Bundle OSGI"
set "S_CONFIG=Configuratie"
set "S_RESOURCES=Resurse"
set "S_JRE=JRE %ARCH_LABEL%"
set "S_DICOM=DICOM"
set "S_DICOM_JUNC_FAIL=Junction DICOM nu a reusit, se copiaza..."
set "S_VERIFY=Verificare fisiere..."
set "S_VERIFY_OK=Toate fisierele copiate cu succes!"
set "S_VERIFY_FAIL=Copierea a esuat! Fisiere lipsa."
set "S_CACHE=Curatare cache OSGI..."
set "S_LAUNCH=Se lanseaza Weasis..."
set "S_LAUNCH_OK=Weasis pornit cu succes!"
set "S_LAUNCH_FAIL=Weasis nu a pornit! (posibil blocat de antivirus)"
set "S_FALLBACK=Se trece la lansare directa de pe disc..."
set "S_FALLBACK_SLOW=Poate dura 3-5 minute..."
set "S_WARN32_TITLE=Arhitectura calculatorului este pe 32 de biti."
set "S_WARN32_MSG=Se recomanda utilizarea aplicatiei RadiAnt pentru o experienta optima."
set "S_WARN32_PROMPT=Apasati orice tasta pentru a continua sau inchideti fereastra."
exit /b 0

:SET_STRINGS_ru
set "S_WAIT=Pozhalujsta, podozhdite neskol'ko minut..."
set "S_SPACE_CHECK=Proverka svobodnogo mesta..."
set "S_SPACE_OK=Dostupno:"
set "S_SPACE_FAIL=Nedostatochno mesta!"
set "S_CLEANING=Udalenie staroj kopii..."
set "S_FOLDER_LOCKED=Papka zablokirovana (drugoj Weasis zapushchen?)"
set "S_FOLDER_FAIL=Ne udalos' sozdat' vremennuyu papku"
set "S_COPYING=Kopirovanie s diska..."
set "S_JAR=Fajly JAR"
set "S_BUNDLE=Moduli OSGI"
set "S_CONFIG=Konfiguracija"
set "S_RESOURCES=Resursy"
set "S_JRE=JRE %ARCH_LABEL%"
set "S_DICOM=DICOM"
set "S_DICOM_JUNC_FAIL=Ssylka DICOM ne sozdana, kopirovanie..."
set "S_VERIFY=Proverka fajlov..."
set "S_VERIFY_OK=Vse fajly skopirovany!"
set "S_VERIFY_FAIL=Oshibka kopirovanija! Fajly otsutstvuyut."
set "S_CACHE=Ochistka kesha OSGI..."
set "S_LAUNCH=Zapusk Weasis..."
set "S_LAUNCH_OK=Weasis uspeshno zapushchen!"
set "S_LAUNCH_FAIL=Weasis ne zapustilsya! (vozmozhno, zablokirovan antivirusom)"
set "S_FALLBACK=Zapusk napryamuyu s diska..."
set "S_FALLBACK_SLOW=Eto mozhet zanyat' 3-5 minut..."
set "S_WARN32_TITLE=Arkhitektura komp'yutera - 32 bita."
set "S_WARN32_MSG=Rekomenduetsya ispol'zovat' prilozhenie RadiAnt dlya optimal'noj raboty."
set "S_WARN32_PROMPT=Nazhmite lyubuyu klavishu dlya prodolzheniya ili zakrojte okno."
exit /b 0

:SET_STRINGS_en
set "S_WAIT=Please wait a few minutes..."
set "S_SPACE_CHECK=Checking disk space..."
set "S_SPACE_OK=Available space:"
set "S_SPACE_FAIL=Insufficient space!"
set "S_CLEANING=Removing old copy..."
set "S_FOLDER_LOCKED=Folder locked (another Weasis running?)"
set "S_FOLDER_FAIL=Cannot create temporary folder"
set "S_COPYING=Copying from disc..."
set "S_JAR=JAR files"
set "S_BUNDLE=OSGI Bundles"
set "S_CONFIG=Configuration"
set "S_RESOURCES=Resources"
set "S_JRE=JRE %ARCH_LABEL%"
set "S_DICOM=DICOM"
set "S_DICOM_JUNC_FAIL=DICOM junction failed, copying..."
set "S_VERIFY=Verifying files..."
set "S_VERIFY_OK=All files copied successfully!"
set "S_VERIFY_FAIL=Copy failed! Missing files."
set "S_CACHE=Cleaning OSGI cache..."
set "S_LAUNCH=Launching Weasis..."
set "S_LAUNCH_OK=Weasis started successfully!"
set "S_LAUNCH_FAIL=Weasis failed to start! (possibly blocked by antivirus)"
set "S_FALLBACK=Switching to direct disc launch..."
set "S_FALLBACK_SLOW=This may take 3-5 minutes..."
set "S_WARN32_TITLE=Computer architecture is 32-bit."
set "S_WARN32_MSG=We recommend using RadiAnt for an optimal experience."
set "S_WARN32_PROMPT=Press any key to continue or close this window."
exit /b 0

:CMD_START

REM --- OS version check (Windows 10 = ver 10.x, Windows 7 = ver 6.x) ---
for /f "tokens=4 delims=[] " %%v in ('ver') do set "OS_VER=%%v"
for /f "tokens=1 delims=." %%m in ("%OS_VER%") do set "OS_MAJOR=%%m"
if %OS_MAJOR% LSS 10 (
    echo.
    echo   ================================================
    echo   [!] Windows %OS_VER% detectat
    echo.
    if "%LANG%"=="ro" (
        echo   Sistemul de operare nu indeplineste cerintele.
        echo   Weasis necesita Windows 10 sau mai nou.
        echo   Recomandam sa folositi aplicatia RadiAnt
        echo   pentru o experienta optima.
    ) else if "%LANG%"=="ru" (
        echo   Operacionnaya sistema ne sootvetstvuet trebovaniyam.
        echo   Weasis trebuet Windows 10 ili novee.
        echo   Rekomenduem ispol'zovat' RadiAnt
        echo   dlya optimal'noj raboty.
    ) else (
        echo   Operating system does not meet requirements.
        echo   Weasis requires Windows 10 or newer.
        echo   We recommend using RadiAnt
        echo   for an optimal experience.
    )
    echo.
    echo   ================================================
    echo.
    pause
    exit /b 0
)

REM --- RAM check (uses wmic to get total physical memory) ---
set "RAM_MB=0"
for /f "skip=1 tokens=*" %%a in ('wmic computersystem get TotalPhysicalMemory 2^>nul') do (
    for /f "tokens=1" %%b in ("%%a") do (
        if not "%%b"=="" set "RAM_BYTES=%%b"
    )
)
if defined RAM_BYTES (
    set "RAM_TRUNC=%RAM_BYTES:~0,-6%"
    if defined RAM_TRUNC set /a "RAM_MB=%RAM_TRUNC%" 2>nul
)

REM RAM < 2048 MB = block, 2048-4095 MB = warning
if %RAM_MB% LSS 2048 if %RAM_MB% GTR 0 (
    echo.
    echo   ================================================
    if "%LANG%"=="ro" (
        echo   [!] Memorie RAM insuficienta: %RAM_MB% MB
        echo   Weasis necesita minim 2 GB RAM.
        echo   Recomandam sa folositi aplicatia RadiAnt
        echo   pentru o experienta optima.
    ) else if "%LANG%"=="ru" (
        echo   [!] Nedostatochno operativnoj pamyati: %RAM_MB% MB
        echo   Weasis trebuet minimum 2 GB RAM.
        echo   Rekomenduem ispol'zovat' RadiAnt
        echo   dlya optimal'noj raboty.
    ) else (
        echo   [!] Insufficient RAM: %RAM_MB% MB
        echo   Weasis requires at least 2 GB RAM.
        echo   We recommend using RadiAnt
        echo   for an optimal experience.
    )
    echo   ================================================
    echo.
    pause
    exit /b 0
)

echo.
echo   %C_GREEN%=======================================================%C_R%
echo   %C_GREEN% Weasis v3.7.1%C_R%  ^|  %C_CYAN%JRE: %ARCH_LABEL%%C_R%
echo   %C_GREEN%=======================================================%C_R%
echo   %C_GRAY%%S_WAIT%%C_R%
echo.

REM --- RAM warning (2-4 GB) ---
if %RAM_MB% LSS 4096 (
    if "%LANG%"=="ro" (
        echo   %C_YELLOW%[!] Memorie RAM redusa: %RAM_MB% MB. Recomandam minim 4 GB.%C_R%
    ) else if "%LANG%"=="ru" (
        echo   %C_YELLOW%[!] Malo operativnoj pamyati: %RAM_MB% MB. Rekomenduem minimum 4 GB.%C_R%
    ) else (
        echo   %C_YELLOW%[!] Low RAM: %RAM_MB% MB. We recommend at least 4 GB.%C_R%
    )
    echo.
)

REM --- 32-bit warning ---
if "%ARCH_LABEL%"=="32-bit" (
    echo   %C_YELLOW%[!] %S_WARN32_TITLE%%C_R%
    echo   %C_YELLOW%    %S_WARN32_MSG%%C_R%
    echo.
    echo   %C_GRAY%%S_WARN32_PROMPT%%C_R%
    pause >nul
    echo.
)

REM --- Step 1: Check free space ---
echo   %C_GRAY%[..] %S_SPACE_CHECK%%C_R%
set "FREE_MB=0"
set "FREE_BYTES="
set "TEMP_DRIVE=%TEMP:~0,2%"
for /f "skip=1 tokens=*" %%a in ('wmic logicaldisk where "DeviceID='%TEMP_DRIVE%'" get FreeSpace 2^>nul') do (
    for /f "tokens=1" %%b in ("%%a") do (
        if not "%%b"=="" set "FREE_BYTES=%%b"
    )
)
set "SPACE_FAIL=0"
if defined FREE_BYTES call :CHECK_SPACE
if not defined FREE_BYTES echo   %C_YELLOW%[..] Space check skipped%C_R%
if "%SPACE_FAIL%"=="1" goto :DVD_FALLBACK

REM --- Step 2: Clean old temp folder ---
if exist "%TEMP_DIR%" (
    echo   %C_GRAY%[..] %S_CLEANING%%C_R%
    if exist "%TEMP_DIR%\DICOM" rmdir "%TEMP_DIR%\DICOM" 2>nul
    rmdir /s /q "%TEMP_DIR%" 2>nul
    if exist "%TEMP_DIR%" (
        echo   %C_RED%[X] %S_FOLDER_LOCKED%%C_R%
        goto :DVD_FALLBACK
    )
)

REM --- Step 3: Create temp folder ---
mkdir "%TEMP_DIR%" 2>nul
if not exist "%TEMP_DIR%" (
    echo   %C_RED%[X] %S_FOLDER_FAIL%%C_R%
    goto :DVD_FALLBACK
)

echo   %C_GRAY%[..] %S_COPYING%%C_R%

REM --- [1/6] JAR files ---
echo   %C_GREEN%[1/6]%C_R% %S_JAR%
copy /y "%DISC%weasis-launcher.jar" "%TEMP_DIR%\" >nul 2>&1
copy /y "%DISC%felix.jar" "%TEMP_DIR%\" >nul 2>&1
copy /y "%DISC%substance.jar" "%TEMP_DIR%\" >nul 2>&1
if not exist "%TEMP_DIR%\weasis-launcher.jar" (
    echo   %C_RED%[X] %S_JAR%%C_R%
    goto :DVD_FALLBACK_CLEANUP
)
echo   %C_GREEN%[OK] %S_JAR%%C_R%

REM --- [2/6] OSGI Bundles ---
echo   %C_GREEN%[2/6]%C_R% %S_BUNDLE%
xcopy /E /I /Q /Y "%DISC%bundle" "%TEMP_DIR%\bundle" >nul 2>&1
if exist "%DISC%bundle-i18n" (
    xcopy /E /I /Q /Y "%DISC%bundle-i18n" "%TEMP_DIR%\bundle-i18n" >nul 2>&1
)
if not exist "%TEMP_DIR%\bundle" (
    echo   %C_RED%[X] %S_BUNDLE%%C_R%
    goto :DVD_FALLBACK_CLEANUP
)
echo   %C_GREEN%[OK] %S_BUNDLE%%C_R%

REM --- [3/6] Configuration ---
echo   %C_GREEN%[3/6]%C_R% %S_CONFIG%
xcopy /E /I /Q /Y "%DISC%conf" "%TEMP_DIR%\conf" >nul 2>&1
if not exist "%TEMP_DIR%\conf\config.properties" (
    echo   %C_RED%[X] %S_CONFIG%%C_R%
    goto :DVD_FALLBACK_CLEANUP
)
echo   %C_GREEN%[OK] %S_CONFIG%%C_R%

REM --- [4/6] Resources ---
echo   %C_GREEN%[4/6]%C_R% %S_RESOURCES%
if exist "%DISC%resources" (
    xcopy /E /I /Q /Y "%DISC%resources" "%TEMP_DIR%\resources" >nul 2>&1
)
echo   %C_GREEN%[OK] %S_RESOURCES%%C_R%

REM --- [5/6] JRE ---
echo   %C_GREEN%[5/6]%C_R% %S_JRE%
REM JRE_DIR is always jre\windows or jre\windows-x64, parent is jre
if not exist "%TEMP_DIR%\jre" mkdir "%TEMP_DIR%\jre" 2>nul
xcopy /E /I /Q /Y "%DISC%%JRE_DIR%" "%TEMP_DIR%\%JRE_DIR%" >nul 2>&1
if not exist "%TEMP_DIR%\%JRE_DIR%\bin\javaw.exe" (
    echo   %C_RED%[X] %S_JRE%%C_R%
    goto :DVD_FALLBACK_CLEANUP
)
echo   %C_GREEN%[OK] %S_JRE%%C_R%

REM --- [6/6] DICOM junction ---
echo   %C_GREEN%[6/6]%C_R% %S_DICOM%
if exist "%DISC%DICOM" (
    mklink /J "%TEMP_DIR%\DICOM" "%DISC%DICOM" >nul 2>&1
    if not exist "%TEMP_DIR%\DICOM" (
        echo   %C_YELLOW%[!] %S_DICOM_JUNC_FAIL%%C_R%
        xcopy /E /I /Q /Y "%DISC%DICOM" "%TEMP_DIR%\DICOM" >nul 2>&1
    )
)
echo   %C_GREEN%[OK] %S_DICOM%%C_R%

REM --- Verify essential files ---
echo   %C_GRAY%[..] %S_VERIFY%%C_R%
set "VERIFY_OK=1"
if not exist "%TEMP_DIR%\weasis-launcher.jar" set "VERIFY_OK=0"
if not exist "%TEMP_DIR%\felix.jar" set "VERIFY_OK=0"
if not exist "%TEMP_DIR%\substance.jar" set "VERIFY_OK=0"
if not exist "%TEMP_DIR%\%JRE_DIR%\bin\javaw.exe" set "VERIFY_OK=0"
if not exist "%TEMP_DIR%\conf\config.properties" set "VERIFY_OK=0"
if "%VERIFY_OK%"=="0" (
    echo   %C_RED%[X] %S_VERIFY_FAIL%%C_R%
    goto :DVD_FALLBACK_CLEANUP
)
echo   %C_GREEN%[OK] %S_VERIFY_OK%%C_R%

REM --- Clean OSGI cache ---
echo   %C_GRAY%[..] %S_CACHE%%C_R%
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

REM --- Launch Weasis from local copy ---
echo   %C_GRAY%[..] %S_LAUNCH%%C_R%
start "Weasis" "%TEMP_DIR%\%JRE_DIR%\bin\javaw.exe" %JAVA_MEM% -Dweasis.portable.dir="%TEMP_DIR%\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%TEMP_DIR%\weasis-launcher.jar;%TEMP_DIR%\felix.jar;%TEMP_DIR%\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable

REM --- Verify javaw started (antivirus may block) ---
timeout /t 3 /nobreak >nul
tasklist /fi "imagename eq javaw.exe" 2>nul | findstr /i "javaw" >nul
if errorlevel 1 (
    echo   %C_RED%[X] %S_LAUNCH_FAIL%%C_R%
    goto :DVD_FALLBACK_CLEANUP
)
echo   %C_GREEN%[OK] %S_LAUNCH_OK%%C_R%
echo.
timeout /t 3 /nobreak >nul
exit /b 0

REM ============================================================================
REM  DVD FALLBACK (cleanup temp + launch direct from disc)
REM ============================================================================
:DVD_FALLBACK_CLEANUP
if exist "%TEMP_DIR%\DICOM" rmdir "%TEMP_DIR%\DICOM" 2>nul
if exist "%TEMP_DIR%" rmdir /s /q "%TEMP_DIR%" 2>nul

:DVD_FALLBACK
echo.
echo   %C_YELLOW%[!] %S_FALLBACK%%C_R%
echo   %C_YELLOW%    %S_FALLBACK_SLOW%%C_R%
echo.

for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

start "Weasis" "%~dp0%JRE_DIR%\bin\javaw.exe" %JAVA_MEM% -Dweasis.portable.dir="%~dp0." -Dgosh.args="-sc telnetd -p 17179 start" -cp "%~dp0weasis-launcher.jar;%~dp0felix.jar;%~dp0substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable

echo   %C_GREEN%[OK] %S_LAUNCH%%C_R%
timeout /t 5 /nobreak >nul
exit /b 0

REM ============================================================================
REM  SUBROUTINE: Check free space (avoids delayed expansion)
REM ============================================================================
:CHECK_SPACE
set "FREE_TRUNC=%FREE_BYTES:~0,-6%"
if not defined FREE_TRUNC (
    set "FREE_MB=0"
) else (
    set /a "FREE_MB=%FREE_TRUNC%" 2>nul
)
if %FREE_MB% LSS %NEED_MB% (
    echo   %C_RED%[X] %S_SPACE_FAIL% %S_SPACE_OK% %FREE_MB% MB%C_R%
    set "SPACE_FAIL=1"
    exit /b 0
)
echo   %C_GREEN%[OK] %S_SPACE_OK% %FREE_MB% MB%C_R%
exit /b 0
