# Install/Uninstall DicomReceiverService as a Windows Service
# Must be run as Administrator
#
# Usage:
#   .\install-service.ps1              — Install and start the service
#   .\install-service.ps1 -Uninstall   — Stop and remove the service

param(
    [switch]$Uninstall
)

$serviceName = "DicomReceiverService"
$displayName = "DICOM Receiver Service (Weasis Burn)"
$description = "Receives DICOM studies via C-STORE SCP for DVD burning"
$port = 4006

# Find the built executable
$scriptDir = $PSScriptRoot
$exePath = Join-Path $scriptDir "..\src\DicomReceiverService\bin\Release\net8.0-windows\DicomReceiverService.exe"
if (-not (Test-Path $exePath)) {
    $exePath = Join-Path $scriptDir "..\src\DicomReceiverService\bin\Debug\net8.0-windows\DicomReceiverService.exe"
}

if ($Uninstall) {
    Write-Host "Stopping service '$serviceName'..." -ForegroundColor Yellow
    sc.exe stop $serviceName 2>$null
    Start-Sleep -Seconds 2

    Write-Host "Removing service..." -ForegroundColor Yellow
    sc.exe delete $serviceName

    Write-Host "Removing firewall rule..." -ForegroundColor Yellow
    netsh advfirewall firewall delete rule name="DICOM Receiver Service" 2>$null

    Write-Host "Service '$serviceName' removed." -ForegroundColor Green
}
else {
    if (-not (Test-Path $exePath)) {
        Write-Error "Build the service first: dotnet build src/DicomReceiverService -c Release"
        exit 1
    }

    $fullExePath = (Resolve-Path $exePath).Path
    Write-Host "Installing service from: $fullExePath" -ForegroundColor Cyan

    # Create the service (auto-start with Windows)
    sc.exe create $serviceName binPath= "`"$fullExePath`"" start= auto DisplayName= "$displayName"
    sc.exe description $serviceName "$description"

    # Add firewall rule for DICOM port
    Write-Host "Adding firewall rule for port $port..." -ForegroundColor Yellow
    netsh advfirewall firewall add rule name="DICOM Receiver Service" dir=in action=allow protocol=TCP localport=$port

    # Start the service
    Write-Host "Starting service..." -ForegroundColor Yellow
    sc.exe start $serviceName

    Write-Host ""
    Write-Host "Service '$serviceName' installed and started." -ForegroundColor Green
    Write-Host "  AE Title and Port configured in WPF app Settings dialog." -ForegroundColor Gray
    Write-Host "  Settings saved to: C:\ProgramData\WeasisBurn\dicom-receiver-settings.json" -ForegroundColor Gray
}
