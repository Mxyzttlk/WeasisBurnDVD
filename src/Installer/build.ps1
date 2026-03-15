# Build script for DICOM Receiver installer
# Produces two MSI variants: Online (~10 MB) and Offline (~540 MB with tools)
#
# Usage:
#   .\build.ps1              # Build both variants
#   .\build.ps1 -Online      # Build online MSI only
#   .\build.ps1 -Offline     # Build offline MSI only
#   .\build.ps1 -Version 1.2.0  # Override version number

param(
    [switch]$Online,
    [switch]$Offline,
    [string]$Version = "1.0.0",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

Write-Host "=== DICOM Receiver Installer Build ===" -ForegroundColor Cyan
Write-Host "Root: $root"
Write-Host "Version: $Version"
Write-Host ""

# If neither specified, build both
if (-not $Online -and -not $Offline) {
    $Online = $true
    $Offline = $true
}

# Step 1: Publish .NET projects
Write-Host "[1/4] Publishing DicomReceiver..." -ForegroundColor Yellow
dotnet publish "$root\src\DicomReceiver\DicomReceiver.csproj" `
    -c $Configuration -r win-x64 --no-self-contained `
    -o "$root\publish\app" -p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "DicomReceiver publish failed" }

Write-Host "[2/4] Publishing DicomReceiverService..." -ForegroundColor Yellow
dotnet publish "$root\src\DicomReceiverService\DicomReceiverService.csproj" `
    -c $Configuration -r win-x64 --no-self-contained `
    -o "$root\publish\service" -p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "DicomReceiverService publish failed" }

# Step 3: Build Online MSI
if ($Online) {
    Write-Host "[3/4] Building Online MSI..." -ForegroundColor Yellow
    dotnet build "$root\src\Installer\Installer.wixproj" `
        -c $Configuration `
        -p:IncludeTools=false `
        -p:ProductVersion=$Version
    if ($LASTEXITCODE -ne 0) { throw "Online MSI build failed" }

    $onlineMsi = Get-ChildItem "$root\src\Installer\bin\$Configuration" -Filter "*Online*.msi" -Recurse | Select-Object -First 1
    if ($onlineMsi) {
        Write-Host "  Online MSI: $($onlineMsi.FullName)" -ForegroundColor Green
        Write-Host "  Size: $([math]::Round($onlineMsi.Length / 1MB, 1)) MB" -ForegroundColor Green
    }
}

# Step 4: Build Offline MSI
if ($Offline) {
    # Verify tools exist for offline build
    $weasisDir = "$root\tools\weasis-portable"
    $dcmtkDir = "$root\tools\dcmtk"
    if (-not (Test-Path $weasisDir)) {
        Write-Host "  WARNING: tools\weasis-portable\ not found. Run scripts\setup.ps1 first." -ForegroundColor Red
        Write-Host "  Skipping offline build." -ForegroundColor Red
    } elseif (-not (Test-Path $dcmtkDir)) {
        Write-Host "  WARNING: tools\dcmtk\ not found. Run scripts\setup.ps1 first." -ForegroundColor Red
        Write-Host "  Skipping offline build." -ForegroundColor Red
    } else {
        Write-Host "[4/4] Building Offline MSI (this may take a while)..." -ForegroundColor Yellow
        dotnet build "$root\src\Installer\Installer.wixproj" `
            -c $Configuration `
            -p:IncludeTools=true `
            -p:ProductVersion=$Version
        if ($LASTEXITCODE -ne 0) { throw "Offline MSI build failed" }

        $offlineMsi = Get-ChildItem "$root\src\Installer\bin\$Configuration" -Filter "*Offline*.msi" -Recurse | Select-Object -First 1
        if ($offlineMsi) {
            Write-Host "  Offline MSI: $($offlineMsi.FullName)" -ForegroundColor Green
            Write-Host "  Size: $([math]::Round($offlineMsi.Length / 1MB, 1)) MB" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Cyan
