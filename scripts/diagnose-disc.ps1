# Diagnostic script for Weasis DICOM disc issues
# Usage: .\diagnose-disc.ps1 -DiscDrive "F:"
# Run from the DVD drive letter to check if disc structure is correct

param(
    [string]$DiscDrive = ""
)

$ErrorActionPreference = "Continue"

function Write-Status($text, $color = "White") {
    Write-Host $text -ForegroundColor $color
}

function Write-OK($text) { Write-Status "[OK] $text" "Green" }
function Write-FAIL($text) { Write-Status "[FAIL] $text" "Red" }
function Write-WARN($text) { Write-Status "[WARN] $text" "Yellow" }
function Write-INFO($text) { Write-Status "[INFO] $text" "Cyan" }

# Auto-detect disc drive if not specified
if (-not $DiscDrive) {
    $opticalDrives = Get-WmiObject -Class Win32_CDROMDrive | Where-Object { $_.MediaLoaded -eq $true }
    if ($opticalDrives) {
        $DiscDrive = ($opticalDrives | Select-Object -First 1).Drive
        Write-INFO "Auto-detected disc drive: $DiscDrive"
    } else {
        Write-FAIL "No disc found. Insert a burned disc and re-run, or specify -DiscDrive 'F:'"
        exit 1
    }
}

