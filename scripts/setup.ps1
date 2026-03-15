# ============================================================================
# Setup Script - Downloads Weasis Portable + JRE + WebView2 SDK
# Copyright (c) 2026 Mxyzttlk. All rights reserved.
# Unauthorized copying, modification, or distribution is strictly prohibited.
# ============================================================================

$_bvt = "Q29weXJpZ2h0IDIwMjYgTXh5enR0bGs="
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ToolsDir    = Join-Path $ProjectRoot "tools"
$WeasisDir   = Join-Path $ToolsDir "weasis-portable"

function Write-Status($msg) {
    Write-Host ""
    Write-Host ">>> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -MaximumRedirection 20
    $ProgressPreference = 'Continue'
}

# ============================================================================
# Step 1: Download Weasis Portable 3.7.1
# ============================================================================

$weasisZipPath = Join-Path $ToolsDir "weasis-portable.zip"
$weasisUrl = "https://sourceforge.net/projects/dcm4che/files/Weasis/3.7.1/weasis-portable.zip/download"

if (Test-Path $WeasisDir) {
    Write-Status "Weasis portable deja exista in: $WeasisDir"
    $overwrite = Read-Host "    Vrei sa-l redescarci? (da/nu)"
    if ($overwrite -ne "da" -and $overwrite -ne "d") {
        Write-Ok "Pastrez versiunea existenta"
    } else {
        Remove-Item -Recurse -Force $WeasisDir
    }
}

if (-not (Test-Path $WeasisDir)) {
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null

    Write-Status "Descarc Weasis Portable 3.7.1..."
    Write-Host ""
    Write-Host "    SourceForge necesita descarcare prin browser." -ForegroundColor Yellow
    Write-Host "    Deschid browserul automat..." -ForegroundColor Yellow
    Write-Host ""

    # Open browser to download page
    Start-Process $weasisUrl

    Write-Host "    1. Asteapta sa inceapa descarcarea in browser" -ForegroundColor White
    Write-Host "    2. Salveaza fisierul (sau lasa-l in Downloads)" -ForegroundColor White
    Write-Host "    3. Apasa ENTER cand descarcarea este completa" -ForegroundColor White
    Write-Host ""
    Read-Host "    Apasa ENTER cand ai descarcat weasis-portable.zip"

    # Search for the downloaded file in common locations
    $searchLocations = @(
        (Join-Path $env:USERPROFILE "Downloads\weasis-portable.zip"),
        (Join-Path $env:USERPROFILE "Desktop\weasis-portable.zip"),
        $weasisZipPath
    )

    $foundZip = $null
    foreach ($loc in $searchLocations) {
        if (Test-Path $loc) {
            $foundZip = $loc
            break
        }
    }

    if (-not $foundZip) {
        Write-Host "    Nu am gasit weasis-portable.zip in locatiile obisnuite." -ForegroundColor Yellow
        $customPath = Read-Host "    Introdu calea completa catre fisierul descarcat"
        $customPath = $customPath.Trim('"', "'", ' ')
        if (Test-Path $customPath) {
            $foundZip = $customPath
        } else {
            Write-Host "    [EROARE] Fisierul nu exista: $customPath" -ForegroundColor Red
            exit 1
        }
    }

    Write-Ok "Gasit: $foundZip ($('{0:N1}' -f ((Get-Item $foundZip).Length / 1MB)) MB)"

    # Move to tools dir if not already there
    if ($foundZip -ne $weasisZipPath) {
        Copy-Item -Path $foundZip -Destination $weasisZipPath -Force
    }

    # Extract
    Write-Status "Extrag Weasis Portable..."
    Expand-Archive -Path $weasisZipPath -DestinationPath $ToolsDir -Force

    # Rename if needed
    $extractedDir = Get-ChildItem -Path $ToolsDir -Directory | Where-Object { $_.Name -match "weasis" } | Select-Object -First 1
    if ($extractedDir -and $extractedDir.Name -ne "weasis-portable") {
        Rename-Item -Path $extractedDir.FullName -NewName "weasis-portable"
    }

    # Clean up zip
    Remove-Item -Path $weasisZipPath -Force
    Write-Ok "Weasis Portable extras"
}

# ============================================================================
# Step 2: Download JRE x86 (Adoptium OpenJDK 8, 32-bit for max compatibility)
# ============================================================================

