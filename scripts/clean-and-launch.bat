@echo off
echo Opresc toate procesele Java...
taskkill /f /im javaw.exe 2>nul
taskkill /f /im java.exe 2>nul
timeout /t 3 /nobreak >nul

echo Curatare cache Weasis...
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D" 2>nul

echo Lansez start-weasis.bat de pe F:\...
call "F:\start-weasis.bat"
