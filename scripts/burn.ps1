# ============================================================================
# DICOM DVD Burn Script - Weasis Portable
# Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
# Unauthorized copying, modification, or distribution is strictly prohibited.
# ============================================================================
# Usage:
#   .\burn.ps1 -ZipPath "C:\Users\...\Downloads\patient.zip"
#   Or drag ZIP onto burn.bat
# ============================================================================

param(
    [string]$ZipPath = "",
    [string]$DicomFolder = "",
    [string]$DriveID = "",
    [int]$BurnSpeed = 4,
    [switch]$AutoConfirm,
    [switch]$SimulateOnly
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
# Internal integrity token (do not modify)
$script:_ivalid = "Q29weXJpZ2h0IDIwMjYgQmVqZW5hcnUgQWRyaWFu"
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

function Add-DefenderExclusion {
    # Exclude staging dir from Windows Defender real-time scanning (permanent).
    # Without this, Antimalware Service Executable (MsMpEngine) scans every file
    # during ZIP extraction, causing 100% CPU on large DICOM archives.
    # Exclusion is permanent for %TEMP%\WeasisBurn — harmless, app-specific path.
    # On non-admin accounts: self-elevates via UAC (user enters admin password once).

    # 1. Check if exclusion already exists (no admin needed for Get-MpPreference)
    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        if ($prefs.ExclusionPath -and ($prefs.ExclusionPath -contains $TempRoot)) {
            Write-Ok "Windows Defender: excludere deja configurata"
            return
        }
    } catch {
        # 0x800106ba = Defender service not running / disabled — no exclusion needed
        Write-Ok "Windows Defender: serviciul nu ruleaza — excludere nu e necesara"
        return
    }

    # 2. Add exclusion — directly if admin, or self-elevate via UAC
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        try {
            Add-MpPreference -ExclusionPath $TempRoot -ErrorAction Stop
            Write-Ok "Windows Defender: excludere adaugata pentru $TempRoot"
        } catch {}
    } else {
        Write-Host "    [!] Se solicita drepturi admin pentru excludere Defender..." -ForegroundColor Yellow
        Write-Host "    [!] Introduceti parola de administrator in fereastra UAC" -ForegroundColor Yellow
        try {
            $cmd = "Add-MpPreference -ExclusionPath '$TempRoot'"
            $proc = Start-Process powershell -Verb RunAs `
                -ArgumentList "-NoProfile","-Command",$cmd `
                -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                Write-Ok "Windows Defender: excludere adaugata pentru $TempRoot"
            } else {
                Write-Host "    [!] Excluderea Defender nu a reusit (cod: $($proc.ExitCode))" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "    [!] UAC refuzat — Defender va scana fisierele la extragere (CPU ridicat)" -ForegroundColor Yellow
        }
    }
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
        # CRITICAL: remove junctions BEFORE recursive delete!
        # Previous failed burn may have left junctions to tools/weasis-portable/
        # Remove-Item -Recurse follows junctions and deletes SOURCE files
        try {
            Get-ChildItem -Path $DiscStaging -Recurse -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
                ForEach-Object { cmd /c "rmdir `"$($_.FullName)`"" 2>$null }
        } catch {}
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
    # .NET ZipFile is 2-3x faster than PowerShell's Expand-Archive
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $extractDir)
    } catch {
        # Fallback to Expand-Archive if .NET method fails
        Expand-Archive -Path $Zip -DestinationPath $extractDir -Force
    }
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

    # Step 1: Find ALL DICOM files anywhere in the extracted ZIP
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

    # Step 2: Check if PACS DICOMDIR exists and can be used directly
    # "Exclude Viewer" ZIPs have DICOMDIR + DIR000/ at root — paths match disc root layout
    $pacsDicomdir = Join-Path $ExtractedDir "DICOMDIR"
    $script:usePacsDicomdir = $false
    $script:dicomRootFolders = @()   # folder names copied to disc root (e.g. "DIR000")

    if (Test-Path $pacsDicomdir) {
        # Find top-level directories in extracted ZIP that contain DICOM files
        $topDirsWithDcm = @()
        $extractedTopDirs = Get-ChildItem -Path $ExtractedDir -Directory
        foreach ($d in $extractedTopDirs) {
            $hasDcm = Get-ChildItem -Path $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -match "^\.(dcm|DCM)$"
            } | Select-Object -First 1
            if ($hasDcm) { $topDirsWithDcm += $d }
        }

        if ($topDirsWithDcm.Count -gt 0) {
            # PACS DICOMDIR usable: DICOM dirs are at ZIP root level (paths match)
            $script:usePacsDicomdir = $true

            # Link each DICOM directory to disc root via junction (e.g. DIR000/ -> disc\DIR000\)
            # DICOM files are NOT modified for PACS path — junction is safe.
            foreach ($d in $topDirsWithDcm) {
                $dest = Join-Path $DiscStaging $d.Name
                $null = cmd /c "mklink /J `"$dest`" `"$($d.FullName)`"" 2>&1
                if (-not (Test-Path $dest)) {
                    # Fallback: normal copy if junction fails
                    Copy-Item -Path $d.FullName -Destination $dest -Recurse -Force
                }
                $script:dicomRootFolders += $d.Name
                $dirCount = (Get-ChildItem -Path $dest -Recurse -File).Count
                Write-Ok "$($d.Name)/ la root disc ($dirCount fisiere) [junction]"
            }

            # Copy PACS DICOMDIR to disc root (paths already match!)
            Copy-Item -Path $pacsDicomdir -Destination (Join-Path $DiscStaging "DICOMDIR") -Force
            $dicomdirSize = (Get-Item (Join-Path $DiscStaging "DICOMDIR")).Length
            Write-Ok "DICOMDIR PACS copiat ($([math]::Round($dicomdirSize / 1KB)) KB) - statiile medicale vor recunoaste discul"

            # Also copy DICOM to Weasis/DICOM/ for Weasis auto-scan compatibility
            # Instead of duplicating files, we modify config.properties later (Step 8b)
            Write-Ok "DICOM la root disc. Weasis va fi configurat sa scaneze ../$($topDirsWithDcm[0].Name)"
            return
        }
    }

    # Fallback: PACS DICOMDIR not usable (With Viewer ZIP or no DICOMDIR)
    # Copy DICOM files into Weasis/DICOM/ subfolder (old behavior)
    Write-Host "    DICOMDIR PACS nu poate fi folosit direct. Copii DICOM in Weasis/DICOM/..." -ForegroundColor Yellow

    # Find the DICOM root folder
    $firstDcm = $allDcmFiles[0]
    $dicomParent = $firstDcm.DirectoryName
    $dicomSourceRoot = $null
    $checkPath = $dicomParent
    while ($checkPath -and $checkPath.Length -gt $ExtractedDir.Length) {
        if ((Split-Path -Leaf $checkPath) -match "^(DICOM|dicom|IMAGES|images)$") {
            $dicomSourceRoot = $checkPath
            break
        }
        $checkPath = Split-Path -Parent $checkPath
    }

    if ($dicomSourceRoot) {
        $destDicom = Join-Path $ContentDir (Split-Path -Leaf $dicomSourceRoot)
        Copy-Item -Path $dicomSourceRoot -Destination $destDicom -Recurse -Force
        Write-Ok "Copiat folderul $(Split-Path -Leaf $dicomSourceRoot)/ ($($allDcmFiles.Count) fisiere)"
    } else {
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

    Write-Ok "DICOMDIR din ZIP omis (cai incompatibile). Se va genera unul nou cu dcmmkdir."
}

