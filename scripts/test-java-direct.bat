@echo off
cd /d "C:\Users\Fucking_User\AppData\Local\Temp\weasis-test"
echo Current directory: %CD%
echo.
echo Testing Java...
jre\windows\bin\java.exe -version
echo.
echo Testing Weasis launcher...
jre\windows\bin\java.exe -Xms64m -Xmx768m -Dgosh.args="-sc telnetd -p 17179 start" -jar weasis-launcher.jar
echo.
echo Exit code: %ERRORLEVEL%
pause
