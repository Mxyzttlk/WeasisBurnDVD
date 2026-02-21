@echo off
echo === Test cu cai absolute de pe F:\ ===
echo.
echo Inchide Weasis daca e deschis, apoi apasa o tasta...
pause
echo.
echo Curatare cache...
for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do (
    echo   Sterg: %%D
    rmdir /s /q "%%D" 2>nul
)
echo.
echo Lansez Weasis cu cai absolute (exact ca noul start-weasis.bat)...
start "Weasis" "F:\jre\windows\bin\javaw.exe" -Xms64m -Xmx768m -Dweasis.portable.dir="F:\." -Dgosh.args="-sc telnetd -p 17179 start" -cp "F:\weasis-launcher.jar;F:\felix.jar;F:\substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
echo Comanda trimisa. Weasis ar trebui sa apara in 30-60 secunde (citire DVD).
echo Daca nu apare, apasa o tasta pentru a iesi.
pause