function Copy-WeasisToStaging {
    Write-Status "Copiez Weasis portable pe disc (junctions)..."

    # Folders/files to exclude from DVD (not needed for Windows target / replaced by our templates)
    $excludeNames = @("viewer-mac.app", "autorun.inf", "viewer-win32.exe")

    # Directories that need normal copy (will be modified during burn process)
    $copyDirs = @("conf")

    # Use NTFS junctions for large directories (instant, zero bytes copied).
    # IMAPI2 AddTree reads through junctions transparently.
    # Only small/modified items are copied normally.
    $junctionCount = 0
    $copyCount = 0

    $items = Get-ChildItem -Path $WeasisDir
    foreach ($item in $items) {
        if ($excludeNames -contains $item.Name) { continue }
        $destPath = Join-Path $ContentDir $item.Name
        if ($item.PSIsContainer) {
            if ($copyDirs -contains $item.Name) {
                # Normal copy — this directory gets modified (e.g. config.properties)
                Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                $copyCount++
            } else {
                # NTFS junction — instant link, no data copied
                $null = cmd /c "mklink /J `"$destPath`" `"$($item.FullName)`"" 2>&1
                if (Test-Path $destPath) {
                    $junctionCount++
                } else {
                    # Fallback: normal copy if junction fails (e.g. policy restriction)
                    Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                    $copyCount++
                }
            }
        } else {
            Copy-Item -Path $item.FullName -Destination $destPath -Force
            $copyCount++
        }
    }

    # Report which JREs are included
    $jreInfo = @()
    if (Test-Path (Join-Path $ContentDir "jre\windows\bin\java.exe")) { $jreInfo += "x86" }
    if (Test-Path (Join-Path $ContentDir "jre\windows-x64\bin\java.exe")) { $jreInfo += "x64" }
    Write-Ok "Weasis portable: $junctionCount junctions + $copyCount copii (JRE: $($jreInfo -join ' + '))"
}

