# Build script for DICOM Receiver installer
# Produces two variants:
#   Online  — small .exe (~10 MB), installs .NET 8 Runtime + MSI, then runs setup.ps1
#   Offline — large .exe (~540 MB), installs .NET 8 Runtime + MSI with tools bundled
#
# Usage:
#   .\build.ps1              # Build both variants
#   .\build.ps1 -Online      # Build online only
#   .\build.ps1 -Offline     # Build offline only
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

$step = 1
$totalSteps = 2 + ([bool]$Online -as [int]) * 2 + ([bool]$Offline -as [int]) * 2

# Step 1: Publish DicomReceiver
Write-Host "[$step/$totalSteps] Publishing DicomReceiver..." -ForegroundColor Yellow
dotnet publish "$root\src\DicomReceiver\DicomReceiver.csproj" `
    -c $Configuration -r win-x64 --no-self-contained `
    -o "$root\publish\app" -p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "DicomReceiver publish failed" }
$step++

# Step 2: Publish DicomReceiverService
Write-Host "[$step/$totalSteps] Publishing DicomReceiverService..." -ForegroundColor Yellow
dotnet publish "$root\src\DicomReceiverService\DicomReceiverService.csproj" `
    -c $Configuration -r win-x64 --no-self-contained `
    -o "$root\publish\service" -p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "DicomReceiverService publish failed" }
$step++

# --- Online variant ---
if ($Online) {
    # Build MSI (online)
    Write-Host "[$step/$totalSteps] Building Online MSI..." -ForegroundColor Yellow
    dotnet clean "$root\src\Installer\Installer.wixproj" -c $Configuration --nologo -v q 2>$null
    dotnet build "$root\src\Installer\Installer.wixproj" `
        -c $Configuration `
        -p:IncludeTools=false `
        -p:ProductVersion=$Version
    if ($LASTEXITCODE -ne 0) { throw "Online MSI build failed" }
    $step++

    # Build Bundle (online) — wraps .NET 8 Runtime + MSI
    Write-Host "[$step/$totalSteps] Building Online Bundle (.exe)..." -ForegroundColor Yellow
    dotnet clean "$root\src\Bundle\Bundle.wixproj" -c $Configuration --nologo -v q 2>$null
    dotnet build "$root\src\Bundle\Bundle.wixproj" `
        -c $Configuration `
        -p:IncludeTools=false `
        -p:ProductVersion=$Version
    if ($LASTEXITCODE -ne 0) { throw "Online Bundle build failed" }

    $onlineExe = Get-ChildItem "$root\src\Bundle\bin\$Configuration" -Filter "*Online*.exe" -Recurse | Select-Object -First 1
    if ($onlineExe) {
        New-Item "$root\output" -ItemType Directory -Force | Out-Null
        Copy-Item $onlineExe.FullName "$root\output\" -Force
        Write-Host "  Online: $($onlineExe.Name) ($([math]::Round($onlineExe.Length / 1MB, 1)) MB)" -ForegroundColor Green
    }
    $step++
}

# --- Offline variant ---
if ($Offline) {
    $weasisDir = "$root\tools\weasis-portable"
    $dcmtkDir = "$root\tools\dcmtk"
    if (-not (Test-Path $weasisDir) -or -not (Test-Path $dcmtkDir)) {
        Write-Host "  WARNING: tools\ not complete. Run scripts\setup.ps1 first." -ForegroundColor Red
        Write-Host "  Skipping offline build." -ForegroundColor Red
        $step += 2
    } else {
        # Build MSI (offline)
        Write-Host "[$step/$totalSteps] Building Offline MSI (this may take a while)..." -ForegroundColor Yellow
        dotnet clean "$root\src\Installer\Installer.wixproj" -c $Configuration --nologo -v q 2>$null
        dotnet build "$root\src\Installer\Installer.wixproj" `
            -c $Configuration `
            -p:IncludeTools=true `
            -p:ProductVersion=$Version
        if ($LASTEXITCODE -ne 0) { throw "Offline MSI build failed" }
        $step++

        # Build Bundle (offline)
        Write-Host "[$step/$totalSteps] Building Offline Bundle (.exe)..." -ForegroundColor Yellow
        dotnet clean "$root\src\Bundle\Bundle.wixproj" -c $Configuration --nologo -v q 2>$null
        dotnet build "$root\src\Bundle\Bundle.wixproj" `
            -c $Configuration `
            -p:IncludeTools=true `
            -p:ProductVersion=$Version
        if ($LASTEXITCODE -ne 0) { throw "Offline Bundle build failed" }

        $offlineExe = Get-ChildItem "$root\src\Bundle\bin\$Configuration" -Filter "*Offline*.exe" -Recurse | Select-Object -First 1
        if ($offlineExe) {
            New-Item "$root\output" -ItemType Directory -Force | Out-Null
            Copy-Item $offlineExe.FullName "$root\output\" -Force
            Write-Host "  Offline: $($offlineExe.Name) ($([math]::Round($offlineExe.Length / 1MB, 1)) MB)" -ForegroundColor Green
        }
        $step++
    }
}

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Cyan
Write-Host "Output: $root\output\" -ForegroundColor Cyan
Get-ChildItem "$root\output\*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  $($_.Name) - $([math]::Round($_.Length / 1MB, 1)) MB" -ForegroundColor Green
}
Write-Host ""
Read-Host "Press Enter to close"