$jreWindowsDir = Join-Path $WeasisDir "jre\windows"

if (Test-Path (Join-Path $jreWindowsDir "bin\java.exe")) {
    Write-Ok "JRE x86 (32-bit) deja instalat"
} else {
    Write-Status "Descarc JRE x86 (Adoptium OpenJDK 8, 32-bit)..."

    $jreUrl = "https://api.adoptium.net/v3/binary/latest/8/ga/windows/x86/jre/hotspot/normal/eclipse"
    $jreZipPath = Join-Path $ToolsDir "jre8-x86.zip"

    Write-Host "    Aceasta poate dura cateva minute..." -ForegroundColor Yellow

    try {
        Download-File -Url $jreUrl -OutFile $jreZipPath
    } catch {
        Write-Host "    Descarcare automata esuata. Deschid browserul..." -ForegroundColor Yellow
        Start-Process $jreUrl
        Write-Host ""
        Write-Host "    Salveaza fisierul .zip descarcat si apasa ENTER" -ForegroundColor White
        Read-Host

        $jreDownloaded = Get-ChildItem -Path (Join-Path $env:USERPROFILE "Downloads") -Filter "OpenJDK8U-jre*x86*windows*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($jreDownloaded) {
            Copy-Item -Path $jreDownloaded.FullName -Destination $jreZipPath -Force
        } else {
            $customPath = Read-Host "    Introdu calea catre fisierul JRE .zip descarcat"
            $customPath = $customPath.Trim('"', "'", ' ')
            if (Test-Path $customPath) {
                Copy-Item -Path $customPath -Destination $jreZipPath -Force
            } else {
                Write-Host "    [EROARE] Fisierul nu exista." -ForegroundColor Red
                exit 1
            }
        }
    }

    Write-Ok "JRE x86 descarcat: $('{0:N1}' -f ((Get-Item $jreZipPath).Length / 1MB)) MB"

    Write-Status "Extrag JRE x86..."
    $jreTempDir = Join-Path $ToolsDir "jre-temp"
    Expand-Archive -Path $jreZipPath -DestinationPath $jreTempDir -Force

    $jreRoot = Get-ChildItem -Path $jreTempDir -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Path $jreWindowsDir -Force | Out-Null
    Copy-Item -Path (Join-Path $jreRoot.FullName "*") -Destination $jreWindowsDir -Recurse -Force

    Remove-Item -Path $jreZipPath -Force
    Remove-Item -Path $jreTempDir -Recurse -Force

    $javaExe = Join-Path $jreWindowsDir "bin\java.exe"
    if (Test-Path $javaExe) {
        Write-Ok "JRE x86 instalat cu succes"
        $version = cmd /c "`"$javaExe`" -version 2>&1"
        Write-Host "    $($version[0])" -ForegroundColor Gray
    } else {
        Write-Host "    [ATENTIE] java.exe nu a fost gasit la calea asteptata." -ForegroundColor Yellow
        Write-Host "    Calea corecta: $jreWindowsDir\bin\java.exe" -ForegroundColor Yellow
    }
}

# ============================================================================
# Step 2b: Download JRE x64 (Adoptium OpenJDK 8, 64-bit for MPR 3D support)
# ============================================================================

$jreWindowsX64Dir = Join-Path $WeasisDir "jre\windows-x64"

if (Test-Path (Join-Path $jreWindowsX64Dir "bin\java.exe")) {
    Write-Ok "JRE x64 (64-bit) deja instalat"
} else {
    Write-Status "Descarc JRE x64 (Adoptium OpenJDK 8, 64-bit)..."

    $jreX64Url = "https://api.adoptium.net/v3/binary/latest/8/ga/windows/x64/jre/hotspot/normal/eclipse"
    $jreX64ZipPath = Join-Path $ToolsDir "jre8-x64.zip"

    Write-Host "    Aceasta poate dura cateva minute..." -ForegroundColor Yellow

    try {
        Download-File -Url $jreX64Url -OutFile $jreX64ZipPath
    } catch {
        Write-Host "    Descarcare automata esuata. Deschid browserul..." -ForegroundColor Yellow
        Start-Process $jreX64Url
        Write-Host ""
        Write-Host "    Salveaza fisierul .zip descarcat si apasa ENTER" -ForegroundColor White
        Read-Host

        $jreX64Downloaded = Get-ChildItem -Path (Join-Path $env:USERPROFILE "Downloads") -Filter "OpenJDK8U-jre*x64*windows*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($jreX64Downloaded) {
            Copy-Item -Path $jreX64Downloaded.FullName -Destination $jreX64ZipPath -Force
        } else {
            $customPath = Read-Host "    Introdu calea catre fisierul JRE x64 .zip descarcat"
            $customPath = $customPath.Trim('"', "'", ' ')
            if (Test-Path $customPath) {
                Copy-Item -Path $customPath -Destination $jreX64ZipPath -Force
            } else {
                Write-Host "    [EROARE] Fisierul nu exista." -ForegroundColor Red
                exit 1
            }
        }
    }

    Write-Ok "JRE x64 descarcat: $('{0:N1}' -f ((Get-Item $jreX64ZipPath).Length / 1MB)) MB"

    Write-Status "Extrag JRE x64..."
    $jreTempDir = Join-Path $ToolsDir "jre-temp-x64"
    Expand-Archive -Path $jreX64ZipPath -DestinationPath $jreTempDir -Force

    $jreRoot = Get-ChildItem -Path $jreTempDir -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Path $jreWindowsX64Dir -Force | Out-Null
    Copy-Item -Path (Join-Path $jreRoot.FullName "*") -Destination $jreWindowsX64Dir -Recurse -Force

    Remove-Item -Path $jreX64ZipPath -Force
    Remove-Item -Path $jreTempDir -Recurse -Force

    $javaExe = Join-Path $jreWindowsX64Dir "bin\java.exe"
    if (Test-Path $javaExe) {
        Write-Ok "JRE x64 instalat cu succes"
        $version = cmd /c "`"$javaExe`" -version 2>&1"
        Write-Host "    $($version[0])" -ForegroundColor Gray
    } else {
        Write-Host "    [ATENTIE] java.exe x64 nu a fost gasit la calea asteptata." -ForegroundColor Yellow
        Write-Host "    Calea corecta: $jreWindowsX64Dir\bin\java.exe" -ForegroundColor Yellow
    }
}