function Copy-TemplatesToStaging {
    Write-Status "Copiez templates..."

    # autorun.inf goes to disc root (Windows reads it from root only)
    # Generate dynamically with patient name as label (overrides IMAPI2 VolumeName in Explorer)
    $autorunPath = Join-Path $DiscStaging "autorun.inf"
    $autoLabel = if ($script:discLabel) { $script:discLabel } else { "Weasis DICOM Viewer" }
    $autorunContent = @"
[autorun]
open=Weasis\start-weasis.bat
icon=Weasis\weasis.ico
label=$autoLabel
action=Open DICOM Viewer (Weasis)
"@
    [System.IO.File]::WriteAllText($autorunPath, $autorunContent, [System.Text.Encoding]::ASCII)

    # Everything else goes into Weasis/ subfolder
    Copy-Item -Path (Join-Path $TemplatesDir "start-weasis.bat") -Destination $ContentDir -Force
    Copy-Item -Path (Join-Path $TemplatesDir "splash-loader.ps1") -Destination $ContentDir -Force
    Copy-Item -Path (Join-Path $TemplatesDir "README.html") -Destination $ContentDir -Force
    $readmeTxt = Join-Path $TemplatesDir "README.txt"
    if (Test-Path $readmeTxt) { Copy-Item -Path $readmeTxt -Destination $DiscStaging -Force }

    # Tutorial script
    $tutorialScript = Join-Path $TemplatesDir "tutorial.ps1"
    if (Test-Path $tutorialScript) {
        Copy-Item -Path $tutorialScript -Destination $ContentDir -Force
    }

    # Tutorial images (only numbered PNGs, skip "Copy" duplicates)
    $tutorialSrc = Join-Path $TemplatesDir "tutorial"
    if (Test-Path $tutorialSrc) {
        $tutorialDest = Join-Path $ContentDir "tutorial"
        New-Item -ItemType Directory -Path $tutorialDest -Force | Out-Null
        Get-ChildItem "$tutorialSrc\?.png" | Copy-Item -Destination $tutorialDest -Force
    }

    Write-Ok "autorun.inf (root), start-weasis.bat + splash-loader.ps1 + tutorial.ps1 + README.html (Weasis/)"
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
    Write-Status "DICOMDIR pentru statii medicale..."

    # If PACS DICOMDIR was already copied in Copy-DicomToStaging, skip generation
    if ($script:usePacsDicomdir) {
        Write-Ok "DICOMDIR PACS deja copiat la root disc (cai corecte, metadata completa)"
        return
    }

    # Fallback: generate DICOMDIR with dcmmkdir (for "With Viewer" ZIPs)
    Write-Host "    Generez DICOMDIR cu dcmmkdir (fallback)..." -ForegroundColor Yellow

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

    # DICOM Part 10 File IDs: max 8 chars per component, uppercase A-Z 0-9 _, NO dots.
    # dcmmkdir strictly enforces this. Fix staging files/dirs to be compliant.

    # Step A: Strip .DCM extensions from files
    $renamedCount = 0
    Get-ChildItem -Path $dicomDir -Recurse -File | Where-Object {
        $_.Extension -match "^\.(dcm|DCM)$"
    } | ForEach-Object {
        Rename-Item -Path $_.FullName -NewName $_.BaseName -ErrorAction SilentlyContinue
        $renamedCount++
    }
    if ($renamedCount -gt 0) {
        Write-Ok "Eliminat extensia .DCM de la $renamedCount fisiere"
    }

    # Step B: Make directory names DICOM-compliant (uppercase, max 8 chars, A-Z 0-9 _)
    Get-ChildItem -Path $dicomDir -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
        $newName = $_.Name.ToUpper()
        $newName = $newName -replace '[^A-Z0-9_]', ''
        if ($newName.Length -gt 8) { $newName = $newName.Substring(0, 8) }
        if ($newName -eq '') { $newName = 'D' + (Get-Random -Minimum 1000 -Maximum 9999) }
        if ($_.Name -cne $newName) {
            $parentDir = Split-Path $_.FullName
            $tempName = "_ren_" + (Get-Random -Minimum 10000 -Maximum 99999)
            $tempPath = Join-Path $parentDir $tempName
            Rename-Item -Path $_.FullName -NewName $tempName -ErrorAction SilentlyContinue
            if (Test-Path $tempPath) {
                Rename-Item -Path $tempPath -NewName $newName -ErrorAction SilentlyContinue
            }
        }
    }

    # Step C: Make file names compliant (uppercase, max 8 chars, no invalid chars)
    Get-ChildItem -Path $dicomDir -Recurse -File | ForEach-Object {
        $newName = $_.BaseName.ToUpper()
        $newName = $newName -replace '[^A-Z0-9_]', ''
        if ($newName.Length -gt 8) { $newName = $newName.Substring(0, 8) }
        if ($newName -eq '') { $newName = 'F' + (Get-Random -Minimum 10000 -Maximum 99999) }
        $ext = $_.Extension
        $fullNew = $newName + $ext
        if ($_.Name -cne $fullNew) {
            $parentDir = Split-Path $_.FullName
            $tempName = "_ren_" + (Get-Random -Minimum 10000 -Maximum 99999)
            $tempPath = Join-Path $parentDir $tempName
            Rename-Item -Path $_.FullName -NewName $tempName -ErrorAction SilentlyContinue
            if (Test-Path $tempPath) {
                Rename-Item -Path $tempPath -NewName $fullNew -ErrorAction SilentlyContinue
            }
        }
    }

    # Set DICOM dictionary path
    $dictPath = Join-Path $DcmtkDir "share\dcmtk-3.7.0\dicom.dic"
    if (-not (Test-Path $dictPath)) {
        $dictPath = Join-Path $DcmtkDir "share\dcmtk\dicom.dic"
    }
    if (Test-Path $dictPath) {
        $env:DCMDICTPATH = $dictPath
    }

    $dicomdirPath = Join-Path $DiscStaging "DICOMDIR"

    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $cmdLine = "cd /d `"$DiscStaging`" && `"$dcmmkdir`" +r +id Weasis\DICOM +D DICOMDIR +I -Pgp"
        $output = cmd /c $cmdLine 2>&1
    } finally {
        $ErrorActionPreference = $savedEAP
    }

    if ($LASTEXITCODE -eq 0 -and (Test-Path $dicomdirPath)) {
        $dicomdirSize = (Get-Item $dicomdirPath).Length
        Write-Ok "DICOMDIR generat ($([math]::Round($dicomdirSize / 1KB)) KB)"
    } else {
        Write-Host "    [ATENTIE] dcmmkdir a esuat (cod: $LASTEXITCODE)" -ForegroundColor Yellow
        if ($output) {
            $output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
        Write-Host "    Discul va functiona cu Weasis, dar poate nu cu statiile medicale." -ForegroundColor Yellow
    }
}

