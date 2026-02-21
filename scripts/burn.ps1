# ============================================================================
# DICOM DVD Burn Script - Weasis Portable
# ============================================================================
# Usage:
#   .\burn.ps1 -ZipPath "C:\Users\...\Downloads\patient.zip"
#   Or drag ZIP onto burn.bat
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ZipPath
)

$ErrorActionPreference = "Stop"

# --- Configuration ---
$ProjectRoot    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$WeasisDir      = Join-Path $ProjectRoot "tools\weasis-portable"
$TempRoot       = Join-Path $env:TEMP "WeasisBurn"
$DiscStaging    = Join-Path $TempRoot "disc"
$TemplatesDir   = Join-Path $ProjectRoot "templates"
$BurnSpeed      = 4  # slower = more compatible and reliable

# --- Functions ---
function Write-Status($msg) {
    Write-Host ""
    Write-Host ">>> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Err($msg) {
    Write-Host "    [EROARE] $msg" -ForegroundColor Red
}

function Test-WeasisPortable {
    $viewerExe  = Join-Path $WeasisDir "viewer-win32.exe"
    $launcherJar = Join-Path $WeasisDir "weasis-launcher.jar"
    $jrePath    = Join-Path $WeasisDir "jre\windows\bin\java.exe"

    if (-not (Test-Path $viewerExe)) {
        Write-Err "viewer-win32.exe nu a fost gasit!"
        Write-Host "    Ruleaza mai intai: setup.bat" -ForegroundColor Yellow
        exit 1
    }
    if (-not (Test-Path $launcherJar)) {
        Write-Err "weasis-launcher.jar nu a fost gasit!"
        Write-Host "    Ruleaza mai intai: setup.bat" -ForegroundColor Yellow
        exit 1
    }
    if (-not (Test-Path $jrePath)) {
        Write-Err "JRE nu este instalat in Weasis portable!"
        Write-Host "    Ruleaza mai intai: setup.bat" -ForegroundColor Yellow
        exit 1
    }
    Write-Ok "Weasis portable gasit cu JRE bundled"
}

function Clear-Staging {
    if (Test-Path $DiscStaging) {
        Remove-Item -Recurse -Force $DiscStaging
    }
    New-Item -ItemType Directory -Path $DiscStaging -Force | Out-Null
    Write-Ok "Folder staging creat: $DiscStaging"
}

function Expand-PatientZip {
    param([string]$Zip)

    if (-not (Test-Path $Zip)) {
        Write-Err "Fisierul ZIP nu exista: $Zip"
        exit 1
    }

    $extractDir = Join-Path $TempRoot "extracted"
    if (Test-Path $extractDir) {
        Remove-Item -Recurse -Force $extractDir
    }

    Write-Status "Extrag ZIP-ul: $(Split-Path -Leaf $Zip)"
    Expand-Archive -Path $Zip -DestinationPath $extractDir -Force
    Write-Ok "ZIP extras in: $extractDir"

    return $extractDir
}

function Find-DicomFiles {
    param([string]$SearchDir)

    # Find DICOM files (.dcm or files without extension that might be DICOM)
    $dcmFiles = Get-ChildItem -Path $SearchDir -Recurse -File | Where-Object {
        $_.Extension -eq ".dcm" -or
        $_.Extension -eq "" -or
        $_.Extension -eq ".DCM"
    }

    # Filter: check if files without extension are actually DICOM (magic bytes "DICM" at offset 128)
    $validDicom = @()
    foreach ($f in $dcmFiles) {
        if ($f.Extension -eq ".dcm" -or $f.Extension -eq ".DCM") {
            $validDicom += $f
        } elseif ($f.Extension -eq "" -and $f.Length -gt 132) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                if ($bytes.Length -gt 132) {
                    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 128, 4)
                    if ($magic -eq "DICM") {
                        $validDicom += $f
                    }
                }
            } catch {}
        }
    }

    Write-Ok "Gasite $($validDicom.Count) fisiere DICOM"
    return $validDicom
}