$discRoot = "${DiscDrive}\"
if (-not (Test-Path $discRoot)) {
    Write-FAIL "Drive $DiscDrive not accessible"
    exit 1
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  DICOM Disc Diagnostic" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check disc root structure
Write-INFO "=== 1. DISC ROOT STRUCTURE ==="
$rootItems = Get-ChildItem -Path $discRoot -Force
foreach ($item in $rootItems) {
    $type = if ($item.PSIsContainer) { "[DIR]" } else { "[FILE] $([math]::Round($item.Length / 1KB, 0)) KB" }
    Write-Host "  $type $($item.Name)"
}
Write-Host ""

# 2. Check DICOMDIR
Write-INFO "=== 2. DICOMDIR ==="
$dicomdirPath = Join-Path $discRoot "DICOMDIR"
if (Test-Path $dicomdirPath) {
    $dicomdirSize = (Get-Item $dicomdirPath).Length
    Write-OK "DICOMDIR exists ($([math]::Round($dicomdirSize / 1KB)) KB)"

    # Read DICOMDIR binary to check for IMAGE records
    try {
        $bytes = [System.IO.File]::ReadAllBytes($dicomdirPath)
        $content = [System.Text.Encoding]::ASCII.GetString($bytes)

        # Count directory record types
        $patientCount = ([regex]::Matches($content, "PATIENT")).Count
        $studyCount = ([regex]::Matches($content, "STUDY")).Count
        $seriesCount = ([regex]::Matches($content, "SERIES")).Count
        $imageCount = ([regex]::Matches($content, "IMAGE")).Count

        Write-INFO "  Records: PATIENT=$patientCount, STUDY=$studyCount, SERIES=$seriesCount, IMAGE=$imageCount"

        if ($imageCount -eq 0) {
            Write-FAIL "  DICOMDIR has 0 IMAGE records! Medical workstations cannot find files."
        }

        # Check for DIR000 references
        $dir000Refs = ([regex]::Matches($content, "DIR000")).Count
        Write-INFO "  DIR000 references: $dir000Refs"
    } catch {
        Write-WARN "  Could not parse DICOMDIR: $_"
    }
} else {
    Write-FAIL "DICOMDIR not found at disc root!"
}
Write-Host ""

# 3. Check DIR000/ folder
Write-INFO "=== 3. DICOM FILES ==="
$dir000 = Join-Path $discRoot "DIR000"
if (Test-Path $dir000) {
    $dcmFiles = Get-ChildItem -Path $dir000 -Recurse -File
    $dcmCount = ($dcmFiles | Where-Object { $_.Extension -match "^\.(dcm|DCM)$" }).Count
    $totalSize = ($dcmFiles | Measure-Object -Property Length -Sum).Sum
    $series = (Get-ChildItem -Path $dir000 -Directory).Count
    Write-OK "DIR000/ exists: $dcmCount DCM files, $series series, $([math]::Round($totalSize / 1MB)) MB"

    # Show first file details
    $firstDcm = $dcmFiles | Where-Object { $_.Extension -match "^\.(dcm|DCM)$" } | Select-Object -First 1
    if ($firstDcm) {
        Write-INFO "  First file: $($firstDcm.FullName) ($([math]::Round($firstDcm.Length / 1KB)) KB)"

        # Check DICM magic
        try {
            $buf = New-Object byte[] 132
            $fs = [System.IO.File]::OpenRead($firstDcm.FullName)
            $fs.Read($buf, 0, 132) | Out-Null
            $fs.Close()
            $magic = [System.Text.Encoding]::ASCII.GetString($buf, 128, 4)
            if ($magic -eq "DICM") {
                Write-OK "  DICM magic: valid DICOM Part 10 file"
            } else {
                Write-WARN "  No DICM magic at offset 128 (magic='$magic')"
            }
        } catch {
            Write-WARN "  Could not read file header: $_"
        }
    }
} else {
    # Check for other DICOM folders
    $dicomFolder = Join-Path $discRoot "Weasis\DICOM"
    if (Test-Path $dicomFolder) {
        Write-WARN "DIR000/ not at root, but Weasis\DICOM\ exists"
    } else {
        Write-FAIL "No DIR000/ and no Weasis\DICOM\ found!"
    }
}
Write-Host ""

# 4. Check Weasis folder
Write-INFO "=== 4. WEASIS FOLDER ==="
$weasisDir = Join-Path $discRoot "Weasis"
if (Test-Path $weasisDir) {
    Write-OK "Weasis/ exists"

    # Essential files
    $essentials = @(
        "start-weasis.bat",
        "splash-loader.ps1",
        "weasis-launcher.jar",
        "felix.jar",
        "substance.jar",
        "conf\config.properties"
    )
    foreach ($f in $essentials) {
        $path = Join-Path $weasisDir $f
        if (Test-Path $path) {
            Write-OK "  $f"
        } else {
            Write-FAIL "  $f MISSING!"
        }
    }

    # JRE
    $jreX86 = Join-Path $weasisDir "jre\windows\bin\javaw.exe"
    $jreX64 = Join-Path $weasisDir "jre\windows-x64\bin\javaw.exe"
    if (Test-Path $jreX64) { Write-OK "  JRE x64: present" }
    else { Write-WARN "  JRE x64: missing" }
    if (Test-Path $jreX86) { Write-OK "  JRE x86: present" }
    else { Write-WARN "  JRE x86: missing" }
} else {
    Write-FAIL "Weasis/ folder not found!"
}
Write-Host ""

# 5. Check config.properties -- THE CRITICAL PART
Write-INFO "=== 5. CONFIG.PROPERTIES (DICOM scan paths) ==="
$configPath = Join-Path $weasisDir "conf\config.properties"
if (Test-Path $configPath) {
    $configLines = Get-Content $configPath
    $dicomDirLine = $configLines | Where-Object { $_ -match "^weasis\.portable\.dicom\.directory=" }
    if ($dicomDirLine) {
        Write-INFO "  Line: $dicomDirLine"

        # Parse directories
        $value = $dicomDirLine -replace "^weasis\.portable\.dicom\.directory=", ""
        $dirs = $value -split ","
        Write-INFO "  Scan directories ($($dirs.Count)):"
        foreach ($d in $dirs) {
            $d = $d.Trim()
            # Resolve relative to Weasis/ folder
            $resolved = Join-Path $weasisDir $d
            $exists = Test-Path $resolved
            if ($exists) {
                Write-OK "    '$d' -> $resolved (EXISTS)"
            } else {
                # Try resolving from disc root for ../DIR000
                $fromRoot = Join-Path $discRoot ($d -replace "^\.\./", "")
                $existsRoot = Test-Path $fromRoot
                if ($existsRoot) {
                    Write-OK "    '$d' -> $fromRoot (EXISTS via ../ from Weasis)"
                } else {
                    Write-WARN "    '$d' -> NOT FOUND (resolved: $resolved)"
                }
            }
        }

        # Check if DIR000 is referenced
        if ($value -match "DIR000") {
            Write-OK "  Config references DIR000"
        } else {
            Write-FAIL "  Config does NOT reference DIR000! Weasis won't find DICOM files!"
            Write-FAIL "  Expected: weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images,../DIR000,DIR000"
        }
    } else {
        Write-FAIL "  weasis.portable.dicom.directory line NOT FOUND in config!"
    }
} else {
    Write-FAIL "  config.properties not found!"
}
Write-Host ""

# 6. Simulate HDD copy scenario (what splash-loader does)
Write-INFO "=== 6. SIMULATE HDD COPY (splash-loader logic) ==="
Write-INFO "  weasis.portable.dir would be: %TEMP%\weasis-dvd\"
Write-INFO "  Splash-loader creates junctions:"

# Find DIR* folders at disc root
$dirFolders = Get-ChildItem -Path $discRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^DIR\d{3}$" } | Sort-Object Name

if ($dirFolders.Count -gt 0) {
    foreach ($df in $dirFolders) {
        Write-OK "    Junction: %TEMP%\weasis-dvd\$($df.Name) -> $($df.FullName)"
    }
    Write-INFO "  Weasis config entry 'DIR000' would resolve to: %TEMP%\weasis-dvd\DIR000 (junction)"
} else {
    Write-FAIL "  No DIR* folders at disc root! Splash-loader cannot create DICOM junctions!"
    # Check for DICOM in Weasis/
    foreach ($dn in @("DICOM","dicom","IMAGES","images")) {
        $candidate = Join-Path $weasisDir $dn
        if (Test-Path $candidate) {
            Write-WARN "  Found $dn inside Weasis/ (old layout)"
        }
        $candidateRoot = Join-Path $discRoot $dn
        if (Test-Path $candidateRoot) {
            Write-WARN "  Found $dn at disc root"
        }
    }
}
Write-Host ""

# 7. Test DICOM file parsing (if fo-dicom available)
Write-INFO "=== 7. DICOM FILE VALIDATION ==="
$firstDcm = Get-ChildItem -Path $discRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match "^\.(dcm|DCM)$" } | Select-Object -First 1
if ($firstDcm) {
    # Check DICOM header manually
    try {
        $bytes = [System.IO.File]::ReadAllBytes($firstDcm.FullName)

        # Check preamble (128 bytes) + DICM magic
        $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 128, 4)
        if ($magic -eq "DICM") {
            Write-OK "  Valid DICOM Part 10 format"
        } else {
            Write-WARN "  Not standard DICOM Part 10 (no DICM magic)"
        }

        # Try to find PatientName tag (0010,0010)
        $hexContent = [BitConverter]::ToString($bytes) -replace "-", ""
        # Tag (0010,0010) in little-endian = 10 00 10 00
        $patNameTag = "10001000"
        $idx = $hexContent.IndexOf($patNameTag)
        if ($idx -ge 0) {
            # Read VR and length after tag
            $tagBytePos = $idx / 2
            $vr = [System.Text.Encoding]::ASCII.GetString($bytes, $tagBytePos + 4, 2)
            Write-OK "  PatientName tag found (VR=$vr) at offset $tagBytePos"
        } else {
            Write-WARN "  PatientName tag (0010,0010) not found in first file"
        }

        # File size check
        if ($bytes.Length -lt 1024) {
            Write-WARN "  File very small ($($bytes.Length) bytes) -- might not contain image data"
        } else {
            Write-OK "  File size: $([math]::Round($bytes.Length / 1KB)) KB"
        }

        # Check Transfer Syntax
        $tsTag = "02001000" # (0002,0010) TransferSyntaxUID
        $tsIdx = $hexContent.IndexOf($tsTag)
        if ($tsIdx -ge 0) {
            $tsBytePos = $tsIdx / 2
            # VR is UI, then 2 bytes length
            $tsVR = [System.Text.Encoding]::ASCII.GetString($bytes, $tsBytePos + 4, 2)
            if ($tsVR -eq "UI") {
                $tsLen = [BitConverter]::ToUInt16($bytes, $tsBytePos + 6)
                if ($tsLen -gt 0 -and $tsLen -lt 100) {
                    $tsUID = [System.Text.Encoding]::ASCII.GetString($bytes, $tsBytePos + 8, $tsLen).TrimEnd("`0", " ")
                    Write-INFO "  Transfer Syntax: $tsUID"

                    $knownTS = @{
                        "1.2.840.10008.1.2" = "Implicit VR Little Endian"
                        "1.2.840.10008.1.2.1" = "Explicit VR Little Endian"
                        "1.2.840.10008.1.2.2" = "Explicit VR Big Endian"
                        "1.2.840.10008.1.2.4.50" = "JPEG Baseline"
                        "1.2.840.10008.1.2.4.70" = "JPEG Lossless"
                        "1.2.840.10008.1.2.4.90" = "JPEG 2000 Lossless"
                        "1.2.840.10008.1.2.4.91" = "JPEG 2000 Lossy"
                        "1.2.840.10008.1.2.5" = "RLE Lossless"
                    }
                    if ($knownTS.ContainsKey($tsUID)) {
                        Write-OK "  -> $($knownTS[$tsUID]) (supported by Weasis)"
                    } else {
                        Write-WARN "  -> Unknown transfer syntax -- may not be supported by Weasis 3.7.1"
                    }
                }
            }
        }
    } catch {
        Write-WARN "  Error parsing DICOM: $_"
    }
} else {
    Write-FAIL "  No .DCM files found on disc!"
}
Write-Host ""

