# ============================================================================
# DICOM DVD Burn Script - Weasis Portable
# ============================================================================
# Usage:
#   .\burn.ps1 -ZipPath "C:\Users\...\Downloads\patient.zip"
#   Or drag ZIP onto burn.bat
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ZipPath,
    [string]$DriveID = "",
    [int]$BurnSpeed = 4
)

$ErrorActionPreference = "Stop"

# --- Configuration ---
$ProjectRoot    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$WeasisDir      = Join-Path $ProjectRoot "tools\weasis-portable"
$TempRoot       = Join-Path $env:TEMP "WeasisBurn"
$DiscStaging    = Join-Path $TempRoot "disc"
$ContentDir     = Join-Path $DiscStaging "Weasis"     # subfolder on disc for all content
$TemplatesDir   = Join-Path $ProjectRoot "templates"
$DcmtkDir       = Join-Path $ProjectRoot "tools\dcmtk"
$script:burnSuccess = $false

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
    $launcherJar = Join-Path $WeasisDir "weasis-launcher.jar"
    $jreX86Path  = Join-Path $WeasisDir "jre\windows\bin\java.exe"
    $jreX64Path  = Join-Path $WeasisDir "jre\windows-x64\bin\java.exe"

    if (-not (Test-Path $launcherJar)) {
        Write-Err "weasis-launcher.jar nu a fost gasit!"
        Write-Host "    Ruleaza mai intai: setup.bat" -ForegroundColor Yellow
        exit 1
    }
    $hasX86 = Test-Path $jreX86Path
    $hasX64 = Test-Path $jreX64Path
    if (-not $hasX86 -and -not $hasX64) {
        Write-Err "Niciun JRE nu este instalat in Weasis portable!"
        Write-Host "    Ruleaza mai intai: setup.bat" -ForegroundColor Yellow
        exit 1
    }
    $jreList = @()
    if ($hasX86) { $jreList += "x86" }
    if ($hasX64) { $jreList += "x64" }
    Write-Ok "Weasis portable gasit cu JRE: $($jreList -join ' + ')"
}

function Clear-Staging {
    if (Test-Path $DiscStaging) {
        Remove-Item -Recurse -Force $DiscStaging
    }
    New-Item -ItemType Directory -Path $DiscStaging -Force | Out-Null
    New-Item -ItemType Directory -Path $ContentDir -Force | Out-Null
    Write-Ok "Folder staging creat: $DiscStaging (content in Weasis/)"
}

function Read-DicomPatientInfo {
    param([string]$FilePath)

    $result = @{ PatientName = ""; StudyDate = "" }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        if ($bytes.Length -lt 140) { return $result }

        # Verify DICM magic at offset 128
        $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 128, 4)
        if ($magic -ne "DICM") { return $result }

        $pos = 132  # Start after preamble + magic
        $maxPos = [Math]::Min($bytes.Length, 16384)  # Scan first 16 KB
        $longVRs = @("OB","OD","OF","OL","OW","SQ","UC","UN","UR","UT")

        while ($pos + 8 -le $maxPos) {
            # Read tag: group (2 LE) + element (2 LE)
            $group   = [BitConverter]::ToUInt16($bytes, $pos)
            $element = [BitConverter]::ToUInt16($bytes, $pos + 2)
            $pos += 4

            # Read VR (2 ASCII chars)
            $vr = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 2)
            $pos += 2

            # Determine value length
            if ($longVRs -contains $vr) {
                $pos += 2  # skip 2 reserved bytes
                if ($pos + 4 -gt $maxPos) { break }
                $valLen = [BitConverter]::ToUInt32($bytes, $pos)
                $pos += 4
            } else {
                if ($pos + 2 -gt $maxPos) { break }
                $valLen = [BitConverter]::ToUInt16($bytes, $pos)
                $pos += 2
            }

            # Undefined length (0xFFFFFFFF) -- skip (sequence)
            if ($valLen -eq 0xFFFFFFFF -or $valLen -lt 0) { break }

            $valStart = $pos
            $pos += $valLen

            if ($pos -gt $maxPos) { break }

            # Extract target tags
            if ($group -eq 0x0008 -and $element -eq 0x0020 -and $valLen -gt 0) {
                # StudyDate (DA): YYYYMMDD
                $result.StudyDate = [System.Text.Encoding]::ASCII.GetString($bytes, $valStart, $valLen).Trim()
            }
            elseif ($group -eq 0x0010 -and $element -eq 0x0010 -and $valLen -gt 0) {
                # PatientName (PN): FAMILY^GIVEN^MIDDLE^PREFIX^SUFFIX
                $result.PatientName = [System.Text.Encoding]::ASCII.GetString($bytes, $valStart, $valLen).Trim()
            }

            # Stop early if both found
            if ($result.PatientName -and $result.StudyDate) { break }

            # Stop scanning after group 0x0010 (tags are in order)
            if ($group -gt 0x0010) { break }
        }
    } catch {
        # Silent fail -- fallback to generic label
    }
    return $result
}