# ============================================================================
# Step 3: Download WebView2 SDK (for PACS Burner app)
# ============================================================================

$WebView2Dir = Join-Path $ToolsDir "webview2"
$wv2CoreDll  = Join-Path $WebView2Dir "Microsoft.Web.WebView2.Core.dll"
$wv2WpfDll   = Join-Path $WebView2Dir "Microsoft.Web.WebView2.Wpf.dll"
$wv2Loader   = Join-Path $WebView2Dir "WebView2Loader.dll"

if ((Test-Path $wv2CoreDll) -and (Test-Path $wv2WpfDll) -and (Test-Path $wv2Loader)) {
    Write-Ok "WebView2 SDK deja instalat"
} else {
    Write-Status "Descarc WebView2 SDK (NuGet package)..."

    $wv2NugetUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2"
    $wv2ZipPath  = Join-Path $ToolsDir "webview2.nupkg.zip"

    try {
        Download-File -Url $wv2NugetUrl -OutFile $wv2ZipPath
    } catch {
        Write-Host "    Descarcare automata esuata." -ForegroundColor Yellow
        Write-Host "    Descarca manual de la: https://www.nuget.org/packages/Microsoft.Web.WebView2" -ForegroundColor Yellow
        Write-Host "    (Click 'Download package' pe pagina)" -ForegroundColor Yellow
        Write-Host ""
        Read-Host "    Salveaza fisierul .nupkg si apasa ENTER"

        $wv2Downloaded = Get-ChildItem -Path (Join-Path $env:USERPROFILE "Downloads") -Filter "microsoft.web.webview2*.nupkg" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($wv2Downloaded) {
            Copy-Item -Path $wv2Downloaded.FullName -Destination $wv2ZipPath -Force
        } else {
            $customPath = Read-Host "    Introdu calea catre fisierul .nupkg descarcat"
            $customPath = $customPath.Trim('"', "'", ' ')
            if (Test-Path $customPath) {
                Copy-Item -Path $customPath -Destination $wv2ZipPath -Force
            } else {
                Write-Host "    [EROARE] Fisierul nu exista." -ForegroundColor Red
                exit 1
            }
        }
    }

    Write-Ok "WebView2 NuGet descarcat: $('{0:N1}' -f ((Get-Item $wv2ZipPath).Length / 1MB)) MB"

    Write-Status "Extrag WebView2 SDK..."
    $wv2TempDir = Join-Path $ToolsDir "webview2-temp"
    # NuGet .nupkg is a ZIP file - rename extension for Expand-Archive
    Expand-Archive -Path $wv2ZipPath -DestinationPath $wv2TempDir -Force

    New-Item -ItemType Directory -Path $WebView2Dir -Force | Out-Null

    # Extract the 3 required DLLs from NuGet package structure:
    # lib/net462/Microsoft.Web.WebView2.Core.dll
    # lib/net462/Microsoft.Web.WebView2.Wpf.dll
    # runtimes/win-x64/native/WebView2Loader.dll
    $coreSrc = Get-ChildItem -Path $wv2TempDir -Recurse -Filter "Microsoft.Web.WebView2.Core.dll" |
        Where-Object { $_.DirectoryName -match "net45|net462|netcoreapp" } |
        Sort-Object { if ($_.DirectoryName -match "net462") { 0 } elseif ($_.DirectoryName -match "net45") { 1 } else { 2 } } |
        Select-Object -First 1

    $wpfSrc = Get-ChildItem -Path $wv2TempDir -Recurse -Filter "Microsoft.Web.WebView2.Wpf.dll" |
        Where-Object { $_.DirectoryName -match "net45|net462|netcoreapp" } |
        Sort-Object { if ($_.DirectoryName -match "net462") { 0 } elseif ($_.DirectoryName -match "net45") { 1 } else { 2 } } |
        Select-Object -First 1

    $loaderSrc = Get-ChildItem -Path $wv2TempDir -Recurse -Filter "WebView2Loader.dll" |
        Where-Object { $_.DirectoryName -match "x64" } |
        Select-Object -First 1

    $extractOk = $true
    if ($coreSrc) {
        Copy-Item -Path $coreSrc.FullName -Destination $wv2CoreDll -Force
        Write-Ok "Microsoft.Web.WebView2.Core.dll"
    } else {
        Write-Host "    [EROARE] Nu am gasit Core.dll in NuGet package" -ForegroundColor Red
        $extractOk = $false
    }

    if ($wpfSrc) {
        Copy-Item -Path $wpfSrc.FullName -Destination $wv2WpfDll -Force
        Write-Ok "Microsoft.Web.WebView2.Wpf.dll"
    } else {
        Write-Host "    [EROARE] Nu am gasit Wpf.dll in NuGet package" -ForegroundColor Red
        $extractOk = $false
    }

    if ($loaderSrc) {
        Copy-Item -Path $loaderSrc.FullName -Destination $wv2Loader -Force
        Write-Ok "WebView2Loader.dll (x64)"
    } else {
        Write-Host "    [EROARE] Nu am gasit WebView2Loader.dll in NuGet package" -ForegroundColor Red
        $extractOk = $false
    }

    # Clean up
    Remove-Item -Path $wv2ZipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $wv2TempDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($extractOk) {
        $wv2Size = (Get-ChildItem -Path $WebView2Dir -File | Measure-Object -Property Length -Sum).Sum
        Write-Ok "WebView2 SDK extras: $('{0:N1}' -f ($wv2Size / 1MB)) MB"
    } else {
        Write-Host "    [EROARE] Extractia WebView2 SDK a esuat." -ForegroundColor Red
    }
}

