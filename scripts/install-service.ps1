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

# Check administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as Administrator, then re-run this script." -ForegroundColor Yellow
    exit 1
}

# Read port from shared settings (same file the WPF app writes)
$port = 4006
$settingsPath = "C:\ProgramData\WeasisBurn\dicom-receiver-settings.json"
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.Port -and $settings.Port -ge 1 -and $settings.Port -le 65535) {
            $port = $settings.Port
        }
    } catch {
        Write-Host "Warning: Could not read settings from $settingsPath, using default port $port" -ForegroundColor Yellow
    }
}

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

    Write-Host ""
    Write-Host "Service '$serviceName' removed." -ForegroundColor Green
}
else {
    # Validate exe exists
    if (-not (Test-Path $exePath)) {
        Write-Host "ERROR: Service executable not found." -ForegroundColor Red
        Write-Host "Build the service first:" -ForegroundColor Yellow
        Write-Host "  dotnet build src/DicomReceiverService -c Release" -ForegroundColor Cyan
        exit 1
    }

    # Check if service already exists
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Host "ERROR: Service '$serviceName' already exists (status: $($existingService.Status))." -ForegroundColor Red
        Write-Host "To reinstall, first uninstall:" -ForegroundColor Yellow
        Write-Host "  .\install-service.ps1 -Uninstall" -ForegroundColor Cyan
        exit 1
    }

    # Check if port is already in use
    $portInUse = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($portInUse) {
        $pid = $portInUse[0].OwningProcess
        $procName = (Get-Process -Id $pid -ErrorAction SilentlyContinue).ProcessName
        Write-Host "WARNING: Port $port already in use by $procName (PID $pid)." -ForegroundColor Yellow
        Write-Host "The service may fail to start. Change the port in Settings or stop the conflicting process." -ForegroundColor Yellow
    }

    $fullExePath = (Resolve-Path $exePath).Path
    Write-Host "Installing service from: $fullExePath" -ForegroundColor Cyan
    Write-Host "DICOM port: $port" -ForegroundColor Cyan

    # Create the service (auto-start with Windows)
    sc.exe create $serviceName binPath= "`"$fullExePath`"" start= auto DisplayName= "$displayName"
    sc.exe description $serviceName "$description"

    # Add firewall rule for DICOM port
    Write-Host "Adding firewall rule for port $port (TCP inbound)..." -ForegroundColor Yellow
    netsh advfirewall firewall delete rule name="DICOM Receiver Service" 2>$null
    netsh advfirewall firewall add rule name="DICOM Receiver Service" dir=in action=allow protocol=TCP localport=$port

    # Start the service
    Write-Host "Starting service..." -ForegroundColor Yellow
    sc.exe start $serviceName

    Start-Sleep -Seconds 2
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host ""
        Write-Host "Service '$serviceName' installed and running." -ForegroundColor Green
        Write-Host "  Port: $port (TCP)" -ForegroundColor Gray
        Write-Host "  AE Title and Port configured in WPF app Settings dialog." -ForegroundColor Gray
        Write-Host "  Settings: $settingsPath" -ForegroundColor Gray
    } else {
        Write-Host ""
        Write-Host "WARNING: Service installed but may not be running. Check Event Viewer for errors." -ForegroundColor Yellow
        Write-Host "  Try: Get-Service $serviceName | Format-List *" -ForegroundColor Gray
    }
}