function Format-DiscLabel {
    param([string]$PatientName, [string]$StudyDate)

    $name = ""
    $date = ""

    # Format patient name: FAMILY^GIVEN -> FAMILY GIVEN
    if ($PatientName) {
        $name = ($PatientName -replace '\^', ' ').Trim()
        $name = $name.ToUpper()
    }

    # Format study date: YYYYMMDD -> DD/MM/YYYY
    if ($StudyDate -and $StudyDate.Length -ge 8) {
        $yyyy = $StudyDate.Substring(0, 4)
        $mm   = $StudyDate.Substring(4, 2)
        $dd   = $StudyDate.Substring(6, 2)
        $date = "$dd/$mm/$yyyy"
    }

    if ($name -and $date) {
        $label = "$name $date"
    } elseif ($name) {
        $label = $name
    } else {
        $label = "Weasis DICOM"
    }

    # Truncate to 32 chars (ISO 9660 safe)
    if ($label.Length -gt 32) {
        $label = $label.Substring(0, 32).Trim()
    }

    return $label
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

    # Step 3: Copy DICOM files to Weasis/ subfolder on disc
    if ($dicomSourceRoot) {
        # Found a DICOM folder - copy it as-is to content dir
        $destDicom = Join-Path $ContentDir (Split-Path -Leaf $dicomSourceRoot)
        Copy-Item -Path $dicomSourceRoot -Destination $destDicom -Recurse -Force
        Write-Ok "Copiat folderul $(Split-Path -Leaf $dicomSourceRoot)/ ($($allDcmFiles.Count) fisiere)"
    } else {
        # No DICOM parent folder - create one and copy files preserving structure
        $dicomDir = Join-Path $ContentDir "DICOM"
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
    # (e.g. viewer-mac.app\Contents\DICOM\...) that don't match our disc layout.
    # A new DICOMDIR will be generated by dcmmkdir with correct paths (step 8).
    Write-Ok "DICOMDIR din ZIP omis (cai incompatibile). Se va genera unul nou."

    # Count final DICOM files (with .dcm extension OR extensionless)
    $finalDcm = (Get-ChildItem -Path $ContentDir -Recurse -File |
        Where-Object { $_.Extension -match "^\.(dcm|DCM)$" -or $_.Extension -eq "" }).Count
    Write-Ok "Fisiere pe disc: $finalDcm (DICOM + auxiliare)"
}

function Copy-WeasisToStaging {
    Write-Status "Copiez Weasis portable pe disc..."

    # Folders/files to exclude from DVD (not needed for Windows target / replaced by our templates)
    $excludeNames = @("viewer-mac.app", "autorun.inf", "viewer-win32.exe")

    # Copy weasis-portable contents to Weasis/ subfolder, excluding macOS app bundle
    $items = Get-ChildItem -Path $WeasisDir
    foreach ($item in $items) {
        if ($excludeNames -contains $item.Name) { continue }
        $destPath = Join-Path $ContentDir $item.Name
        if ($item.PSIsContainer) {
            Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
        } else {
            Copy-Item -Path $item.FullName -Destination $destPath -Force
        }
    }

    # Report which JREs are included
    $jreInfo = @()
    if (Test-Path (Join-Path $ContentDir "jre\windows\bin\java.exe")) { $jreInfo += "x86" }
    if (Test-Path (Join-Path $ContentDir "jre\windows-x64\bin\java.exe")) { $jreInfo += "x64" }
    Write-Ok "Weasis portable copiat (JRE: $($jreInfo -join ' + '))"
}

function Copy-TemplatesToStaging {
    Write-Status "Copiez templates..."

    # autorun.inf goes to disc root (Windows reads it from root only)
    Copy-Item -Path (Join-Path $TemplatesDir "autorun.inf") -Destination $DiscStaging -Force

    # Everything else goes into Weasis/ subfolder
    Copy-Item -Path (Join-Path $TemplatesDir "start-weasis.bat") -Destination $ContentDir -Force
    Copy-Item -Path (Join-Path $TemplatesDir "splash-loader.ps1") -Destination $ContentDir -Force
    Copy-Item -Path (Join-Path $TemplatesDir "README.html") -Destination $ContentDir -Force

    Write-Ok "autorun.inf (root), start-weasis.bat + splash-loader.ps1 + README.html (Weasis/)"
}

function Build-LauncherWrapper {
    Write-Status "Creez launcher pe disc..."

    # Copy weasis.ico into Weasis/ subfolder (used by autorun.inf for disc icon)
    $iconSrc = Join-Path $TemplatesDir "weasis.ico"
    if (Test-Path $iconSrc) {
        Copy-Item $iconSrc -Destination $ContentDir -Force
        Write-Ok "weasis.ico copiat in Weasis/"
    }

    # Copy .bat wrapper to disc root (backup/fallback launcher)
    $wrapperSrc = Join-Path $TemplatesDir "Weasis Viewer.bat"
    if (Test-Path $wrapperSrc) {
        Copy-Item $wrapperSrc -Destination $DiscStaging -Force
        Write-Ok "'Weasis Viewer.bat' copiat la root (backup)"
    }

    # Create shortcut (.lnk) at disc root
    # Target: cmd.exe (fixed system path, always exists on any Windows)
    # Arguments: relative path to start-weasis.bat (resolved from DVD root)
    # NOTE: IconLocation intentionally NOT set. Windows .lnk requires absolute path
    # to an existing file on the local HDD for icon resolution. On DVD with unknown
    # drive letter, no absolute path works. Tested: relative paths, ExtraData patching,
    # ExtraData removal -- none work on optical/mounted media. Disc icon is set via
    # autorun.inf (icon=Weasis\weasis.ico) which DOES work.
    $lnkPath = Join-Path $DiscStaging "Weasis Viewer.lnk"
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = "$env:SystemRoot\System32\cmd.exe"
        $shortcut.Arguments = '/c "Weasis\start-weasis.bat"'
        $shortcut.WorkingDirectory = ""
        $shortcut.WindowStyle = 7  # Minimized (hide cmd flash)
        $shortcut.Description = "Weasis DICOM Viewer"
        $shortcut.Save()

        if (Test-Path $lnkPath) {
            Write-Ok "'Weasis Viewer.lnk' creat (cmd.exe -> Weasis\start-weasis.bat)"
        } else {
            Write-Err "Nu s-a putut crea shortcut-ul"
        }
    } catch {
        Write-Err "Eroare la crearea shortcut-ului: $($_.Exception.Message)"
        Write-Host "    'Weasis Viewer.bat' este disponibil ca alternativa." -ForegroundColor Yellow
    }
}