function Get-DirectorySize {
    # .NET GetFiles follows NTFS junctions (Get-ChildItem -Recurse does NOT)
    param([string]$Path)
    try {
        $files = [System.IO.DirectoryInfo]::new($Path).GetFiles('*', [System.IO.SearchOption]::AllDirectories)
        return ($files | Measure-Object -Property Length -Sum).Sum
    } catch {
        return (Get-ChildItem -Path $Path -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    }
}

function Show-DiscSummary {
    Write-Status "Sumar disc:"

    $totalSize = Get-DirectorySize $DiscStaging
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
            $dirSize = Get-DirectorySize $_.FullName
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

    # Release discMaster — no longer needed after enumeration
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discMaster) | Out-Null } catch {}

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
    $script:selectedDriveId = $selectedDrive.ID

    # Check if blank media is already inserted (for AutoConfirm mode)
    if ($AutoConfirm) {
        $preCheck = $null
        try {
            $preCheck = New-Object -ComObject IMAPI2.MsftDiscFormat2Data
            $preCheck.Recorder = $recorder
            $preCheck.ClientName = "WeasisBurn"
            $mediaReady = $preCheck.CurrentMediaStatus
        } catch { $mediaReady = $null }
        finally {
            if ($preCheck) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($preCheck) | Out-Null } catch {} }
        }

        if ($mediaReady) {
            Write-Ok "Disc gol detectat in $($selectedDrive.Letter) - continui automat"
        } else {
            Write-Host ""
            Write-Host "    Introdu un DVD-R gol in $($selectedDrive.Letter) si apasa ENTER..." -ForegroundColor Yellow
            Read-Host
        }
    } else {
        Write-Host ""
        Write-Host "    Introdu un DVD-R gol in $($selectedDrive.Letter) si apasa ENTER..." -ForegroundColor Yellow
        Read-Host
    }

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

        # Get drive letter BEFORE releasing COM objects
        $ejectDrive = $null
        try { $ejectDrive = $recorder.VolumePathNames[0] -replace '\\$','' } catch {}

        # Release ALL IMAPI2 COM objects BEFORE eject
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($result) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsImage) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discFormat) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) | Out-Null } catch {}
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        # Start background dialog killer BEFORE eject (catches "Insert disc" within ~150ms)
        try {
            $killerScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "dialog-killer-$PID.ps1")
            @'