# ============================================================================
# Step 3b: Check/Install WebView2 Runtime (needed by PACS Burner app)
# ============================================================================

# WebView2 Runtime comes with Edge Chromium on Win 10/11, but may be missing on clean installs.
# Check registry for installed runtime.

$wv2RuntimeFound = $false
$wv2RegPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5810CD5}",
    "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5810CD5}",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5810CD5}"
)

foreach ($regPath in $wv2RegPaths) {
    if (Test-Path $regPath) {
        $ver = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).pv
        if ($ver) {
            Write-Ok "WebView2 Runtime deja instalat (v$ver)"
            $wv2RuntimeFound = $true
            break
        }
    }
}

if (-not $wv2RuntimeFound) {
    Write-Status "WebView2 Runtime nu este instalat. Descarc si instalez..."
    Write-Host "    (Necesar pentru PACS Burner - browserul integrat)" -ForegroundColor Yellow

    $bootstrapperUrl = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    $bootstrapperPath = Join-Path $ToolsDir "MicrosoftEdgeWebview2Setup.exe"

    try {
        Download-File -Url $bootstrapperUrl -OutFile $bootstrapperPath
        Write-Ok "Bootstrapper descarcat"

        Write-Host "    Instalez WebView2 Runtime (poate dura 1-2 minute)..." -ForegroundColor Yellow
        $proc = Start-Process -FilePath $bootstrapperPath -ArgumentList "/silent /install" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Ok "WebView2 Runtime instalat cu succes"
        } else {
            Write-Host "    [ATENTIE] Instalarea a returnat codul: $($proc.ExitCode)" -ForegroundColor Yellow
            Write-Host "    PACS Burner ar putea sa nu functioneze." -ForegroundColor Yellow
            Write-Host "    Instaleaza manual Microsoft Edge sau WebView2 Runtime." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    [ATENTIE] Nu am putut descarca WebView2 Runtime." -ForegroundColor Yellow
        Write-Host "    Instaleaza manual de la: https://developer.microsoft.com/en-us/microsoft-edge/webview2/" -ForegroundColor Yellow
        Write-Host "    Sau instaleaza Microsoft Edge (include WebView2 Runtime)." -ForegroundColor Yellow
    }

    # Clean up bootstrapper
    Remove-Item -Path $bootstrapperPath -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# Step 3c: Download dcmtk (for DICOMDIR generation)
# ============================================================================
# dcmmkdir.exe creates a DICOMDIR index file required by medical workstations
# (Siemens, GE, Philips) to recognize DICOM studies on DVD media.

$DcmtkDir    = Join-Path $ToolsDir "dcmtk"
$dcmmkdirExe = Join-Path $DcmtkDir "bin\dcmmkdir.exe"

if (Test-Path $dcmmkdirExe) {
    Write-Ok "dcmtk deja instalat (dcmmkdir.exe)"
} else {
    Write-Status "Descarc dcmtk 3.7.0 (pentru generare DICOMDIR)..."

    $dcmtkUrl     = "https://dicom.offis.de/download/dcmtk/dcmtk370/bin/dcmtk-3.7.0-win64-dynamic.zip"
    $dcmtkZipPath = Join-Path $ToolsDir "dcmtk.zip"

    Write-Host "    (~9 MB, cateva secunde)" -ForegroundColor Yellow

    try {
        Download-File -Url $dcmtkUrl -OutFile $dcmtkZipPath
    } catch {
        Write-Host "    Descarcare automata esuata. Deschid browserul..." -ForegroundColor Yellow
        Start-Process "https://dicom.offis.de/en/dcmtk/dcmtk-tools/"
        Write-Host ""
        Write-Host "    1. Descarca 'dcmtk-3.7.0-win64-dynamic.zip'" -ForegroundColor White
        Write-Host "    2. Salveaza in Downloads si apasa ENTER" -ForegroundColor White
        Write-Host ""
        Read-Host "    Apasa ENTER cand ai descarcat"

        $dcmtkDownloaded = Get-ChildItem -Path (Join-Path $env:USERPROFILE "Downloads") -Filter "dcmtk*win64*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($dcmtkDownloaded) {
            Copy-Item -Path $dcmtkDownloaded.FullName -Destination $dcmtkZipPath -Force
        } else {
            $customPath = Read-Host "    Introdu calea catre fisierul dcmtk .zip descarcat"
            $customPath = $customPath.Trim('"', "'", ' ')
            if (Test-Path $customPath) {
                Copy-Item -Path $customPath -Destination $dcmtkZipPath -Force
            } else {
                Write-Host "    [EROARE] Fisierul nu exista." -ForegroundColor Red
                exit 1
            }
        }
    }

    Write-Ok "dcmtk descarcat: $('{0:N1}' -f ((Get-Item $dcmtkZipPath).Length / 1MB)) MB"

    Write-Status "Extrag dcmtk..."
    $dcmtkTempDir = Join-Path $ToolsDir "dcmtk-temp"
    Expand-Archive -Path $dcmtkZipPath -DestinationPath $dcmtkTempDir -Force

    # ZIP contains a root folder like dcmtk-3.7.0-win64-dynamic/ -- move it
    $dcmtkRoot = Get-ChildItem -Path $dcmtkTempDir -Directory | Select-Object -First 1
    if ($dcmtkRoot) {
        if (Test-Path $DcmtkDir) { Remove-Item -Recurse -Force $DcmtkDir }
        Move-Item -Path $dcmtkRoot.FullName -Destination $DcmtkDir -Force
    }

    # Clean up
    Remove-Item -Path $dcmtkZipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $dcmtkTempDir -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path $dcmmkdirExe) {
        Write-Ok "dcmtk instalat (dcmmkdir.exe gasit)"
    } else {
        Write-Host "    [ATENTIE] dcmmkdir.exe nu a fost gasit dupa extractie." -ForegroundColor Yellow
        Write-Host "    DICOMDIR nu va fi generat - discul nu va fi recunoscut de statiile medicale." -ForegroundColor Yellow
    }
}