function Copy-DicomToStaging {
    param([string]$ExtractedDir)

    Write-Status "Organizez fisierele DICOM pe disc..."

    # Step 1: Find ALL .DCM files anywhere in the extracted ZIP
    $allDcmFiles = Get-ChildItem -Path $ExtractedDir -Recurse -File | Where-Object {
        $_.Extension -match "^\.(dcm|DCM)$"
    }

    if ($allDcmFiles.Count -eq 0) {
        # Try finding DICOM files without extension (check magic bytes)
        $allDcmFiles = Find-DicomFiles -SearchDir $ExtractedDir
    }

    if ($allDcmFiles.Count -eq 0) {
        Write-Err "Nu am gasit fisiere DICOM in ZIP!"
        exit 1
    }

    Write-Ok "Gasite $($allDcmFiles.Count) fisiere DICOM in ZIP"

    # Step 2: Find the DICOM root folder (the folder named DICOM that contains the DCMs)
    $firstDcm = $allDcmFiles[0]
    $dicomParent = $firstDcm.DirectoryName
    # Walk up until we find a folder named DICOM (or the root)
    $dicomSourceRoot = $null
    $checkPath = $dicomParent
    while ($checkPath -and $checkPath.Length -gt $ExtractedDir.Length) {
        if ((Split-Path -Leaf $checkPath) -match "^(DICOM|dicom|IMAGES|images)$") {
            $dicomSourceRoot = $checkPath
            break
        }
        $checkPath = Split-Path -Parent $checkPath
    }

    # Step 3: Copy DICOM files to staging
    if ($dicomSourceRoot) {
        # Found a DICOM folder - copy it as-is to staging
        $destDicom = Join-Path $DiscStaging (Split-Path -Leaf $dicomSourceRoot)
        Copy-Item -Path $dicomSourceRoot -Destination $destDicom -Recurse -Force
        Write-Ok "Copiat folderul $(Split-Path -Leaf $dicomSourceRoot)/ ($($allDcmFiles.Count) fisiere)"
    } else {
        # No DICOM parent folder - create one and copy files preserving structure
        $dicomDir = Join-Path $DiscStaging "DICOM"
        New-Item -ItemType Directory -Path $dicomDir -Force | Out-Null
        foreach ($f in $allDcmFiles) {
            $relPath = $f.FullName.Substring($ExtractedDir.Length).TrimStart('\', '/')
            $destPath = Join-Path $dicomDir $relPath
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -Path $f.FullName -Destination $destPath -Force
        }
        Write-Ok "Copiat $($allDcmFiles.Count) fisiere in DICOM/"
    }

    # Step 4: Skip DICOMDIR from PACS ZIP - it contains original paths
    # (e.g. viewer-mac.app\Contents\DICOM\...) that don't match our flat disc layout.
    # Without DICOMDIR, Weasis uses LoadLocalDicom to scan DICOM/ directly.
    Write-Ok "DICOMDIR din ZIP omis (cai incompatibile). Weasis va scana DICOM/ direct."

    # Count final files
    $finalDcm = (Get-ChildItem -Path $DiscStaging -Recurse -File |
        Where-Object { $_.Extension -match "^\.(dcm|DCM)$" }).Count
    Write-Ok "Fisiere DICOM pe disc: $finalDcm"
}

function Copy-WeasisToStaging {
    Write-Status "Copiez Weasis portable pe disc..."

    # Folders/files to exclude from DVD (not needed for Windows target)
    $excludeNames = @("viewer-mac.app", "autorun.inf")

    # Copy weasis-portable contents to staging, excluding macOS app bundle
    $items = Get-ChildItem -Path $WeasisDir
    foreach ($item in $items) {
        if ($excludeNames -contains $item.Name) { continue }
        $destPath = Join-Path $DiscStaging $item.Name
        if ($item.PSIsContainer) {
            Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
        } else {
            Copy-Item -Path $item.FullName -Destination $destPath -Force
        }
    }

    Write-Ok "Weasis portable copiat (cu JRE bundled)"
}

function Copy-TemplatesToStaging {
    Write-Status "Copiez autorun.inf, start-weasis.bat si README..."

    Copy-Item -Path (Join-Path $TemplatesDir "autorun.inf") -Destination $DiscStaging -Force
    Copy-Item -Path (Join-Path $TemplatesDir "start-weasis.bat") -Destination $DiscStaging -Force
    Copy-Item -Path (Join-Path $TemplatesDir "README.html") -Destination $DiscStaging -Force

    Write-Ok "autorun.inf si README.html copiate"
}

function Show-DiscSummary {
    Write-Status "Sumar disc:"

    $totalSize = (Get-ChildItem -Path $DiscStaging -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 1)
    $dvdCapacity = 4700  # MB approximate

    Write-Host "    Dimensiune totala: $totalSizeMB MB" -ForegroundColor White

    if ($totalSizeMB -gt $dvdCapacity) {
        Write-Err "ATENTIE: Depaseste capacitatea DVD-R (4.7 GB)!"
        Write-Host "    Ai nevoie de DVD-R DL sau de a reduce studiul." -ForegroundColor Yellow
        exit 1
    }

    $percentage = [math]::Round(($totalSizeMB / $dvdCapacity) * 100, 1)
    Write-Host "    Utilizare DVD: $percentage%" -ForegroundColor White

    Write-Host ""
    Write-Host "    Structura disc:" -ForegroundColor White
    Get-ChildItem -Path $DiscStaging -Depth 0 | ForEach-Object {
        if ($_.PSIsContainer) {
            $dirSize = (Get-ChildItem -Path $_.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum
            $dirSizeMB = [math]::Round($dirSize / 1MB, 1)
            Write-Host "      [$dirSizeMB MB] $($_.Name)/" -ForegroundColor Gray
        } else {
            Write-Host "      $($_.Name)" -ForegroundColor Gray
        }
    }
}

function Select-OpticalDrive {
    $discMaster = New-Object -ComObject IMAPI2.MsftDiscMaster2

    if ($discMaster.Count -eq 0) {
        Write-Err "Nu am gasit nicio unitate optica!"
        Write-Host "    Conecteaza un DVD Writer si incearca din nou." -ForegroundColor Yellow
        exit 1
    }

    # Gather info about all drives
    $drives = @()
    for ($i = 0; $i -lt $discMaster.Count; $i++) {
        $rec = New-Object -ComObject IMAPI2.MsftDiscRecorder2
        $rec.InitializeDiscRecorder($discMaster.Item($i))
        $drives += @{
            Index      = $i
            ID         = $discMaster.Item($i)
            Recorder   = $rec
            Letter     = ($rec.VolumePathNames | Select-Object -First 1)
            Vendor     = $rec.VendorId.Trim()
            Product    = $rec.ProductId.Trim()
        }
    }

    if ($drives.Count -eq 1) {
        # Only one drive - use it automatically
        $sel = $drives[0]
        Write-Ok "DVD Writer: $($sel.Vendor) $($sel.Product) ($($sel.Letter))"
        return $sel
    }

    # Multiple drives - let user choose
    Write-Host ""
    Write-Host "    Unitati optice gasite:" -ForegroundColor White
    foreach ($d in $drives) {
        Write-Host "      [$($d.Index + 1)] $($d.Vendor) $($d.Product) ($($d.Letter))" -ForegroundColor Gray
    }
    Write-Host ""

    do {
        $choice = Read-Host "    Alege unitatea (1-$($drives.Count))"
        $choiceNum = 0
        $valid = [int]::TryParse($choice, [ref]$choiceNum) -and $choiceNum -ge 1 -and $choiceNum -le $drives.Count
        if (-not $valid) {
            Write-Host "    Introdu un numar intre 1 si $($drives.Count)" -ForegroundColor Yellow
        }
    } while (-not $valid)

    $sel = $drives[$choiceNum - 1]
    Write-Ok "Selectat: $($sel.Vendor) $($sel.Product) ($($sel.Letter))"
    return $sel
}

function Burn-ToDisc {
    Write-Status "Pregatesc arderea pe DVD-R..."

    # Select optical drive (auto if only one, prompt if multiple)
    $selectedDrive = Select-OpticalDrive
    $recorder = $selectedDrive.Recorder

    # Prompt user to insert disc
    Write-Host ""
    Write-Host "    Introdu un DVD-R gol in $($selectedDrive.Letter) si apasa ENTER..." -ForegroundColor Yellow
    Read-Host

    # Use IMAPI2 COM for burning
    Write-Status "Ardere in curs... (nu scoate discul!)"

    try {

        # Create disc format
        $discFormat = New-Object -ComObject IMAPI2.MsftDiscFormat2Data
        $discFormat.Recorder = $recorder
        $discFormat.ClientName = "WeasisBurn"

        # Check if media is blank
        if (-not $discFormat.CurrentMediaStatus) {
            Write-Err "Discul nu este gol sau nu este inserat corect."
            exit 1
        }

        # Create file system image - ISO 9660 + Joliet (critical for compatibility!)
        $fsImage = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsImage.FileSystemsToCreate = 3  # FsiFileSystemJoliet (2) + FsiFileSystemISO9660 (1) = 3
        $fsImage.VolumeName = "DICOM"

        # Add all files from staging
        Write-Host "    Adaug fisierele pe disc..." -ForegroundColor Gray
        $fsImage.Root.AddTree($DiscStaging, $false)

        # Create result stream
        Write-Host "    Generez imaginea ISO..." -ForegroundColor Gray
        $result = $fsImage.CreateResultImage()
        $stream = $result.ImageStream

        # Set burn speed (slower = more reliable for medical data)
        # Speed values: 1x DVD = 1385 KB/s
        # We use 4x = 5540 sectors/second for reliability
        try {
            $discFormat.SetWriteSpeed(5540, $false)
        } catch {
            Write-Host "    Nu am putut seta viteza, folosesc viteza implicita." -ForegroundColor Yellow
        }

        # Burn!
        Write-Host "    Ard discul... aceasta poate dura cateva minute." -ForegroundColor Yellow
        $discFormat.Write($stream)

        # Eject
        $recorder.EjectMedia()

        Write-Ok "DISC ARDS CU SUCCES!"
        Write-Host ""
        Write-Host "    Discul a fost ejectat. Poti sa-l folosesti." -ForegroundColor Green

    } catch {
        Write-Err "Eroare la ardere: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "    Posibile cauze:" -ForegroundColor Yellow
        Write-Host "      - Discul nu este gol (DVD-R se poate scrie o singura data)" -ForegroundColor Yellow
        Write-Host "      - Unitatea optica nu este conectata corect" -ForegroundColor Yellow
        Write-Host "      - DVD-R-ul este deteriorat" -ForegroundColor Yellow
        exit 1
    }
}

function Cleanup {
    Write-Status "Curatare fisiere temporare..."
    if (Test-Path $TempRoot) {
        # Wait briefly for IMAPI2 to release file locks
        Start-Sleep -Seconds 2
        try {
            Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
        } catch {}
        # If some files are still locked, try once more
        if (Test-Path $TempRoot) {
            Start-Sleep -Seconds 3
            Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Curat"
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  DICOM DVD Burn - Weasis Portable" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Verify Weasis is set up
Test-WeasisPortable

# Step 2: Clean staging area
Clear-Staging

# Step 3: Extract ZIP
$extractedDir = Expand-PatientZip -Zip $ZipPath

# Step 4: Copy DICOM files to staging with proper structure
Copy-DicomToStaging -ExtractedDir $extractedDir

# Step 5: Copy Weasis portable with JRE
Copy-WeasisToStaging

# Step 6: Copy templates (autorun, readme)
Copy-TemplatesToStaging

# Step 7: Show summary
Show-DiscSummary

# Step 8: Confirm and burn
Write-Host ""
$confirm = Read-Host "Vrei sa arzi pe DVD-R acum? (da/nu)"
if ($confirm -eq "da" -or $confirm -eq "d" -or $confirm -eq "y" -or $confirm -eq "yes") {
    Burn-ToDisc
} else {
    Write-Host ""
    Write-Host "    Fisierele pregatite sunt in: $DiscStaging" -ForegroundColor Yellow
    Write-Host "    Poti arde manual mai tarziu." -ForegroundColor Yellow
}

# Step 9: Cleanup
Cleanup

Write-Host ""
Write-Host "GATA!" -ForegroundColor Green
Write-Host ""