for($i=0;$i -lt 60;$i++){
    try{
        $w=New-Object -ComObject WScript.Shell
        foreach($t in @("Insert disc","Insert a disc","Introduceti un disc","Introduceți un disc")){
            if($w.AppActivate($t)){Start-Sleep -Milliseconds 80;$w.SendKeys("{ESCAPE}")}
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($w)
    }catch{}
    Start-Sleep -Milliseconds 150
}
try{Remove-Item $MyInvocation.MyCommand.Path -Force}catch{}
'@ | Set-Content -Path $killerScript -Encoding ASCII
            Start-Process powershell -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File",$killerScript -WindowStyle Hidden
        } catch {}

        # Eject via Win32 (LOCK → DISMOUNT → EJECT)
        if ($ejectDrive) {
            try {
                if (-not ([System.Management.Automation.PSTypeName]'DriveEject').Type) {
                    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DriveEject {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    static extern IntPtr CreateFile(string f, uint a, uint s, IntPtr p, uint d, uint g, IntPtr t);
    [DllImport("kernel32.dll")]
    static extern bool DeviceIoControl(IntPtr h, uint c, IntPtr i, uint si, IntPtr o, uint so, out uint r, IntPtr v);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    public static bool Eject(string drive) {
        IntPtr h = CreateFile(@"\\.\" + drive, 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) return false;
        uint r;
        DeviceIoControl(h, 0x90018u, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
        DeviceIoControl(h, 0x90020u, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
        bool ok = DeviceIoControl(h, 0x2D4808u, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
        CloseHandle(h);
        return ok;
    }
}
"@
                }
                [DriveEject]::Eject($ejectDrive)
            } catch {
                # Fallback: IMAPI2 eject
                try {
                    $fallbackRec = New-Object -ComObject IMAPI2.MsftDiscRecorder2
                    $fallbackRec.InitializeDiscRecorder($script:selectedDriveId)
                    $fallbackRec.DisableMcn()
                    $fallbackRec.EjectMedia()
                    $fallbackRec.EnableMcn()
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fallbackRec) | Out-Null
                } catch {}
            }
        }

        Write-Ok "DISC ARDS CU SUCCES!"
        $script:burnSuccess = $true
        Write-Host ""
        Write-Host "    Discul a fost ejectat. Poti sa-l folosesti." -ForegroundColor Green

    } catch {
        # Cleanup COM objects on error too
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($result) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsImage) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discFormat) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) | Out-Null } catch {}
        [GC]::Collect()

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

        # CRITICAL: Remove NTFS junctions BEFORE Remove-Item -Recurse!
        # PowerShell follows junctions and would delete source files in tools/weasis-portable/
        # rmdir on a junction removes only the link, not the target data.
        try {
            Get-ChildItem -Path $TempRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
                ForEach-Object {
                    cmd /c "rmdir `"$($_.FullName)`"" 2>$null
                }
        } catch {}

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

# Step 2b: Add Windows Defender exclusion for temp dir (prevents 100% CPU during extraction)
Add-DefenderExclusion

# Validate input: one of ZipPath or DicomFolder must be provided
if (-not $ZipPath -and -not $DicomFolder) {
    Write-Err "Specificati -ZipPath sau -DicomFolder"
    exit 1
}

# Step 3: Extract ZIP or use provided folder
if ($DicomFolder) {
    if (-not (Test-Path $DicomFolder)) {
        Write-Err "Folderul DICOM nu exista: $DicomFolder"
        exit 1
    }
    $extractedDir = $DicomFolder
    Write-Ok "Folder DICOM primit: $DicomFolder"
} else {
    $extractedDir = Expand-PatientZip -Zip $ZipPath
}

# Step 4: Copy DICOM files to staging with proper structure
Copy-DicomToStaging -ExtractedDir $extractedDir

# Step 4b: Extract patient info from DICOM for disc label
$script:discLabel = "Weasis DICOM"
$uniquePatients = @{}
$foldersChecked = @{}
# Collect search directories: all DIR root folders + Weasis/DICOM/ fallback
$dicomSearchDirs = @()
if ($script:dicomRootFolders -and $script:dicomRootFolders.Count -gt 0) {
    foreach ($dirFolder in $script:dicomRootFolders) {
        $dirPath = Join-Path $DiscStaging $dirFolder
        if (Test-Path $dirPath) { $dicomSearchDirs += $dirPath }
    }
}
# Fallback: check Weasis/DICOM/ (only if no root folders found)
if ($dicomSearchDirs.Count -eq 0) {
    $fallbackDir = Join-Path $ContentDir "DICOM"
    if (Test-Path $fallbackDir) { $dicomSearchDirs += $fallbackDir }
    else {
        $found = Get-ChildItem -Path $ContentDir -Directory | Where-Object {
            $_.Name -match "^(DICOM|dicom|IMAGES|images)$"
        } | Select-Object -First 1 -ExpandProperty FullName
        if ($found) { $dicomSearchDirs += $found }
    }
}
foreach ($dicomSearchDir in $dicomSearchDirs) {
    # Find DICOM files: with .dcm extension OR extensionless with DICM magic bytes
    $allDcmForLabel = @()
    foreach ($fileItem in (Get-ChildItem -Path $dicomSearchDir -Recurse -File)) {
        if ($fileItem.Extension -match "^\.(dcm|DCM)$") {
            $allDcmForLabel += $fileItem
        } elseif ($fileItem.Extension -eq "" -and $fileItem.Length -gt 132) {
            try {
                $buf = New-Object byte[] 132
                $fs = [System.IO.File]::OpenRead($fileItem.FullName)
                $fs.Read($buf, 0, 132) | Out-Null
                $fs.Close()
                if ([System.Text.Encoding]::ASCII.GetString($buf, 128, 4) -eq "DICM") {
                    $allDcmForLabel += $fileItem
                }
            } catch {}
        }
        # Stop after finding enough files from different folders
        if ($allDcmForLabel.Count -ge 50) { break }
    }
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
        if ($foldersChecked.Count -ge 20) { break }
    }
}
if ($uniquePatients -and $uniquePatients.Count -gt 0) {

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

# Step 8b: Configure Weasis to scan DICOM at disc root (when using PACS DICOMDIR)
if ($script:usePacsDicomdir -and $script:dicomRootFolders.Count -gt 0) {
    $configPath = Join-Path $ContentDir "conf\config.properties"
    if (Test-Path $configPath) {
        $configContent = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
        # Add ../DIR000 (etc.) to weasis.portable.dicom.directory so Weasis finds files at disc root
        # ../DIR000 works from disc (Weasis/ is one level down); DIR000 works from HDD copy (splash-loader junction)
        $extraDirs = (($script:dicomRootFolders | ForEach-Object { "../$_" }) + ($script:dicomRootFolders)) -join ","
        $oldLine = "weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images"
        $newLine = "weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images,$extraDirs"
        $configContent = $configContent.Replace($oldLine, $newLine)
        [System.IO.File]::WriteAllText($configPath, $configContent, [System.Text.Encoding]::UTF8)
        Write-Ok "config.properties: adaugat $extraDirs la scanare DICOM"
    } else {
        Write-Host "    [ATENTIE] config.properties nu a fost gasit. Weasis poate sa nu gaseasca DICOM automat." -ForegroundColor Yellow
    }
}

# Step 9: Show summary
Show-DiscSummary

# Step 10: Confirm and burn (or simulate)
if ($SimulateOnly) {
    Write-Status "SIMULARE - Nu se arde nimic pe disc!"
    Write-Host ""
    Write-Host "    ============================================" -ForegroundColor Magenta
    Write-Host "    =         MOD SIMULARE ACTIV               =" -ForegroundColor Magenta
    Write-Host "    ============================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "    Toti pasii au fost executati cu succes:" -ForegroundColor White
    Write-Host "      - ZIP extras" -ForegroundColor Green
    Write-Host "      - DICOM copiat si organizat" -ForegroundColor Green
    Write-Host "      - Weasis portable copiat" -ForegroundColor Green
    Write-Host "      - Templates copiate" -ForegroundColor Green
    Write-Host "      - DICOMDIR copiat/generat" -ForegroundColor Green
    Write-Host ""

    # Simulate burn with progress bar based on real data size and burn speed
    $totalSize = Get-DirectorySize $DiscStaging
    $totalSizeMB = [math]::Round($totalSize / 1MB, 1)
    $speedKBs = $BurnSpeed * 1385  # 1x DVD = 1385 KB/s
    $totalSizeKB = $totalSize / 1024
    $estimatedSec = [math]::Max([math]::Ceiling($totalSizeKB / $speedKBs), 3)
    $barWidth = 40

    Write-Host "    Simulare ardere: $totalSizeMB MB la ${BurnSpeed}x ($speedKBs KB/s)" -ForegroundColor Yellow
    Write-Host "    Timp estimat: ~$estimatedSec secunde" -ForegroundColor Gray
    Write-Host ""

    # Phases: lead-in (5%), writing (85%), lead-out (10%)
    $phases = @(
        @{ Name = "Lead-in";  Start = 0;    End = 0.05; Color = "DarkYellow" }
        @{ Name = "Scriere";  Start = 0.05; End = 0.90; Color = "Yellow" }
        @{ Name = "Lead-out"; Start = 0.90; End = 1.00; Color = "DarkYellow" }
    )

    $steps = $estimatedSec * 4  # update 4 times per second
    $sleepMs = [math]::Round(($estimatedSec * 1000) / $steps)
    $startTime = [DateTime]::Now

    for ($i = 1; $i -le $steps; $i++) {
        $pct = [math]::Min($i / $steps, 1.0)
        $pctInt = [math]::Round($pct * 100)
        $filled = [math]::Round($pct * $barWidth)
        $empty = $barWidth - $filled
        $bar = ([string][char]9608) * $filled + ([string][char]9617) * $empty

        # Determine current phase name
        $phaseName = "Scriere"
        $phaseColor = "Yellow"
        foreach ($ph in $phases) {
            if ($pct -ge $ph.Start -and $pct -lt $ph.End) {
                $phaseName = $ph.Name
                $phaseColor = $ph.Color
                break
            }
        }
        if ($pct -ge 1.0) { $phaseName = "Lead-out"; $phaseColor = "DarkYellow" }

        # Simulated written size
        $writtenMB = [math]::Round($totalSizeMB * $pct, 1)

        # Elapsed time
        $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
        $elapsedStr = "{0:mm\:ss}" -f [TimeSpan]::FromSeconds($elapsed)
        $remainSec = [math]::Max($estimatedSec - $elapsed, 0)
        $remainStr = "{0:mm\:ss}" -f [TimeSpan]::FromSeconds($remainSec)

        # Write on same line
        $line = "    $bar  $pctInt%  $writtenMB/$totalSizeMB MB  [$phaseName]  $elapsedStr / ~$remainStr"
        Write-Host "`r$line" -NoNewline -ForegroundColor $phaseColor

        Start-Sleep -Milliseconds $sleepMs
    }

    # Final 100%
    $bar = ([string][char]9608) * $barWidth
    $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
    $elapsedStr = "{0:mm\:ss}" -f [TimeSpan]::FromSeconds($elapsed)
    Write-Host "`r    $bar  100%  $totalSizeMB/$totalSizeMB MB  [Finalizat]  $elapsedStr          " -ForegroundColor Green
    Write-Host ""
    Write-Host ""
    Write-Ok "SIMULARE BURN FINALIZATA CU SUCCES!"
    Write-Host ""
    Write-Host "    Fisierele pregatite sunt in:" -ForegroundColor White
    Write-Host "      $DiscStaging" -ForegroundColor Yellow
    Write-Host ""
    $script:burnSuccess = $true  # simulate success for cleanup (ZIP delete)
} elseif ($AutoConfirm) {
    Write-Host ""
    Write-Ok "AutoConfirm: pornesc arderea automat..."
    Burn-ToDisc
} else {
    Write-Host ""
    $confirm = Read-Host "Vrei sa arzi pe DVD-R acum? (da/nu)"
    if ($confirm -eq "da" -or $confirm -eq "d" -or $confirm -eq "y" -or $confirm -eq "yes") {
        Burn-ToDisc
    } else {
        Write-Host ""
        Write-Host "    Fisierele pregatite sunt in: $DiscStaging" -ForegroundColor Yellow
        Write-Host "    Poti arde manual mai tarziu." -ForegroundColor Yellow
    }
}

# Step 11: Cleanup
Cleanup

Write-Host ""
Write-Host "GATA!" -ForegroundColor Green
Write-Host ""