# ============================================================================
# Step 4: Verify everything
# ============================================================================

Write-Status "Verificare finala..."

$checks = @(
    @{ Path = (Join-Path $WeasisDir "weasis-launcher.jar"); Name = "weasis-launcher.jar" },
    @{ Path = (Join-Path $WeasisDir "felix.jar"); Name = "felix.jar (OSGI framework)" },
    @{ Path = (Join-Path $WeasisDir "conf\config.properties"); Name = "conf/config.properties" },
    @{ Path = (Join-Path $WeasisDir "bundle"); Name = "bundle/ folder" },
    @{ Path = (Join-Path $jreWindowsDir "bin\java.exe"); Name = "jre/windows/bin/java.exe (x86)" },
    @{ Path = (Join-Path $jreWindowsX64Dir "bin\java.exe"); Name = "jre/windows-x64/bin/java.exe (x64)" },
    @{ Path = (Join-Path $ToolsDir "webview2\Microsoft.Web.WebView2.Core.dll"); Name = "webview2/Core.dll (WebView2 SDK)" },
    @{ Path = (Join-Path $ToolsDir "webview2\Microsoft.Web.WebView2.Wpf.dll"); Name = "webview2/Wpf.dll (WebView2 SDK)" },
    @{ Path = (Join-Path $ToolsDir "webview2\WebView2Loader.dll"); Name = "webview2/WebView2Loader.dll (native)" },
    @{ Path = (Join-Path $ToolsDir "dcmtk\bin\dcmmkdir.exe"); Name = "dcmtk/bin/dcmmkdir.exe (DICOMDIR generator)" },
    @{ Path = (Join-Path $ProjectRoot "templates\autorun.inf"); Name = "templates/autorun.inf" },
    @{ Path = (Join-Path $ProjectRoot "templates\README.html"); Name = "templates/README.html" },
    @{ Path = (Join-Path $ProjectRoot "burn.bat"); Name = "burn.bat" }
)

$allGood = $true
foreach ($check in $checks) {
    if (Test-Path $check.Path) {
        Write-Ok $check.Name
    } else {
        Write-Host "    [LIPSA] $($check.Name)" -ForegroundColor Red
        $allGood = $false
    }
}

# Show total size of Weasis portable + JRE
$weasisSize = (Get-ChildItem -Path $WeasisDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$weasisSizeMB = [math]::Round($weasisSize / 1MB, 1)
Write-Host ""
Write-Host "    Dimensiune Weasis + JRE: $weasisSizeMB MB" -ForegroundColor White
Write-Host "    Spatiu ramas pe DVD pentru DICOM: $([math]::Round(4700 - $weasisSizeMB, 0)) MB" -ForegroundColor White

if ($allGood) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  SETUP COMPLET!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Poti folosi:" -ForegroundColor White
    Write-Host "    burn.bat       - Trage un ZIP peste el (sau: burn.bat cale\fisier.zip)" -ForegroundColor White
    Write-Host "    app\pacs-burner.bat - Aplicatia PACS Burner cu browser integrat" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  SETUP INCOMPLET - rezolva problemele de mai sus" -ForegroundColor Red
    Write-Host ""
}
