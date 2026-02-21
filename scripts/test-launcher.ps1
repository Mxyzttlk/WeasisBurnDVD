# Test: copy start-weasis.bat to disc contents copied locally, then run it
$testDir = Join-Path $env:TEMP "weasis-test"
if (Test-Path $testDir) { Remove-Item -Recurse -Force $testDir }

Write-Host "Copiez continutul discului F:\ in $testDir ..." -ForegroundColor Cyan
Copy-Item -Path "F:\" -Destination $testDir -Recurse -Force

# Copy our new launcher
Copy-Item -Path "E:\Weasis Burn\templates\start-weasis.bat" -Destination $testDir -Force

Write-Host "Lansez start-weasis.bat din $testDir ..." -ForegroundColor Cyan
Set-Location $testDir
& "$testDir\start-weasis.bat"
