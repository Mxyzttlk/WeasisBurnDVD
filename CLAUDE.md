# Weasis Burn - DICOM DVD Burn System

## Project Overview
Medical imaging DVD burn system using Weasis portable 3.7.1 viewer with bundled JRE.
Replaces eFilm disc burning with open-source Weasis-based solution.

## Architecture
- **burn.bat** - Entry point. User drags PACS ZIP onto it.
- **scripts/burn.ps1** - Main logic: extract ZIP, organize DICOM, copy Weasis, burn DVD via IMAPI2
- **scripts/setup.ps1** - One-time setup: downloads Weasis portable + JRE 8 x86 + JRE 8 x64
- **templates/** - autorun.inf, start-weasis.bat, and README.html copied onto each disc
- **tools/weasis-portable/** - Weasis 3.7.1 + Adoptium JRE 8 x86 + x64 (not in git, created by setup)

## Key Technical Decisions
- **Weasis 3.7.1 portable** (not 4.x) because 4.x has no portable version and is slow from DVD
- **Dual JRE** (x86 + x64) from Adoptium bundled on disc. `start-weasis.bat` auto-detects OS architecture:
  - **x64 (64-bit)**: `-Xmx2048m` - supports MPR 3D reconstruction on large datasets
  - **x86 (32-bit)**: `-Xmx768m` - compatibility fallback for older PCs (no MPR 3D on large studies)
- **viewer-win32.exe** (Launch4j wrapper) extracted from PACS ZIP, not from SourceForge
- **SourceForge ZIP** only contains Java bundles (no launcher exe)
- **IMAPI2 COM** for burning - native Windows API, no external tools needed
- **ISO 9660 + Joliet** filesystem (flag value 3) - critical for fast disc reading vs UDF
- **Burn speed 4x** for reliability with medical data
- **viewer-mac.app excluded** from disc to save ~262 MB (only Windows target for now)
- **DICOMDIR excluded** from disc - PACS ZIP DICOMDIR has paths for original structure (viewer-mac.app/Contents/DICOM/...) that don't match our flat layout. Without DICOMDIR, Weasis uses LoadLocalDicom to scan DICOM/ directly.

## Weasis Launch Method (CRITICAL)
`viewer-win32.exe` (Launch4j) does NOT work in our flat layout because it has hardcoded classpath `weasis\weasis-launcher.jar` and JRE paths from original PACS structure.

Instead, `start-weasis.bat` launches Weasis directly via Java:
```
javaw.exe -Xms64m -Xmx768m -Dweasis.portable.dir="%~dp0." -Dgosh.args="-sc telnetd -p 17179 start" -cp "weasis-launcher.jar;felix.jar;substance.jar" org.weasis.launcher.WeasisLauncher $dicom:get --portable
```

The script auto-detects architecture and selects JRE:
- **64-bit OS**: uses `jre/windows-x64/` with `-Xmx2048m` (MPR 3D works)
- **32-bit OS**: uses `jre/windows/` with `-Xmx768m` (basic viewing only)
- Shows loading message before launch (console window stays 5 seconds)

Key launch requirements:
- **`-Dweasis.portable.dir`** - MUST be set, otherwise `--portable` flag is ignored and DICOM auto-scan doesn't work
- **Main class**: `org.weasis.launcher.WeasisLauncher` (neither JAR has Main-Class in manifest)
- **Classpath**: `weasis-launcher.jar;felix.jar;substance.jar`
- **Arguments**: `$dicom:get --portable` triggers automatic DICOM folder scanning
- Weasis scans directories listed in `weasis.portable.dicom.directory` config relative to `weasis.portable.dir`

## Optical Media Launch Issue (CRITICAL)
On DVD/CD, the `start` command with relative paths fails silently. `start-weasis.bat` MUST use absolute paths via `%~dp0`:
```batch
start "Weasis" "%~dp0jre\windows\bin\javaw.exe" ... -cp "%~dp0weasis-launcher.jar;%~dp0felix.jar;%~dp0substance.jar" ...
```
Relative paths like `jre\windows\bin\javaw.exe` work from HDD but NOT from optical media with `start`.

## OSGI Cache Issue
- Weasis caches OSGI bundles in `%USERPROFILE%\.weasis\cache-XXXXXXXX\`
- Corrupted cache from failed/killed launches causes 30-60 sec delay or prevents startup
- `start-weasis.bat` cleans cache before each launch: `for /d %%D in ("%USERPROFILE%\.weasis\cache-*") do rmdir /s /q "%%D"`
- Cache locked if Weasis still running - must close Weasis (or kill java/javaw) first
- Helper script: `scripts/clean-and-launch.bat` - kills Java, cleans cache, launches from disc
- On a fresh computer (no prior `.weasis`), startup is clean - no issues

## PACS ZIP Structure (with viewer)
```
root/
├── DICOMDIR              ← at ZIP root (paths reference viewer-mac.app structure!)
├── Autorun.inf, Readme.html, Weasis-Viewer.bat
└── viewer-mac.app/
    └── Contents/
        ├── DICOM/DIR000/  ← DCM files are HERE (not at root!)
        ├── viewer-win32.exe, weasis/, jre/, etc.
```
The DICOM files are nested inside viewer-mac.app/Contents/DICOM/, not at ZIP root level.
burn.ps1 handles this by searching for .DCM files recursively and finding the DICOM parent folder.

## PACS ZIP Download Options
User downloads from institutional PACS website. Available options:
- "Ascunderea Detaliilor" (Hide Details)
- "DICOMizare document" (DICOMize document)
- "Exclude Viewer" - when checked, ZIP has only DICOM files (no viewer)
- "Export PNG"

For burn: use "Exclude Viewer" checked (we supply our own Weasis).
For setup: needed one ZIP without "Exclude Viewer" to extract viewer-win32.exe.

## Weasis Config
`conf/config.properties` line 218: `weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images`
Weasis auto-scans these folder names relative to `weasis.portable.dir` for DICOM files.

## DVD Disc Structure (what gets burned)
```
DVD-R/
├── autorun.inf           ← points to start-weasis.bat
├── start-weasis.bat      ← OUR launcher (replaces viewer-win32.exe)
├── README.html
├── DICOM/DIR000/...      ← patient DCM files
├── viewer-win32.exe      ← Launch4j wrapper (DOES NOT WORK in flat layout, kept for reference)
├── weasis-launcher.jar
├── felix.jar
├── substance.jar
├── bundle/               ← Weasis OSGI bundles
├── bundle-i18n/
├── conf/
├── resources/
├── jre/windows/          ← JRE 8 x86 (32-bit fallback)
├── jre/windows-x64/      ← JRE 8 x64 (64-bit, MPR 3D support)
├── viewer-linux.sh
├── viewer-win32.l4j.ini
└── weasis-viewer.bat
```
Note: NO DICOMDIR on disc (paths incompatible with flat layout).

## Known Issues
- SourceForge blocks automated downloads (JavaScript redirect). Setup opens browser for manual download.
- Java outputs version info to stderr, causing PowerShell to treat it as error. Use `cmd /c` to capture.
- PACS ZIP nests DCM files deep inside viewer-mac.app/Contents/DICOM/ - burn.ps1 searches recursively.
- viewer-win32.exe (Launch4j) has hardcoded paths for PACS structure, doesn't work in flat layout.
- DICOMDIR from PACS ZIP references viewer-mac.app paths, must be excluded from disc.
- Weasis caches OSGI bundles in `%USERPROFILE%\.weasis\cache-XXXXXXXX\`. Corrupted cache from failed launches can slow startup. Felix auto-cleans corrupted bundles on next launch but it takes time.
- Windows 10+ blocks autorun on optical media. User must right-click > Open disc, then run start-weasis.bat.

## Current Status (2026-02-21)
### WORKING:
- burn.bat + burn.ps1: full burn pipeline (extract ZIP, copy DICOM, copy Weasis, IMAPI2 burn)
- start-weasis.bat: launches Weasis with automatic DICOM loading (absolute paths, cache cleanup)
- Tested successfully: patient PANCELEA, EVGHENIA (CT Head, 160 DICOM files, 5 series)
- Multiple optical drive selection
- Disc works standalone (start-weasis.bat from DVD launches correctly)
- First launch ~5 min (reading from optical), second launch ~3 min (bundles cached)
- Scrolling smooth after second launch

### KNOWN LIMITATIONS (32-bit JRE):
- MPR 3D on 625 images (1.5mm CT) fails with `-Xmx768m` (insufficient memory for OpenCV)
- Increasing to `-Xmx1280m` on 32-bit makes scrolling and everything worse (not enough native memory)
- **Solution implemented**: dual JRE (x86 + x64) with architecture auto-detection

### SESSION 2026-02-21 (latest changes):

#### Tested disc with single JRE x86 (768m):
- Launch: 5 min first time, 3 min second time (bundles cached)
- Scrolling: smooth after second launch
- MPR 3D on 625 images (1.5mm CT): coronal/sagittal stay at 0%, never load
- MPR 3D on 125 images (5mm CT): OpenCV error `alloc.cpp:73: (-4: insufficient memory) Failed to allocate 524288 bytes`

#### Tested -Xmx1280m on 32-bit JRE - WORSE:
- Scrolling became jerky/difficult (images jumping around)
- MPR 3D still doesn't work
- Root cause: 32-bit process has ~2GB total address space. 1280m heap leaves too little for native memory (OpenCV, JVM internals, thread stacks). Reverted to 768m.

#### Solution implemented - Dual JRE with auto-detection:
- **setup.ps1** updated: downloads both JRE x86 (38 MB) + JRE x64 (38 MB) from Adoptium
- **start-weasis.bat** rewritten with:
  - Architecture detection via `%PROCESSOR_ARCHITECTURE%` + `%PROCESSOR_ARCHITEW6432%`
  - x64 detected → `jre/windows-x64/` with `-Xmx2048m`
  - x86 fallback → `jre/windows/` with `-Xmx768m`
  - Loading message displayed for 5 seconds: "Se incarca, va rugam asteptati..."
  - Shows which JRE is being used (32-bit/64-bit)
- **burn.ps1** updated: `Test-WeasisPortable` accepts either/both JRE, reports which JREs on disc
- **clean-and-launch.bat** improved: auto-detects disc drive letter (D-I), no longer hardcoded F:\
- **setup.ps1 run successfully**: JRE x64 downloaded (OpenJDK 1.8.0_482), total Weasis+JRE = 485.9 MB
- DVD space remaining for DICOM: ~4.2 GB

#### Memory settings rationale:
- **x86 (32-bit)**: `-Xmx768m` - sweet spot. Higher breaks native memory. MPR 3D not feasible.
- **x64 (64-bit)**: `-Xmx2048m` - plenty of headroom. Should support MPR 3D on large CT studies.
- Never use `-Xmx1280m` on 32-bit - it's worse than 768m for everything.

### SESSION 2026-02-21 (session 2 — fast launch, DVD branding, IMAPI2 fix):

#### start-weasis.bat — Major rewrite (copy-to-HDD as default):
Previous behavior: launched Weasis directly from DVD (~5 min startup due to random I/O on optical media).
New behavior: copies Weasis to local HDD first, then launches from there (~1-2 min total).

**Why 5 min startup from DVD**: OSGI framework (Felix) loads dozens of bundles from `bundle/` folder.
Each bundle = random seek on DVD (~100-200ms per seek vs 0.1ms on SSD). Sequential copy is fast,
random reads are extremely slow on optical media.

**Fast launch flow (Method 2 — default)**:
1. Check free space on `%TEMP%` drive (need ~500 MB) via PowerShell
2. Clean old `%TEMP%\weasis-dvd\` folder from previous session
3. Create temp folder
4. Copy sequentially from DVD: JARs, bundles, conf, resources, JRE (only needed architecture)
5. Create junction (`mklink /J`) for DICOM → DVD (no copy, reads from disc)
6. Verify 5 essential files exist (weasis-launcher.jar, felix.jar, substance.jar, javaw.exe, config.properties)
7. Launch Weasis from local copy
8. Verify javaw.exe actually started (antivirus may block execution from `%TEMP%`)

**6 auto-fallback points to direct DVD launch (Method 1)**:
- Insufficient disk space (< 500 MB)
- Old temp folder locked (another Weasis running)
- Cannot create temp folder (permissions)
- Copy failed (files missing after copy)
- Antivirus blocks javaw.exe from `%TEMP%` (checked 3 sec after launch via tasklist)
- PowerShell unavailable → skips space check, continues anyway

**Junction for DICOM**: `mklink /J "%TEMP%\weasis-dvd\DICOM" "D:\DICOM"` — Weasis sees DICOM
as local folder but reads from DVD. No copy needed. If junction fails (policy restrictions),
falls back to xcopy. Junction removed safely with `rmdir` (doesn't delete DVD data).

**Local storage on doctor's PC**: `%TEMP%\weasis-dvd\` (~150-200 MB) — auto-cleaned at next launch.
Plus `%USERPROFILE%\.weasis\` (~100-500 MB cache+prefs) — doesn't accumulate, overwrites each time.
Decision: no cleanup at exit needed, acceptable footprint.

#### autorun.inf — Weasis branding on DVD:
- `icon=viewer-win32.exe,0` — extracts Weasis icon from Launch4j wrapper exe
- `label=Weasis DICOM Viewer` — shows in Windows Explorer
- Windows reads autorun.inf for icon/label even when autorun execution is blocked (Win 10+)

#### burn.ps1 — DVD label + CRITICAL IMAPI2 fix:
- `VolumeName` changed: `"DICOM"` → `"Weasis DICOM"`
- **CRITICAL FIX**: Added `$fsImage.FreeMediaBlocks = $discFormat.TotalSectorsOnMedia`
  - Without this, IMAPI2 `MsftFileSystemImage` defaults to **CD capacity (~700 MB)**
  - Any disc content > 700 MB caused error: `"Adding 'file.DCM' would result in a result image having a size larger than the current configured limit"`
  - Fix reads actual media capacity from inserted disc and sets it on the filesystem image
  - Also displays capacity: `"Capacitate disc: 4489 MB"` for DVD-R
- This bug only appeared with larger DICOM datasets (>700 MB total with Weasis)

#### Weasis scrolling behavior — documented (not fixable):
- **First scroll down**: jerky — each DICOM image decompressed on-demand (lazy decompression)
- **Scroll up / second scroll down**: smooth — pixels already in memory cache
- **MPR orthogonal**: smooth from start — all slices pre-decompressed for 3D volume reconstruction
- This is architectural (Java lazy decompression), no config option to enable prefetch in Weasis 3.7.1
- RadiAnt (C++ native) doesn't have this issue due to multi-threaded prefetch

### PENDING TEST:
- Test fast launch method (Method 2) from burned disc
- Verify copy time (~1-2 min expected)
- Verify antivirus doesn't block javaw.exe from %TEMP%
- Verify Weasis icon appears on DVD in Explorer
- Verify "Weasis DICOM" label on disc
- Test with large DICOM dataset (>700 MB) — IMAPI2 fix should resolve burn error
- Test MPR 3D with 64-bit JRE (-Xmx2048m) on 625 images (1.5mm CT)

### NEXT STEPS:
- Consider removing viewer-win32.exe and weasis-viewer.bat from disc (don't work, cause confusion)
  - Note: viewer-win32.exe is now used for icon (`autorun.inf icon=viewer-win32.exe,0`), so KEEP it
- Create .gitignore (tools/ folder excluded)
- Test on another computer (clean environment, no .weasis cache)

## Future Plans (user's vision)
Build a complete application that:
- Fetches patient list from PACS
- Downloads ZIPs automatically
- Provides simple UI for burn workflow
Current phase: core burn script (BAT + PowerShell).

## Hardware
- Work: internal DVD writer
- Home: external USB DVD writer (MATSHITA DVD-RAM UJ862AS)
- Both work with IMAPI2, script auto-detects and allows selection if multiple drives.