# 8. Summary
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$issues = @()

# Check critical paths
if (-not (Test-Path $dicomdirPath)) { $issues += "DICOMDIR missing at root" }
if (-not (Test-Path $dir000)) { $issues += "DIR000/ missing at root" }
if (-not (Test-Path $configPath)) { $issues += "config.properties missing" }
else {
    $cfgContent = Get-Content $configPath -Raw
    if ($cfgContent -notmatch "DIR000") { $issues += "config.properties missing DIR000 scan path" }
}
if ($dirFolders.Count -eq 0) { $issues += "No DIR* folders at root for splash-loader junctions" }

if ($issues.Count -eq 0) {
    Write-OK "Disc structure looks correct. If Weasis still shows empty:"
    Write-Host ""
    Write-INFO "  1. Try launching manually: open Weasis/, double-click start-weasis.bat"
    Write-INFO "  2. Check %TEMP%\weasis-dvd\ -- is DIR000 junction there?"
    Write-INFO "  3. Try: File > Open > Local Disc > navigate to DIR000 on disc"
    Write-INFO "  4. Check Weasis log: %USERPROFILE%\.weasis\log\default.log"
} else {
    Write-FAIL "Found $($issues.Count) issue(s):"
    foreach ($i in $issues) { Write-FAIL "  - $i" }
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