function Generate-Dicomdir {
    Write-Status "Generez DICOMDIR (index pentru statii medicale)..."

    $dcmmkdir = Join-Path $DcmtkDir "bin\dcmmkdir.exe"
    if (-not (Test-Path $dcmmkdir)) {
        Write-Host "    [ATENTIE] dcmmkdir.exe nu a fost gasit!" -ForegroundColor Yellow
        Write-Host "    Ruleaza setup.bat pentru a descarca dcmtk." -ForegroundColor Yellow
        Write-Host "    Discul va functiona cu Weasis, dar NU va fi recunoscut de statiile medicale (Siemens, GE etc.)." -ForegroundColor Yellow
        return
    }

    # Verify DICOM files exist in staging
    $dicomDir = Join-Path $ContentDir "DICOM"
    if (-not (Test-Path $dicomDir)) {
        Write-Host "    [ATENTIE] Folderul DICOM nu exista in staging. Nu pot genera DICOMDIR." -ForegroundColor Yellow
        return
    }

    # Set DICOM dictionary path (needed by dcmtk to parse tags)
    $dictPath = Join-Path $DcmtkDir "share\dcmtk\dicom.dic"
    if (Test-Path $dictPath) {
        $env:DCMDICTPATH = $dictPath
    }

    # dcmmkdir MUST run from disc root -- DICOMDIR stores paths relative to itself
    # Result: DICOMDIR at disc root with paths like WEASIS\DICOM\DIR000\filename
    Push-Location $DiscStaging
    try {
        # +r = recurse, +id = input directory, +D = output file, +I = invent missing attrs, -Pgp = General Purpose profile
        $dcmArgs = @("+r", "+id", "Weasis\DICOM", "+D", "DICOMDIR", "+I", "-Pgp")
        $output = & $dcmmkdir @dcmArgs 2>&1

        $dicomdirPath = Join-Path $DiscStaging "DICOMDIR"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dicomdirPath)) {
            $dicomdirSize = (Get-Item $dicomdirPath).Length
            Write-Ok "DICOMDIR generat ($([math]::Round($dicomdirSize / 1KB)) KB) - statiile medicale vor recunoaste discul"
        } else {
            Write-Host "    [ATENTIE] dcmmkdir a esuat (cod: $LASTEXITCODE)" -ForegroundColor Yellow
            if ($output) {
                $output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
            }
            Write-Host "    Discul va functiona cu Weasis, dar poate nu cu statiile medicale." -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }
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

    # If DriveID provided (from GUI settings), use it directly
    if ($DriveID) {
        foreach ($d in $drives) {
            if ($d.ID -eq $DriveID) {
                Write-Ok "DVD Writer (selectat din setari): $($d.Vendor) $($d.Product) ($($d.Letter))"
                return $d
            }
        }
        Write-Host "    Drive-ul salvat in setari nu mai este disponibil, caut altul..." -ForegroundColor Yellow
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
        $fsImage.VolumeName = if ($script:discLabel) { $script:discLabel } else { "Weasis DICOM" }

        # Set media capacity from actual disc (critical! default is CD-sized ~700 MB)
        $fsImage.FreeMediaBlocks = $discFormat.TotalSectorsOnMedia
        Write-Host "    Capacitate disc: $([math]::Round($discFormat.TotalSectorsOnMedia * 2048 / 1MB)) MB" -ForegroundColor Gray

        # Add all files from staging
        Write-Host "    Adaug fisierele pe disc..." -ForegroundColor Gray
        $fsImage.Root.AddTree($DiscStaging, $false)

        # Create result stream
        Write-Host "    Generez imaginea ISO..." -ForegroundColor Gray
        $result = $fsImage.CreateResultImage()
        $stream = $result.ImageStream

        # Set burn speed (1x DVD = 1385 KB/s)
        $speedKBs = $BurnSpeed * 1385
        Write-Host "    Viteza: ${BurnSpeed}x ($speedKBs KB/s)" -ForegroundColor Gray
        try {
            $discFormat.SetWriteSpeed($speedKBs, $false)
        } catch {
            Write-Host "    Nu am putut seta viteza ${BurnSpeed}x, folosesc viteza implicita." -ForegroundColor Yellow
        }

        # Burn!
        Write-Host "    Ard discul... aceasta poate dura cateva minute." -ForegroundColor Yellow
        $discFormat.Write($stream)

        # Eject
        $recorder.EjectMedia()

        Write-Ok "DISC ARDS CU SUCCES!"
        $script:burnSuccess = $true
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

    # Delete source ZIP after successful burn
    if ($script:burnSuccess -and (Test-Path $ZipPath)) {
        try {
            Remove-Item -Force $ZipPath
            Write-Ok "ZIP-ul sters: $(Split-Path -Leaf $ZipPath)"
        } catch {
            Write-Host "    Nu am putut sterge ZIP-ul: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================

# Step 1: Verify Weasis is set up
Test-WeasisPortable

# Step 2: Clean staging area
Clear-Staging

# Step 3: Extract ZIP
$extractedDir = Expand-PatientZip -Zip $ZipPath

# Step 4: Copy DICOM files to staging with proper structure
Copy-DicomToStaging -ExtractedDir $extractedDir

# Step 4b: Extract patient info from DICOM for disc label
$script:discLabel = "Weasis DICOM"
$dicomSearchDir = Join-Path $ContentDir "DICOM"
if (-not (Test-Path $dicomSearchDir)) {
    # Try other common DICOM folder names
    $dicomSearchDir = Get-ChildItem -Path $ContentDir -Directory | Where-Object {
        $_.Name -match "^(DICOM|dicom|IMAGES|images)$"
    } | Select-Object -First 1 -ExpandProperty FullName
}
if ($dicomSearchDir) {
    # Find DICOM files: with .dcm extension OR extensionless with DICM magic bytes
    $allDcmForLabel = @()
    Get-ChildItem -Path $dicomSearchDir -Recurse -File | ForEach-Object {
        if ($_.Extension -match "^\.(dcm|DCM)$") {
            $allDcmForLabel += $_
        } elseif ($_.Extension -eq "" -and $_.Length -gt 132) {
            try {
                $buf = New-Object byte[] 132
                $fs = [System.IO.File]::OpenRead($_.FullName)
                $fs.Read($buf, 0, 132) | Out-Null
                $fs.Close()
                if ([System.Text.Encoding]::ASCII.GetString($buf, 128, 4) -eq "DICM") {
                    $allDcmForLabel += $_
                }
            } catch {}
        }
        # Stop after finding enough files from different folders
        if ($allDcmForLabel.Count -ge 50) { return }
    }
}
if ($allDcmForLabel -and $allDcmForLabel.Count -gt 0) {
    # Collect unique patients (by PatientName) - check files from different folders
    $uniquePatients = @{}
    $foldersChecked = @{}
    foreach ($dcmFile in $allDcmForLabel) {
        $folder = $dcmFile.DirectoryName
        if ($foldersChecked.ContainsKey($folder)) { continue }
        $foldersChecked[$folder] = $true
        $info = Read-DicomPatientInfo -FilePath $dcmFile.FullName
        if ($info.PatientName) {
            $key = $info.PatientName.ToUpper().Trim()
            if (-not $uniquePatients.ContainsKey($key)) {
                $uniquePatients[$key] = $info
            }
        }
        if ($uniquePatients.Count -gt 1) { break }  # no need to check more
        if ($foldersChecked.Count -ge 20) { break }
    }

    if ($uniquePatients.Count -gt 1) {
        $script:discLabel = "Multiple"
        Write-Ok "Nume disc: Multiple ($($uniquePatients.Count) pacienti)"
    } elseif ($uniquePatients.Count -eq 1) {
        $info = $uniquePatients.Values | Select-Object -First 1
        $script:discLabel = Format-DiscLabel -PatientName $info.PatientName -StudyDate $info.StudyDate
        Write-Ok "Nume disc: $($script:discLabel)"
    } else {
        Write-Host "    Nu am putut citi info pacient din DICOM. Folosesc nume generic." -ForegroundColor Yellow
    }
} else {
    Write-Host "    Nu am gasit fisiere DICOM -- folosesc nume generic." -ForegroundColor Yellow
}

# Step 5: Copy Weasis portable with JRE
Copy-WeasisToStaging

# Step 6: Copy templates (autorun, readme)
Copy-TemplatesToStaging

# Step 7: Copy launcher wrapper bat + icon
Build-LauncherWrapper

# Step 8: Generate DICOMDIR (required for medical workstations)
Generate-Dicomdir

# Step 9: Show summary
Show-DiscSummary

# Step 10: Confirm and burn
Write-Host ""
$confirm = Read-Host "Vrei sa arzi pe DVD-R acum? (da/nu)"
if ($confirm -eq "da" -or $confirm -eq "d" -or $confirm -eq "y" -or $confirm -eq "yes") {
    Burn-ToDisc
} else {
    Write-Host ""
    Write-Host "    Fisierele pregatite sunt in: $DiscStaging" -ForegroundColor Yellow
    Write-Host "    Poti arde manual mai tarziu." -ForegroundColor Yellow
}

# Step 11: Cleanup
Cleanup

Write-Host ""
Write-Host "GATA!" -ForegroundColor Green
Write-Host ""
