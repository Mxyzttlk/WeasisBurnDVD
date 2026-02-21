@echo off
cd /d "C:\Users\Fucking_User\AppData\Local\Temp\weasis-test"
echo Current directory: %CD%
echo.
echo Testing Weasis launch with explicit classpath + main class...
echo Command: jre\windows\bin\java.exe -Xms64m -Xmx768m -Dgosh.args="-sc telnetd -p 17179 start" -cp "weasis-launcher.jar;felix.jar;substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
jre\windows\bin\java.exe -Xms64m -Xmx768m -Dgosh.args="-sc telnetd -p 17179 start" -cp "weasis-launcher.jar;felix.jar;substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
echo.
echo Exit code: %ERRORLEVEL%
pause
