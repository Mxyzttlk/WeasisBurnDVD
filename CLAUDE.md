# Weasis Burn - DICOM DVD Burn System

## Project Overview
Medical imaging DVD burn system using Weasis portable 3.7.1 viewer with bundled JRE.
Replaces eFilm disc burning with open-source Weasis-based solution.

## Architecture
- **burn.bat** - Entry point. User drags PACS ZIP onto it.
- **scripts/burn.ps1** - Main logic: extract ZIP, organize DICOM, copy Weasis, burn DVD via IMAPI2
- **scripts/setup.ps1** - One-time setup: downloads Weasis portable + JRE 8 x86 + JRE 8 x64 + dcmtk
- **templates/** - autorun.inf, start-weasis.bat, and README.html copied onto each disc
- **tools/weasis-portable/** - Weasis 3.7.1 + Adoptium JRE 8 x86 + x64 (not in git, created by setup)
- **tools/dcmtk/** - dcmtk 3.7.0 toolkit, used for DICOMDIR generation (not in git, created by setup)

## Burn Pipeline — Steps & Optimization Analysis (burn.ps1)

| Step | Function | What it does | Duration | Optimizable? |
|------|----------|-------------|----------|-------------|
| 1 | `Test-WeasisPortable` | Verify Weasis + JRE exist | <1 sec | ❌ |
| 2 | `Clear-Staging` | Delete old staging, create new | 1-3 sec | ❌ |
| 3 | `Expand-PatientZip` | .NET `ZipFile` extraction (2-3x faster than Expand-Archive) | 3-15 sec | ✅ **DONE** |
| 4 | `Copy-DicomToStaging` | NTFS junction for PACS DICOMDIR path; copy only for fallback | **<1 sec** | ✅ **DONE** |
| 4b | Patient info extraction | Read PatientName/StudyDate from DICOM header | <1 sec | ❌ |
| 5 | `Copy-WeasisToStaging` | NTFS junctions for large dirs + copy small files (~3 MB) | **<2 sec** | ✅ **DONE** |
| 6 | `Copy-TemplatesToStaging` | Copy autorun.inf, start-weasis.bat, splash-loader.ps1 | <1 sec | ❌ |
| 7 | `Build-LauncherWrapper` | Copy weasis.ico, create .lnk shortcut, .bat wrapper | 1-2 sec | ❌ |
| 8 | `Generate-Dicomdir` | Skip if PACS DICOMDIR used; fallback: dcmmkdir | <1 sec | ❌ |
| 8b | Config modification | Add `../DIR000` to `weasis.portable.dicom.directory` | <1 sec | ❌ |
| 9 | `Show-DiscSummary` | Calculate sizes, show disc structure | 1-2 sec | ❌ |
| 10 | **`Burn-ToDisc`** | **IMAPI2: create ISO image + burn at x8** | **3-5 min** | ❌ (x8 max) |
| 11 | `Cleanup` | Delete staging + source ZIP | 2-5 sec | ❌ |

**Optimizations implemented (2026-02-25)**:
- **Step 3**: Replaced `Expand-Archive` with `.NET ZipFile.ExtractToDirectory()` — 2-3x faster on large ZIPs. Fallback to `Expand-Archive` if .NET method fails.
- **Step 4**: PACS DICOMDIR path now uses **NTFS junction** for DIR000/ (files not modified, junction safe). Fallback path (dcmmkdir normalization) still uses normal copy.
- **Step 5**: Uses **NTFS junctions** for large directories (`bundle/`, `jre/`, `resources/`, `bundle-i18n/`) — instant links, zero bytes copied. Only `conf/` (modified) and loose files (~3 MB) are real copies. IMAPI2 `AddTree` reads transparently through junctions.

**CRITICAL cleanup rule**: `Cleanup` must remove junctions BEFORE `Remove-Item -Recurse`, otherwise PowerShell follows junctions and deletes source files in `tools/weasis-portable/` and extracted ZIP. Junctions removed with `cmd /c rmdir` (removes link only, not target).

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
- **DICOMDIR generated** by dcmmkdir (dcmtk) with correct paths for our disc layout. Required by medical workstations (Siemens, GE, Philips) to recognize studies on DVD. PACS ZIP DICOMDIR is excluded (has wrong paths for viewer-mac.app structure). Weasis also works without DICOMDIR (uses LoadLocalDicom to scan DICOM/ directly).

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

## DICOMDIR (CRITICAL for medical workstations)
Medical workstations (Siemens, GE, Philips) follow DICOM Part 10 Media Storage standard.
They look for a **DICOMDIR file at the media root** — this is a binary index containing:
- Patient list, studies, series
- Exact paths to each DICOM file on disc

**Without DICOMDIR, medical stations cannot find any studies on the disc.**

### Primary method: PACS DICOMDIR (Exclude Viewer ZIP)
For "Exclude Viewer" ZIPs, the PACS DICOMDIR is **copied directly** to disc root:
- PACS creates DICOMDIR with paths like `DIR000\00000000\00000000.DCM`
- `burn.ps1` copies `DIR000/` to disc root + PACS DICOMDIR as-is
- Paths in DICOMDIR match actual file locations on disc — **zero modification needed**
- Contains complete metadata (PatientBirthDate, SeriesDescription, etc.) from PACS

### Why NOT dcmmkdir:
- dcmmkdir `+id Weasis\DICOM` stores paths relative to `+id` dir, NOT relative to DICOMDIR location
- Generated paths: `CTED\DIR000\...` instead of `WEASIS\DICOM\CTED\DIR000\...` — **path mismatch!**
- dcmmkdir also strips `.DCM` extensions and generates less metadata than PACS
- Running dcmmkdir from disc root fails: rejects non-DICOM files (JARs, BATs) with invalid filenames

### Weasis integration with disc-root DICOM:
- `conf/config.properties` modified at burn time: `weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images,../DIR000`
- `../DIR000` resolved relative to `weasis.portable.dir` (Weasis folder) → disc root's `DIR000/`
- `splash-loader.ps1` and `start-weasis.bat` create junction: `tempDir\DICOM` → `disc\DIR000\`

### Fallback: dcmmkdir (With Viewer ZIP)
For ZIPs where PACS DICOMDIR can't be used (paths don't match disc layout), dcmmkdir generates DICOMDIR.
DICOM files go to `Weasis\DICOM\` and are normalized (strip .DCM, uppercase, max 8 chars).
Known limitation: paths relative to `+id` directory, less metadata. dcmtk installed in `tools/dcmtk/`.

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
At burn time, `burn.ps1` appends `../DIR000` so Weasis finds DICOM at disc root.

## DVD Disc Structure (what gets burned)
```
DVD-R/
├── autorun.inf           ← points to Weasis\start-weasis.bat (disc icon)
├── DICOMDIR              ← COPIED from PACS ZIP (paths match DIR000/ layout)
├── DIR000/               ← patient DICOM files (.DCM extension preserved)
│   ├── 00000000/
│   │   ├── 00000000.DCM
│   │   └── 00000001.DCM
│   └── ...
├── Weasis Viewer.lnk     ← shortcut (cmd.exe -> Weasis\start-weasis.bat)
├── Weasis Viewer.bat      ← backup launcher
└── Weasis/
    ├── start-weasis.bat      ← main launcher (arch detection + splash)
    ├── splash-loader.ps1     ← WPF splash screen + HDD copy logic
    ├── README.html
    ├── weasis.ico
    ├── conf/                 ← config.properties modified: ../DIR000 added to scan paths
    ├── weasis-launcher.jar
    ├── felix.jar
    ├── substance.jar
    ├── bundle/               ← Weasis OSGI bundles
    ├── bundle-i18n/
    ├── resources/
    ├── jre/windows/          ← JRE 8 x86 (32-bit fallback)
    ├── jre/windows-x64/      ← JRE 8 x64 (64-bit, MPR 3D support)
    ├── viewer-linux.sh
    ├── viewer-win32.l4j.ini
    └── weasis-viewer.bat
```
DICOMDIR at disc root references `DIR000\00000000\filename.DCM` — recognized by Siemens, GE, Philips workstations.

## Known Issues
- SourceForge blocks automated downloads (JavaScript redirect). Setup opens browser for manual download.
- Java outputs version info to stderr, causing PowerShell to treat it as error. Use `cmd /c` to capture.
- PACS ZIP nests DCM files deep inside viewer-mac.app/Contents/DICOM/ - burn.ps1 searches recursively.
- viewer-win32.exe (Launch4j) has hardcoded paths for PACS structure, doesn't work in flat layout.
- PACS DICOMDIR from "Exclude Viewer" ZIP is now used directly (paths match disc layout). "With Viewer" ZIP DICOMDIR still has wrong paths (viewer-mac.app/...) — fallback to dcmmkdir.
- Weasis caches OSGI bundles in `%USERPROFILE%\.weasis\cache-XXXXXXXX\`. Corrupted cache from failed launches can slow startup. Felix auto-cleans corrupted bundles on next launch but it takes time.
- Windows 10+ blocks autorun on optical media. User must right-click > Open disc, then run start-weasis.bat.
- **PACS Burner Settings dialog**: ComboBox text in "Burning" section (Writer, Viteza) is barely visible — dark gray on dark background. WPF default ComboBox template ignores `Foreground` property on the selected item display area. Tried: XAML style, ComboBoxItem with explicit Foreground, `TextElement.Foreground` attached property — none fully work. Needs custom ControlTemplate for ComboBox or alternative UI approach (e.g. TextBlock + popup).
- **~~Windows "Insert disc" dialog after burn~~**: FIXED. IMAPI2 COM objects not released + MCN not disabled before eject → Windows detected empty drive. Fix: `ReleaseComObject` all burn COM objects before eject, `DisableMcn()` → `EjectMedia()` → `EnableMcn()`, `GC::Collect()`.

## Licensing — DVD Disc Components

All components on the burned DVD are open-source. Custom scripts (burn.ps1, start-weasis.bat, splash-loader.ps1, launcher.cs) are our own code with no OSS license obligations.

### Component Licenses

| Component | Version | License | Obligation |
|-----------|---------|---------|------------|
| **Weasis** | 3.7.1 | EPL-2.0 OR Apache-2.0 (choose Apache) | Include license text, retain notices |
| **Adoptium JRE** | 8 (x86 + x64) | GPL-2.0 WITH Classpath-exception-2.0 | Point to source repo; keep LICENSE/NOTICE files |
| **Apache Felix** | various | Apache-2.0 | Include license text |
| **Substance** | (bundled) | BSD-3-Clause | Attribution |
| **OpenCV** | 4.5.1-dcm | Apache-2.0 | Include license text |
| **Jackson** | 2.12.3 | Apache-2.0 | Include license text |
| **JAXB-OSGi** | 2.3.2 | CDDL-1.0 or GPL-2.0 | Include license text |
| **Jakarta.json** | 1.1.6 | EPL-2.0 or GPL-2.0 | Include license text |
| **SLF4J** | 1.7.30 | MIT | Attribution |
| **Docking Frames** | 1.1.3p1 | LGPL-2.1 or BSD | Attribution |
| **Launch4j wrapper** | (exe shell) | MIT + BSD-3 | Attribution |
| **WebView2 SDK** | (app only, not on DVD) | MIT | Attribution |

### License Files on Disc

JRE license files are automatically included on every burned DVD:
```
jre/windows/LICENSE              ← GNU GPL-2.0 full text
jre/windows/ASSEMBLY_EXCEPTION   ← OpenJDK Classpath Exception
jre/windows/NOTICE               ← Eclipse Temurin notice
jre/windows/THIRD_PARTY_README   ← All JRE bundled library licenses (3,371 lines)
jre/windows-x64/                 ← Same files for x64 JRE
```

### Source Code Pointers (GPL compliance)

- **Adoptium JDK 8u**: https://github.com/adoptium/jdk8u
- **Weasis**: https://github.com/nroduit/Weasis (upstream)
- **Apache Felix**: https://github.com/apache/felix-dev

### Compliance Notes

1. **JRE Classpath Exception**: Allows linking with non-GPL code (our scripts, Weasis bundles). No source distribution required on disc — pointing to upstream repo is sufficient.
2. **Weasis dual license**: We choose Apache-2.0 (simpler, no source disclosure required). Apache-2.0 requires: include license text, retain NOTICE files, state changes.
3. **LGPL (Docking Frames)**: Bundled as separate JAR in bundle/ — user can theoretically replace it. LGPL allows dynamic linking without GPL contamination.
4. **Our custom code**: launcher.cs, splash-loader.ps1, burn.ps1, start-weasis.bat — no OSS license needed. Not derivative works of any GPL component.
5. **WebView2 SDK**: MIT licensed, used only in PACS Burner desktop app (not on DVD).

### TODO
- Add "Open Source Attribution" section to `templates/README.html` with component list + source links

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

#### splash-loader.ps1 — NEW: WPF GUI Splash Screen
Replaced CMD text progress with a proper graphical window using PowerShell WPF.

**Architecture**:
- `start-weasis.bat` — simplified to thin wrapper: detects architecture, launches PowerShell splash
- `splash-loader.ps1` — NEW: WPF GUI with all copy/verify/launch logic
- `burn.ps1` — updated to copy splash-loader.ps1 to disc

**GUI Features**:
- 500x420px borderless window, dark theme (#1E1E1E), Weasis green (#0F9B58) accents
- Logo (logo-button.png from disc), title "Weasis v3.7.1"
- Animated "Loading..." text with cycling dots (DispatcherTimer 400ms)
- Localized wait message based on system language
- Determinate progress bar (0-100%) with 6 copy steps
- Color-coded log area (Consolas): green [OK], red [X], yellow [!], green [n/6]
- JRE architecture label bottom-right
- Window is draggable (borderless, MouseLeftButtonDown → DragMove)
- Auto-closes 1.5 sec after Weasis launches successfully

**Multilingual support (RO/RU/EN)**:
- Detects via `(Get-Culture).TwoLetterISOLanguageName`
- ALL text is translated — UI labels AND log messages (~25 strings per language)
- Romanian (ro), Russian (ru), English (default)

**32-bit warning**:
- If x86 architecture detected, shows warning screen BEFORE loading:
  "Arhitectura calculatorului este pe 32 de biți. Se recomandă utilizarea aplicației RadiAnt pentru o experiență optimă."
- Two buttons: "Continuă" (green) / "Închide" (red) — both translated
- "Continuă" → proceeds to copy/launch; "Închide" → closes, exit

**Background worker**:
- Copy operations run in MTA runspace (separate thread)
- UI updates via Dispatcher.Invoke() (thread-safe)
- WPF objects (Run, LineBreak, Brush) created exclusively on UI thread
- Completion timer (500ms) polls Completed flag, closes window

**3-tier fallback chain**:
1. WPF splash (copy to HDD + launch from temp) — normal experience
2. DVD fallback WITH GUI (splash shows message, launches from disc) — if copy fails
3. CMD fallback WITHOUT GUI (text in cmd.exe) — if PowerShell/WPF completely unavailable

**DVD disc structure change**:
- Added `splash-loader.ps1` (~12 KB) — negligible space impact

#### burn.ps1 — duplicate header fix
- Removed duplicate "DICOM DVD Burn - Weasis Portable" header from burn.ps1 (was in both burn.bat and burn.ps1)

### SESSION 2026-02-21 (session 3 — splash-loader.ps1 debugging & fixes):

#### Bug 1: UTF-8 BOM encoding (Cyrillic parsing failure)
- **Symptom**: PowerShell threw parsing errors on Russian strings (Cyrillic characters)
- **Root cause**: `splash-loader.ps1` saved as UTF-8 without BOM. PowerShell 5.1 defaults to ANSI encoding, cannot parse UTF-8 multibyte characters without BOM marker.
- **Fix**: Created `scripts/fix-encoding.ps1` helper that re-saves file with UTF-8 BOM:
  ```powershell
  $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)
  $utf8Bom = [System.Text.UTF8Encoding]::new($true)
  [System.IO.File]::WriteAllText($filePath, $content, $utf8Bom)
  ```
- **IMPORTANT**: Must re-run `fix-encoding.ps1` after ANY edit to `splash-loader.ps1` to maintain BOM.

#### Bug 2: JavaMem parameter name conflict
- **Symptom**: `-JavaMem "-Xms64m -Xmx2048m"` — PowerShell interpreted `-Xmx2048m` as a parameter name (starts with `-`)
- **Root cause**: CMD strips inner quotes when passing to PowerShell via `-File`. PowerShell then sees `-Xms64m -Xmx2048m` as two separate tokens, interprets `-Xmx2048m` as an unknown parameter.
- **Fix**: Removed `-JavaMem` parameter entirely. `splash-loader.ps1` determines memory internally from `-ArchLabel`:
  ```powershell
  if ($ArchLabel -eq "64-bit") { $JavaMem = "-Xms64m -Xmx2048m" }
  else { $JavaMem = "-Xms64m -Xmx768m" }
  ```

#### Bug 3: CMD trailing backslash escaping quotes
- **Symptom**: PowerShell prompted for `JreDir` parameter even though it was passed on command line.
- **Root cause**: `%~dp0` always ends with `\`. In CMD: `-DiscPath "%~dp0"` becomes `-DiscPath "E:\path\"`. The `\"` at the end escapes the closing quote. CMD treats everything after as part of DiscPath value, consuming `-JreDir` and its value.
- **Fix**: Changed `"%~dp0"` to `"%~dp0."` in `start-weasis.bat`. The dot (current directory) prevents `\"` escape. In `splash-loader.ps1`, path normalized with `[System.IO.Path]::GetFullPath($DiscPath)` which converts `E:\path\.` → `E:\path\`.

#### Bug 4: closeTimer closure scoping (null reference)
- **Symptom**: Error `"You cannot call a method on a null-valued expression"` at `$closeTimer.Stop()` (line 613)
- **Root cause**: `$closeTimer` is a local variable inside the completion timer's Tick handler. The `Add_Tick` closure for the close timer runs later, when `$closeTimer` is already out of scope (null in PowerShell closure).
- **Fix**: Replaced `$closeTimer.Stop()` with `$this.Stop()`. In PowerShell event handlers, `$this` refers to the sender (the DispatcherTimer that fired the Tick event). Applied to both close timer instances (fallback 3sec and success 1.5sec).

#### Files modified this session:
- **`templates/splash-loader.ps1`** — 4 bug fixes (encoding, JavaMem removal, path normalization, $this.Stop)
- **`templates/start-weasis.bat`** — trailing dot fix (`%~dp0.`)
- **`scripts/fix-encoding.ps1`** — NEW helper script for UTF-8 BOM re-save

#### Current splash-loader.ps1 parameter interface:
```
param(
    [Parameter(Mandatory=$true)][string]$DiscPath,   # Path to disc root (normalized internally)
    [Parameter(Mandatory=$true)][string]$JreDir,     # Relative JRE path (e.g., "jre\windows-x64")
    [Parameter(Mandatory=$true)][string]$ArchLabel   # "64-bit" or "32-bit" (determines JavaMem internally)
)
```

Called from BAT:
```batch
powershell -sta -nologo -noprofile -ExecutionPolicy Bypass -File "%~dp0splash-loader.ps1" -DiscPath "%~dp0." -JreDir "%JRE_DIR%" -ArchLabel "%ARCH_LABEL%" 2>nul
```

#### Test results this session:
- GUI splash screen launches successfully ✓
- Parameters pass correctly from BAT to PS1 ✓
- Weasis opens from local copy ✓
- Window auto-closes after Weasis starts ✓ (closeTimer fix)
- No PowerShell errors in console ✓ (pending re-test after Bug 4 fix)

### PENDING TEST:
- Test WPF splash screen from burned disc
- Verify logo loads from disc `resources/images/logo-button.png`
- Verify animated loading dots
- Verify progress bar advances through [1/6]-[6/6]
- Verify color-coded log messages
- Verify window auto-closes when Weasis opens
- Verify 32-bit warning appears on x86 systems
- Verify language detection (test with RO/RU/EN system locale)
- Verify DVD fallback with GUI when copy fails
- Verify CMD fallback when PowerShell unavailable
- Verify Weasis icon on DVD in Explorer
- Verify "Weasis DICOM" label on disc
- Test with large DICOM dataset (>700 MB) — IMAPI2 fix
- Test MPR 3D with 64-bit JRE (-Xmx2048m)

### SESSION 2026-02-22 (viewer-win32.exe launcher replacement):

#### Problem: Users click viewer-win32.exe instead of start-weasis.bat
On the DVD, users instinctively click the `.exe` file (has an icon, looks like an app) instead of `start-weasis.bat`. But the original `viewer-win32.exe` (Launch4j wrapper) doesn't work in our flat disc layout — it has hardcoded paths from the PACS structure.

#### Solution: Replace viewer-win32.exe with custom C# launcher
Created a tiny C# program that launches `start-weasis.bat` when clicked. Compiled with the Weasis icon so it looks identical to the original.

**New files:**
- **`templates/launcher.cs`** — C# source (30 lines), uses P/Invoke MessageBox for errors:
  ```csharp
  // Finds start-weasis.bat in same directory as exe, launches it
  // Shows error MessageBox if bat not found
  // Compiled as /target:winexe (no console window)
  ```
- **`templates/weasis.ico`** — Icon extracted from original viewer-win32.exe (766 bytes)

**Modified files:**
- **`scripts/burn.ps1`** — Added `Build-LauncherExe` function (Step 7):
  - Uses `csc.exe` from .NET Framework (built-in on all Windows)
  - Compiles `launcher.cs` + `weasis.ico` → `viewer-win32.exe` in staging
  - Overwrites the original 54 KB Launch4j exe with our 5.5 KB launcher
  - **Fail-safe**: If csc.exe missing or compilation fails, keeps original exe on disc
  - Steps renumbered: was 7 steps, now 10 steps (7=Build, 8=Summary, 9=Burn, 10=Cleanup)

**How it works on disc:**
1. User opens DVD, sees `viewer-win32.exe` with Weasis icon → clicks it
2. Our launcher starts `start-weasis.bat` (no console window from the exe itself)
3. `start-weasis.bat` detects architecture, launches WPF splash screen
4. Splash copies Weasis to HDD, launches Weasis

**Compilation details:**
- Compiler: `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` (always present)
- Flags: `/target:winexe /win32icon:weasis.ico /nologo`
- Output size: 5.5 KB (vs 54 KB original)
- Icon extracted via: `[System.Drawing.Icon]::ExtractAssociatedIcon()`

**Original viewer-win32.exe in tools/weasis-portable/ is NOT modified** — only the staging copy is replaced during burn.

#### Licensing analysis (all components on DVD):

| Component | License | Source disclosure? | Key obligation |
|---|---|---|---|
| Weasis 3.7.1 | EPL-2.0 OR Apache-2.0 (choose Apache) | No (under Apache) | Include license text, retain notices |
| Adoptium JRE 8 | GPLv2 + Classpath Exception | Point to source repo | Keep LICENSE/NOTICE files (already in jre/) |
| Apache Felix | Apache 2.0 | No | Include license text |
| Substance | BSD | No | Attribution |
| Launch4j wrapper | MIT + BSD-3 | No | Attribution |
| OpenCV | Apache 2.0 | No | Include license text |
| Our launcher.cs | Own code, no license needed | N/A | N/A |

**JRE compliance**: `LICENSE`, `ASSEMBLY_EXCEPTION`, `NOTICE`, `THIRD_PARTY_README` already exist in `jre/windows/` and `jre/windows-x64/` — copied to disc automatically by `Copy-WeasisToStaging`.

**Recommended**: Add license attributions to `README.html` + JRE source pointer (`https://github.com/adoptium/jdk8u`).

### PENDING TEST:
- Test WPF splash screen from burned disc
- Test viewer-win32.exe launcher from burned disc (does clicking exe launch start-weasis.bat?)
- Verify logo loads from disc `resources/images/logo-button.png`
- Verify animated loading dots
- Verify progress bar advances through [1/6]-[6/6]
- Verify color-coded log messages
- Verify window auto-closes when Weasis opens
- Verify 32-bit warning appears on x86 systems
- Verify language detection (test with RO/RU/EN system locale)
- Verify DVD fallback with GUI when copy fails
- Verify CMD fallback when PowerShell unavailable
- Verify Weasis icon on DVD in Explorer
- Verify "Weasis DICOM" label on disc
- Test with large DICOM dataset (>700 MB) — IMAPI2 fix
- Test MPR 3D with 64-bit JRE (-Xmx2048m)
- Add license attributions to README.html

### SESSION 2026-02-23 (PACS Burner application):

#### PACS Burner — PowerShell WPF + WebView2 desktop app

**Purpose**: Replaces manual workflow (browser -> download ZIP -> drag to burn.bat) with integrated app.

**Architecture**:
- `app/pacs-burner.bat` → `app/launch.vbs` → `app/pacs-burner.ps1` (no CMD window)
- PowerShell WPF window with embedded WebView2 (Chromium browser)
- Dark theme (#1E1E1E), toolbar + browser + status bar layout
- Settings stored in `app/settings.json` (passwords DPAPI-encrypted)
- WebView2 user data (cookies/cache) in `%APPDATA%\WeasisBurn\WebView2Data\`
- Downloads intercepted to `downloads/` folder

**Files created:**
- `app/pacs-burner.ps1` — main application (~860 lines)
- `app/pacs-burner.bat` — launcher (calls launch.vbs)
- `app/launch.vbs` — VBS wrapper to hide CMD window (Run ..., 0, False)
- `app/settings.json` — auto-created on first run

**Files modified:**
- `scripts/setup.ps1` — added Step 3: WebView2 SDK NuGet download
- `CLAUDE.md` — licensing section, PACS Burner documentation

**WebView2 SDK** (in `tools/webview2/`, downloaded by setup.ps1):
- `Microsoft.Web.WebView2.Core.dll` (635 KB, net462)
- `Microsoft.Web.WebView2.Wpf.dll` (81 KB, net462)
- `WebView2Loader.dll` (157 KB, native x64)
- Source: NuGet package `Microsoft.Web.WebView2` (MIT license)
- Requires: WebView2 Runtime (pre-installed with Edge Chromium on Win 10/11)

**Key features:**
1. **Network selector** — External (imagistica.scr.md) / Internal (192.168.22.10) with custom networks
2. **Auto-login** — React-compatible JS injection using native HTMLInputElement setter
3. **Auto-unlock** — detects `.panel.panel-danger` lock screen, fills password
4. **Auto "Exclude Viewer"** — MutationObserver injected via DOMContentLoaded
5. **Download interception** — ZIP files redirected to `downloads/`, progress in status bar
6. **BURN button** — launches burn.ps1 with downloaded ZIP

**Critical PowerShell + WebView2 patterns:**
- `$args` is reserved in PowerShell — all event handlers MUST use `param($s, $e)` not `param($sender, $args)`
- Async init: `CreateAsync()` + DispatcherTimer polling (ContinueWith doesn't work in PS)
- `CoreWebView2InitializationCompleted` event fires on UI thread (safe for WPF)
- React value injection: `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set` + `dispatchEvent(new Event('input', {bubbles: true}))` — direct `.value =` is ignored by React
- CMD window hiding: VBS wrapper with `WScript.Shell.Run ..., 0, False`

**PACS website details (Biotronics 3D):**
- React SPA with MobX state management, Bootstrap 3
- Login: `#login` form, `#username`, `#password`, `button.login-button`
- Lock screen: `.panel.panel-danger`, `#password`, `button.login-button` ("Deblocare")
- Studies list: `input.omnisearch-input`, `.glyphicon-download` button
- Download modal: `.modal-dialog`, checkboxes in `.form-group label.checkbox-inline`
- "Exclude Viewer" = 4th checkbox, "Descarcare" = `.btn.btn-primary`
- Finished: `.well.well-sm h5` text "Finalizat" (green `rgb(92,184,92)`)
- F5 = session lost (re-login required), auto-lock after inactivity

### SESSION 2026-02-25 (burn pipeline optimization — NTFS junctions + .NET ZipFile):

#### Problem: Burn preparation takes 60+ seconds before actual disc burn starts
Every burn copied ~225 MB Weasis+JRE and hundreds of MB DICOM files to a staging folder.
These files are never modified — the copy is wasted time.

#### Solution: NTFS junctions + .NET ZipFile

**NTFS junctions** (instant symlinks for directories) replace file copies where data is read-only:
- `mklink /J "staging/Weasis/bundle" "tools/weasis-portable/bundle"` — instant, 0 bytes
- IMAPI2 `AddTree` reads transparently through junctions (sees real files)
- `rmdir` on junction removes only the link, not the target data

**Files modified:**

**`scripts/burn.ps1`:**
- `Expand-PatientZip` — `Expand-Archive` → `.NET ZipFile.ExtractToDirectory()` (2-3x faster, fallback to Expand-Archive)
- `Copy-DicomToStaging` — PACS path: junction for DIR000/ instead of Copy-Item (files not modified)
- `Copy-WeasisToStaging` — junctions for `bundle/`, `jre/`, `resources/`, `bundle-i18n/`; normal copy only for `conf/` (modified) and loose files (~3 MB)
- `Cleanup` — removes junctions with `cmd /c rmdir` BEFORE `Remove-Item -Recurse` (prevents deleting source data)

**`scripts/burn-gui.ps1`:**
- STEP 3 — `.NET ZipFile` instead of `Expand-Archive`
- STEP 4 — junction for DICOM source root directory
- STEP 6 — junctions for Weasis large directories (same logic as burn.ps1)
- STEP 12 — junction-safe cleanup

**CRITICAL: Cleanup must remove junctions first!**
`Remove-Item -Recurse` follows junctions and deletes source files in `tools/weasis-portable/`.
Pattern: `Get-ChildItem -Recurse -Directory | Where ReparsePoint | ForEach rmdir`

#### Performance impact:
| Step | Before | After |
|------|--------|-------|
| 3. Extract ZIP | 15 sec | 8 sec (.NET ZipFile) |
| 4. DICOM staging | 15 sec | <1 sec (junction) |
| 5. Weasis staging | 30 sec | <2 sec (junctions) |
| **Total prep** | **~60 sec** | **~11 sec** |

#### Also in this session:
- DICOMDIR approach updated: use PACS DICOMDIR directly (previous session fix documented)
- CLAUDE.md burn pipeline table updated with optimization status

### SESSION 2026-02-25 (session 2 — IMAPI2 COM cleanup + "Insert disc" dialog fix):

#### Problem: Windows "Insert disc" dialog after burn
After burning a DVD and ejecting, Windows showed "Please insert a disc into drive F:" dialog.
This confused users and interfered with the workflow.

#### Root cause:
1. IMAPI2 COM objects (`$stream`, `$result`, `$fsImage`, `$discFormat`) stayed referenced after `Write()` — Windows thought a burn operation was still in progress
2. `$recorder.EjectMedia()` triggered Media Change Notification (MCN) — Windows Shell detected empty drive and showed the prompt
3. `$discMaster` and `$preCheck` COM objects from drive enumeration/pre-check were never released

#### Fix implemented (both burn.ps1 and burn-gui.ps1):

**Post-burn cleanup sequence (correct order is critical):**
```powershell
$discFormat.Write($stream)                    # 1. Burn complete

# 2. Release burn-time COM objects BEFORE eject
[Marshal]::ReleaseComObject($stream)
[Marshal]::ReleaseComObject($result)
[Marshal]::ReleaseComObject($fsImage)
[Marshal]::ReleaseComObject($discFormat)

$recorder.DisableMcn()                         # 3. Disable Media Change Notification
$recorder.EjectMedia()                         # 4. Eject (Windows won't detect this)
$recorder.EnableMcn()                          # 5. Re-enable MCN for normal drive operation
[Marshal]::ReleaseComObject($recorder)         # 6. Release recorder
[GC]::Collect(); [GC]::WaitForPendingFinalizers()  # 7. Force garbage collection
```

**Additional COM cleanup:**
- `$discMaster` released after drive enumeration (both scripts)
- `$preCheck` released in `finally` block after media pre-check (burn.ps1)
- Error `catch` blocks also release all COM objects + call `GC::Collect()`

**Why DisableMcn() is needed:**
- MCN (Media Change Notification) is how Windows detects disc insertion/removal
- `DisableMcn()` suppresses the notification → Windows doesn't know disc was ejected → no dialog
- `EnableMcn()` after eject restores normal drive behavior for subsequent operations

#### Files modified:
- **`scripts/burn.ps1`** — `Burn-ToDisc`: COM cleanup + MCN; `Select-OpticalDrive`: release `$discMaster`; pre-check: release `$preCheck` in finally
- **`scripts/burn-gui.ps1`** — STEP 11 (burn): COM cleanup + MCN; drive selection: release `$discMaster`; global catch: COM cleanup

#### COM object lifecycle (burn.ps1):
| Object | Created | Released (success) | Released (error) |
|---|---|---|---|
| `$discMaster` | `Select-OpticalDrive` | After enumeration | — |
| `$preCheck` | Pre-check block | `finally` block | `finally` block |
| `$stream` | `CreateResultImage().ImageStream` | Before eject | `catch` block |
| `$result` | `CreateResultImage()` | Before eject | `catch` block |
| `$fsImage` | `New-Object IMAPI2FS.MsftFileSystemImage` | Before eject | `catch` block |
| `$discFormat` | `New-Object IMAPI2.MsftDiscFormat2Data` | Before eject | `catch` block |
| `$recorder` | `Select-OpticalDrive` | After eject | `catch` block |

### SESSION 2026-02-28 (Tutorial WPF):

#### Tutorial WPF — fereastra cu 7 slide-uri
Creat `templates/tutorial.ps1` — fereastră WPF standalone cu carousel de imagini.

**Funcționalitate:**
- 7 slide-uri cu screenshot-uri adnotate (1.png–7.png) care explică funcționalitățile Weasis
- Apare automat după ce splash-loader.ps1 lansează Weasis cu succes
- Apare la FIECARE lansare până când utilizatorul apasă "Skip" (Nu mai afișa)
- Butonul "Skip" creează `%APPDATA%\WeasisBurn\tutorial-skipped.txt` — nu mai apare ulterior
- Butonul "Închide" / X — doar închide, tutorialul reapare la următoarea lansare
- Selector limbă [RO] [RU] [EN] în title bar — auto-detectare din sistem + alegere manuală
- Navigare: butoane Înapoi/Următor + taste săgeți Left/Right + Escape
- Dark theme #1E1E1E, 920x640px, stil identic cu splash-loader.ps1
- Imagini cache-uite (BitmapImage.Freeze()) pentru navigare rapidă

**Slide-uri:**
| # | Conținut |
|---|---------|
| 1 | ① Așteptați terminarea încărcării; ② Buton oprire loading |
| 2 | ① Panoul cu serii (dublu-clic); ② Seria activă — cerc verde |
| 3 | ① Zona de scrolling — click stâng + sus/jos |
| 4 | ① Butonul MPR — reconstrucție proiecții |
| 5 | Așteptați reconstrucția, barele de progres, navigarea devine fluidă |
| 6 | ① MIP; ② Alegerea ferestrelor; ③ Dispunere vizualizare |
| 7 | ① Instrumente de măsurare |

**Fișiere modificate:**
- `templates/tutorial.ps1` — NOU (~380 linii, WPF tutorial window)
- `templates/splash-loader.ps1` — lansare tutorial.ps1 după success (Start-Process)
- `scripts/burn.ps1` — Copy-TemplatesToStaging: copiază tutorial.ps1 + tutorial/*.png
- `scripts/burn-gui.ps1` — aceleași adăugări

**Structura pe disc:**
```
Weasis/
├── tutorial.ps1
├── tutorial/
│   ├── 1.png ... 7.png
└── ...
```

**Encoding**: tutorial.ps1 salvat cu UTF-8 BOM (fix-encoding.ps1) — necesar pentru Cyrillic (RU)

### SESSION 2026-03-01 (Tutorial fullscreen + burn retry + performance + path fix):

#### 1. Tutorial fullscreen mode
- `templates/tutorial.ps1`: `WindowState="Maximized"` — tutorial pe tot ecranul
- Eliminat `AllowsTransparency="True"` (incompatibil cu Maximized)
- `CornerRadius="0"` pe toate borderele (fullscreen nu necesită colțuri rotunjite)

#### 2. Buton "Continuare" la burn — retry fără re-descărcare
- `scripts/burn-gui.ps1`: când discul nu este gol (deja ars), nu se mai închide automat
- Apare buton **"Continuare"** (verde #0F9B58) + "Închide" fără countdown
- Texte multilingve: `BtnContinue` (Continuare/Продолжить/Continue) + `DiscSwap` (instrucțiuni)
- STEP 11 (burn) wrapat în `while (-not $burnDone)` retry loop
- Flux: disc error → release COM → show Continue/Close → user swap disc → Continue → re-create COM → retry burn
- Worker thread polling: `while ($sync.DiscError -and -not $sync.CancelBurn) { Sleep 500ms }`
- animTimer se oprește la disc error (previne flickering text), repornește la Continue
- Staging folder rămâne intact pe durata disc error (cleanup doar după success)

#### 3. Optimizări performanță (audit)
**tutorial.ps1:**
- `Update-LangButtons` crea 8 SolidColorBrush noi per apel → pre-create frozen singletons ($script:activeBg, etc.)
- 4 brushes: activeBg(#0F9B58), activeFg(White), inactiveBg(#444), inactiveFg(#AAA) — Freeze() + reuse

**burn-gui.ps1:**
- SolidColorBrush create în timer callbacks → pre-create 5 frozen singletons: brushOrange, brushGreen, brushSuccess, brushError, brushDefault
- animTimer nu se oprea la disc error → flickering — adăugat Stop()/Start()

#### 4. CRITICAL FIX: Tutorial nu apărea pe disc ars
- **Simptom**: discul ars, tutorialul nu apare
- **Root cause**: `splash-loader.ps1` folosea `Join-Path $syncHash.DiscPath "Weasis\tutorial.ps1"`
  - DiscPath = `F:\Weasis\` (setat de start-weasis.bat cu `%~dp0`)
  - Rezolvare: `F:\Weasis\Weasis\tutorial.ps1` — cale dublă, fișier inexistent!
- **Fix**: schimbat în `Join-Path $syncHash.DiscPath "tutorial.ps1"` → `F:\Weasis\tutorial.ps1` ✓
- Verificat: `-DiscPath` pasat la tutorial.ps1 funcționează corect pentru imagini (fallback #2: `$DiscPath\tutorial\N.png`)

#### Fișiere modificate:
- `templates/tutorial.ps1` — fullscreen + frozen brushes
- `templates/splash-loader.ps1` — fix path tutorial (eliminat "Weasis\" prefix)
- `scripts/burn-gui.ps1` — Continue button + retry loop + frozen brushes + animTimer fix
- Encoding re-aplicat (fix-encoding.ps1) pe toate fișierele modificate

### SESSION 2026-03-01 (session 2 — Tutorial: wait for Weasis + WorkArea fix):

#### Bug 1 FIX: Tutorial apare ÎNAINTE de Weasis
- **Simptom**: tutorialul apărea instant, Weasis încă nu era vizibil
- **Root cause**: `splash-loader.ps1` lansează `tutorial.ps1` via `Start-Process` imediat după ce javaw.exe e detectat (3 sec), dar fereastra Weasis GUI apare mult mai târziu (OSGI bundle loading)
- **Fix**: adăugat wait loop la începutul `tutorial.ps1` (înainte de `ShowDialog()`):
  ```powershell
  while ($waitElapsed -lt 120) {
      $javawProc = Get-Process -Name "javaw" -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }
      if ($javawProc) { break }
      Start-Sleep -Seconds 2
      $waitElapsed += 2
  }
  ```
  - Verifică `MainWindowHandle -ne [IntPtr]::Zero` — fereastra Weasis e vizibilă
  - Timeout 120 sec (dacă Weasis nu apare, arată tutorialul oricum)
  - Sleep la fiecare 2 sec — nu consumă CPU

#### Bug 2 FIX: Butoanele tutorial sub taskbar
- **Simptom**: în `WindowState="Maximized"` + `WindowStyle="None"`, WPF acoperea și taskbar-ul
- **Root cause**: WPF Maximized cu None style ignoră WorkArea, folosește ecranul complet
- **Fix**: eliminat `WindowState="Maximized"`, adăugat `WindowStartupLocation="Manual"`, setat dimensiunile din `SystemParameters.WorkArea` în `Loaded` event:
  ```powershell
  $wa = [System.Windows.SystemParameters]::WorkArea
  $window.Left   = $wa.Left
  $window.Top    = $wa.Top
  $window.Width  = $wa.Width
  $window.Height = $wa.Height
  ```
  - Respectă taskbar-ul (jos, sus, stânga, dreapta — funcționează cu orice poziție)
  - Vizual identic cu Maximized, dar butoanele sunt vizibile

#### Bug 3 FIX: Tutorial apare ÎN SPATELE Weasis
- **Simptom**: după fix-ul wait loop, tutorialul apărea în spate — Weasis deja avea focus
- **Root cause**: Windows nu permite unei ferestre noi să fure focus de la fereastra activă. După wait loop, Weasis e activ → tutorial se deschide în background
- **Fix**: `Topmost="True"` în XAML + resetare la `False` după 500ms via DispatcherTimer:
  ```powershell
  # In Loaded event:
  $resetTimer = New-Object System.Windows.Threading.DispatcherTimer
  $resetTimer.Interval = [TimeSpan]::FromMilliseconds(500)
  $resetTimer.Add_Tick({
      $this.Stop()
      $window.Topmost = $false
  })
  $resetTimer.Start()
  ```
  - `Topmost=True` forțează fereastra deasupra la deschidere
  - După 500ms devine fereastră normală — user poate comuta cu Alt+Tab/click

#### Fișiere modificate:
- `templates/tutorial.ps1` — wait loop + WorkArea sizing + Topmost trick
- Encoding re-aplicat (fix-encoding.ps1)

### NEXT STEPS:
- ~~**Tutorial WPF**: în lucru~~ DONE
- ~~**Tutorial fullscreen + path fix + performance**~~ DONE
- ~~**Burn retry (Continue button)**~~ DONE
- ~~**Test tutorial pe disc ars**~~ DONE (funcționează, 2 buguri găsite ↑)
- ~~**Fix tutorial: ordinea apariției**~~ DONE (wait for MainWindowHandle)
- ~~**Fix tutorial: butoane sub taskbar**~~ DONE (WorkArea sizing)
- **Test buton Continue** — disc ne-gol → swap → Continue → burn reușit
- Add "Open Source Attribution" section to `templates/README.html`
- ~~Create .gitignore (tools/, downloads/ excluded)~~ DONE
- Test on another computer (clean environment, no .weasis cache)
- Test PACS Burner: auto-login, download interception, burn integration
- Test auto-unlock on locked session
- Test burn with junctions (verify IMAPI2 reads through junctions correctly)
- Test cleanup doesn't delete tools/weasis-portable/ source files
- ~~Test "Insert disc" dialog no longer appears after burn~~ PENDING TEST

## Known Issues

### WebView2 Runtime detection in registry
- `setup.ps1` Step 3b checks 3 registry paths for WebView2 Runtime
- On some Windows 10/11 PCs with Edge pre-installed, the registry keys don't exist even though WebView2 works (Edge bundles the runtime internally without separate registry entry)
- Result: setup.ps1 may try to install WebView2 Runtime even when it's already functional via Edge
- Impact: low -- the bootstrapper installer is harmless if runtime already exists (installs standalone copy)
- Future fix: also check if `msedgewebview2.exe` exists in Edge or WebView2 paths before attempting install

## Future: Pipeline paralel (descărcare + ardere simultană)

### Concept
În timp ce un disc se arde (~5 min), utilizatorul descarcă următoarea investigație din PACS.
Câștig: elimină timpul de descărcare (~30-120 sec) pentru fiecare disc după primul.

### Faze de implementare

**Faza 1 — Burn în background + descărcare simultană (mare impact, simplu)**
- Burn-ul rulează în background thread (nu blochează WebView2)
- Utilizatorul navighează PACS + descarcă în timp ce arde
- Status bar: "Ardere: Pacient X — 45%" + "Descărcat: Pacient Y.zip"
- Când burn-ul termină → notificare + auto-preia următorul ZIP din `downloads/`

**Faza 2 — Coadă vizuală de ardere**
- Lista ZIP-uri descărcate cu status: descărcat / în ardere / ars / eroare
- Auto-detect disc gol → pornește automat următorul burn
- Retry pe eroare
- Asociere ZIP → pacient (PatientName din DICOM header)

**Faza 3 — Extinderi**
- Dual writer support (2 unități optice, ardere paralelă)
- Print label pe disc (LightScribe/discuri cu print)

### Impedimente tehnice
- **Staging unic**: acum e fix `%TEMP%\WeasisBurn` — trebuie `WeasisBurn-<timestamp>` per burn
- **Discul fizic**: un writer = un disc la un moment dat, swap manual 5-15 sec (neautomatizabil)
- **Sesiunea PACS**: se blochează după inactivitate — auto-unlock există dar sesiunea poate expira complet
- **Erori în pipeline**: disc defect (retry?), ZIP corupt (skip?), writer blocat (toate așteaptă)
- **Identificare ZIP→Pacient**: GUI trebuie să afișeze coadă cu nume + studiu, permită reordonare

## Aplicație C# .NET 8 — DicomReceiver (IMPLEMENTAT)

### Locație
`src/DicomReceiver/` — proiect complet, compilabil, WPF desktop app.

### De ce C# (vs PowerShell):
- **fo-dicom** — C-STORE SCP nativ, parsare DICOM, DICOMDIR generation (înlocuiește dcmtk + storescp.exe)
- **WPF** — GUI nativ, fără problemele PowerShell (BOM, `$args`, closure scoping)
- **CommunityToolkit.Mvvm** — `[ObservableProperty]` source generators, MVVM curat
- **Single exe** — `dotnet publish --self-contained -p:PublishSingleFile=true` (~30-50 MB, zero dependențe)

### Structura proiectului

```
src/DicomReceiver/
├── DicomReceiver.csproj          ← .NET 8.0-windows, WPF+WinForms, Nullable enable
├── DicomReceiver.sln
├── App.xaml                       ← Dark theme (#1E1E1E), resurse globale, stiluri Button/ComboBox
├── App.xaml.cs
├── MainWindow.xaml                ← Toolbar + DataGrid studii + Log ListBox + StatusBar
├── MainWindow.xaml.cs             ← Localizare coloane, auto-scroll log, Window_Closing → Shutdown()
├── Helpers/
│   ├── LocalizationHelper.cs      ← RO/RU/EN (60+ chei), auto-detect din CultureInfo
│   ├── RelayCommand.cs            ← ICommand wrapper (Action<object?> + Func<object?,bool>)
│   └── StudyStatusToBoolConverter.cs ← Burn button enabled doar la StudyStatus.Complete
├── Models/
│   ├── ReceivedStudy.cs           ← [ObservableProperty] MVVM model, StudyStatus enum
│   └── AppSettings.cs             ← POCO: AeTitle, Port, IncomingFolder, BurnSpeed, etc.
├── Services/
│   ├── DicomScpService.cs         ← fo-dicom C-STORE SCP server + CStoreScp handler
│   ├── StudyMonitorService.cs     ← Lifecycle Receiving→Complete→Burning→Done/Error
│   ├── BurnService.cs             ← DICOMDIR fo-dicom + apel burn.ps1/burn-gui.ps1
│   └── SettingsService.cs         ← JSON %APPDATA%\WeasisBurn\dicom-receiver-settings.json
├── ViewModels/
│   └── MainViewModel.cs           ← ObservableObject, comenzi, DispatcherTimer 1s, auto-start SCP
├── Views/
│   ├── SettingsDialog.xaml        ← AE Title, Port, Drive IMAPI2, Limba, BurnSpeed
│   └── SettingsDialog.xaml.cs     ← IMAPI2 COM drive enumeration, validare, FolderBrowserDialog
└── Resources/
    └── weasis.ico
```

### NuGet packages

| Package | Versiune | Rol |
|---------|----------|-----|
| **fo-dicom** | 5.1.3 | C-STORE SCP, DICOM parsing, DICOMDIR generation |
| **CommunityToolkit.Mvvm** | 8.4.0 | `[ObservableProperty]`, `ObservableObject` |

### Componente implementate

#### 1. DicomScpService.cs — C-STORE SCP Server (185 linii)
- `DicomServerFactory.Create<CStoreScp>(port)` — pornire server fo-dicom
- `CStoreScp` extends `DicomService` + implements `IDicomCStoreProvider`, `IDicomCEchoProvider`
- Transfer syntaxes acceptate: ExplicitVR LE/BE, ImplicitVR LE, JPEG Lossless/Baseline, JPEG2000, RLE
- Salvare: `incoming/{StudyUID}/{SeriesUID}/{SOPUID}.dcm`
- Static delegates (`OnFileReceived`, `OnLog`) — setat de service, accesat de handler
- `FileReceivedEventArgs`: StudyInstanceUid, PatientName, PatientId, StudyDate, Modality, SeriesInstanceUid, FilePath, FileSize

#### 2. StudyMonitorService.cs — Study Lifecycle (275 linii)
- `ConcurrentDictionary<string, ReceivedStudy>` — thread-safe
- `_seriesPerStudy`, `_imagesPerStudy` — `HashSet<string>` cu `lock()` pentru deduplicare SOPInstanceUID
- **Timeout completion**: `CheckAndCompleteStudies()` — dacă nu primește fișiere `_timeoutSeconds` (default 30s) → `Complete`
- **Re-send handling**: studiu Complete resetat la Receiving dacă primește fișiere noi
- **Mixed modality**: acumulare `CT/MR` dacă serii cu modalități diferite
- **Memory cleanup**: HashSet-uri eliberate pentru studii Done/Error
- `RecalculateStudySize()` — re-enumerare de pe disc la completare (mai precis decât acumulare)
- `ValidateStudyOnDisk()` — verificare fișiere DICOM exist înainte de burn (previne bug eFilm)
- `FormatPatientName()`: `LastName^FirstName` → `LastName FirstName`
- `FormatStudyDate()`: `YYYYMMDD` → `DD.MM.YYYY`

#### 3. BurnService.cs — DVD Burn Integration (296 linii)
- **Validare**: verifică fișiere DICOM exist pe disc, count match
- **PrepareDicomFolder()**: normalizare structură DICOM + DICOMDIR fo-dicom
  ```
  prepared/
  ├── DICOMDIR          ← fo-dicom DicomDirectory.Save()
  └── IMAGES/
      ├── 001/          ← serie (3 cifre)
      │   ├── 00001.DCM ← imagine (5 cifre)
      │   └── 00002.DCM
      └── 002/
  ```
- `DicomDirectory.AddFile(dcmFile, @"IMAGES\001\00001.DCM")` — cale relativă corectă
- **Apel burn.ps1**: `powershell.exe -ExecutionPolicy Bypass -File burn-gui.ps1 -DicomFolder "prepared/" -BurnSpeed 4 -DriveID "..."`
- **Post-burn cleanup**: șterge prepared/ (temp) + incoming/ (dacă AutoDeleteAfterBurn=true)
- **FindProjectRoot()**: walk up 5 levels de la exe, fallback `E:\Weasis Burn`

#### 4. MainViewModel.cs — MVVM ViewModel (309 linii)
- Extends `CommunityToolkit.Mvvm.ComponentModel.ObservableObject`
- `ObservableCollection<ReceivedStudy> Studies` — DataGrid binding
- `ObservableCollection<string> LogEntries` — Log ListBox binding
- **DispatcherTimer 1s**: `CheckAndCompleteStudies()` + `UpdateElapsedTimes()` + `AutoPurgeOldStudies()`
- **BeginInvoke** (async) pentru fo-dicom callbacks → nu blochează threadul DICOM network
- **Auto-start SCP** la pornirea aplicației
- **AutoPurgeOldStudies()**: max 1 purge/tick, doar Done/Error, păstrează active (Receiving/Complete/Burning)
- **Log**: max 500 entries, format `[HH:mm:ss] message`
- **Commands**: ToggleScp, OpenSettings, BurnStudy, DeleteStudy, DeleteAll, ClearLog

#### 5. ReceivedStudy.cs — MVVM Model (65 linii)
- `[ObservableProperty]` pe toate câmpurile → source-generated PropertyChanged
- `[NotifyPropertyChangedFor(nameof(TotalSizeFormatted))]` pe `_totalSizeBytes`
- `enum StudyStatus { Receiving, Complete, Burning, Done, Error }`
- `TotalSizeFormatted` — computed property: B/KB/MB/GB

#### 6. AppSettings.cs — Configuration
```csharp
// DICOM SCP
AeTitle = "WEASIS_BURN"     // AE Title SCP
Port = 4006                  // Port ascultare
IncomingFolder = ""          // Default: {exe}/incoming
StudyTimeoutSeconds = 30     // Timeout completare studiu
BurnSpeed = 4                // Viteza ardere DVD
Language = "auto"            // auto/ro/ru/en
AutoDeleteAfterBurn = true   // Șterge DICOM după burn
MaxStudiesKeep = 0           // 0 = nelimitat (auto-purge doar când AutoDelete=false)
SelectedDriveId = ""         // IMAPI2 drive ID
// PACS Browser
PacsNetworks = [External, Internal]  // Lista rețele PACS (DPAPI parole)
LastPacsNetworkIndex = 0     // Ultima rețea selectată
AutoLogin = true             // Auto-login la navigare
AutoUnlock = true            // Auto-deblocare sesiune
AutoExcludeViewer = true     // Auto-bifare "Exclude Viewer" la descărcare
```
Stocare: `%APPDATA%\WeasisBurn\dicom-receiver-settings.json`

#### 7. SettingsDialog.xaml/.cs — Settings UI
- IMAPI2 COM drive enumeration: `MsftDiscMaster2` → `MsftDiscRecorder2.InitializeDiscRecorder()`
- VolumePathNames → drive letter, VendorId + ProductId → label
- `Marshal.ReleaseComObject()` pe toate obiectele COM (cleanup corect)
- Validare: AE Title non-empty, Port 1-65535, Timeout 5-300, MaxStudies >= 0
- AutoDelete ON → MaxStudies disabled (mutual exclusion)
- `FolderBrowserDialog` (WinForms) pentru incoming folder
- **Secțiune PACS Browser**: 3 CheckBox-uri (AutoLogin, AutoUnlock, AutoExcludeViewer) + "Edit Networks" button
- `EditNetworks_Click` → deschide `PacsNetworkDialog` (deep copy, cancel discarde)

#### 8. LocalizationHelper.cs — Multilingual
- 3 limbi: RO, RU, EN (~100 chei fiecare)
- Auto-detect: `CultureInfo.CurrentCulture.TwoLetterISOLanguageName`
- Fallback: EN dacă cheie lipsă
- Chei UI: AppTitle, Start/Stop, Settings, Burn, Delete, PatientName, StudyDate, Modality, etc.
- Chei status: ScpRunning/Stopped, Receiving/Complete/Burning/Done/Error
- Chei dialog: ConfirmDelete, RestartRequired, NoDrives, etc.
- Chei PACS: TabQueue, TabPacs, PacsNetwork, PacsConnect, PacsDisconnected/Connecting/Connected, PacsDownloading/Complete/Error, AutoLogin, AutoUnlock, AutoExcludeViewer, EditNetworks, NetworkName/Url/Username/Password, etc.

#### 9. App.xaml — Dark Theme Global (216 linii)
- Culori: Background #1E1E1E, Surface #2D2D2D, Border #3E3E3E, Accent #0F9B58, Error #E53935
- Stiluri: `DarkButton`, `AccentButton`, `DangerButton` — ControlTemplate cu CornerRadius, hover/pressed triggers
- **ComboBox custom ControlTemplate** — rezolvă textul invizibil pe dark theme (bug PowerShell WPF cunoscut)
- ComboBoxItem: hover (#3E3E3E), selected (#33FFFFFF)
- Toate brush-urile ca StaticResource — frozen, zero alocare la runtime

#### 10. MainWindow.xaml — Main UI (TabControl)
- **TabControl** cu 2 tab-uri (dark theme TabItem style, border-bottom accent verde):
  - Tab 1 "DICOM Queue" (icon &#xE8A5;) — conținutul existent
  - Tab 2 "PACS Browser" (icon &#xE774;) — `<views:PacsBrowserView />`
- **Toolbar**: Start/Stop SCP (AccentButton), Settings (gear icon Segoe MDL2 Assets), Delete All
- **DataGrid**: Auto-generated=false, IsReadOnly, SelectionMode=Single
  - Coloane: Status (Ellipse color-coded), Patient, StudyDate, Modality, Series, Images, Size, StatusText
  - Status culori: Orange=Receiving, Green=Complete, Blue=Burning, DarkGreen=Done, Red=Error
  - Action buttons: Burn (AccentButton, enabled la Complete via converter), Delete X (red)
- **Log Panel**: ListBox Consolas 11pt, auto-scroll via CollectionChanged
- **Status Bar**: Ellipse (verde=running, roșu=stopped) + StatusText
- GridSplitter între DataGrid și Log
- **Lazy init**: PacsViewModel creat doar la prima selectare tab PACS

### Arhitectura threading

```
[fo-dicom network thread]
    │ CStoreScp.OnCStoreRequestAsync()
    │ → OnFileReceived?.Invoke()
    │ → DicomScpService.FileReceived event
    │
    ▼ Dispatcher.BeginInvoke() ← ASYNC, nu blochează DICOM
[UI thread (WPF Dispatcher)]
    │ _monitorService.OnFileReceived()
    │ Studies.Insert(0, study)
    │
    ├── DispatcherTimer (1 sec)
    │   ├── CheckAndCompleteStudies() → timeout → StudyCompleted event
    │   ├── UpdateElapsedTimes() → StatusText update
    │   └── AutoPurgeOldStudies() → max 1 purge/tick
    │
    └── BurnStudy (async void)
        └── Task.Run(() => PrepareDicomFolder()) → Process.Start(burn.ps1) → WaitForExitAsync()
```

**Key pattern**: `BeginInvoke` (nu `Invoke`) — fo-dicom thread nu așteaptă UI, bulk transfers rămân rapide.

### Study lifecycle

```
Receiving ──(timeout 30s)──→ Complete ──(user click Burn)──→ Burning ──→ Done
    ↑                            │                                        │
    └──(re-send files)───────────┘                                   (AutoDelete)
                                                                         │
                                                              Error ←────┘
```

### Integrare cu PowerShell scripts
- BurnService apelează `scripts/burn-gui.ps1` (sau `burn.ps1` fallback)
- Parametru nou: `-DicomFolder "prepared/"` (nu ZIP, fișiere deja pe disc)
- `-BurnSpeed 4` + `-DriveID "..."` opțional
- burn.ps1 vede DICOMDIR la root → tratează ca PACS ZIP → junctions IMAGES/ pe disc

### DICOMDIR Fix — SESSION 2026-03-07

#### Problema: Siemens vede seriile dar import eșuează
- **Simptom**: discul ars din DicomReceiver, DICOMDIR detectat de stația Siemens, seriile vizibile, dar eroare la import
- **Root cause**: fo-dicom `DicomDirectory.AddFile()` crea PATIENT→STUDY→SERIES dar **ZERO IMAGE records**
  - PACS DICOMDIR: 386 KB, 1581 records (cu IMAGE records + ReferencedFileID)
  - fo-dicom DICOMDIR: 1.9 KB, 7 records (fără IMAGE records!)
  - Toate SERIES aveau `OffsetOfReferencedLowerLevelDirectoryEntity = 0` (fără copii)
  - `catch {}` silențios ascundea erorile din `AddFile()`
- **Alte diferențe**: naming `IMAGES/001/00001.DCM` (3+5 cifre) vs PACS `DIR000/00000000/00000000.DCM` (8+8 cifre)

#### Fix implementat în BurnService.cs:
1. **Naming PACS-compatible**: `IMAGES/` → `DIR000/`, 3-digit → 8-digit, 5-digit → 8-digit, 0-based
2. **Separare copy de DICOMDIR**: mai întâi copiază toate fișierele, apoi generează DICOMDIR separat
3. **Error reporting**: `catch {}` → logging detaliat per fișier
4. **Validare**: verifică nr IMAGE records după generare, alertă dacă = 0
5. **Fallback dcmmkdir**: dacă fo-dicom generează 0 IMAGE records, folosește dcmmkdir din tools/dcmtk/
   - Comandă: `dcmmkdir +r +id "outputDir" +D "DICOMDIR"` — căi relative corecte `DIR000\00000000\00000000.DCM`
6. **PrepareResult**: return object cu FilesCopied, SeriesCount, ImageRecordsAdded, DicomdirSource, Errors

#### Structura disc acum (identică cu PACS):
```
DVD-R/
├── DICOMDIR              ← DIR000\00000000\00000000.DCM paths
├── DIR000/
│   ├── 00000000/         ← serie 0 (8 cifre)
│   │   ├── 00000000.DCM  ← imagine 0 (8 cifre)
│   │   └── 00000001.DCM
│   └── 00000001/
├── Weasis/
└── ...
```

### SESSION 2026-03-07 (session 2 — DICOMDIR VR CS fix + SkipValidation):

#### Problema: fo-dicom AddFile() crea 0 IMAGE records
- **Root cause**: fo-dicom validare strictă VR CS — punctul (`.`) din `.DCM` nu e permis
- **Eroare**: `Content "00000000.DCM" does not validate VR CS: value contains invalid character`
- **Dar**: PACS-ul folosește `.DCM` și Siemens importează fără probleme
- **Fix**: `DicomSetupBuilder().SkipValidation().Build()` — dezactivează validarea fo-dicom
- **Testat**: 12/12 AddFile() OK, DICOMDIR identic cu PACS (`ReferencedFileID = DIR000\00000000\00000000.DCM`)

#### BUG CRITIC găsit la analiza 100 burn-uri consecutive
- `SkipValidation()` era apelat în `TryGenerateDicomdirFoDicom()` — PER BURN
- Este configurație globală statică → apelat de 100 ori redundant
- Dezactivează validarea pentru TOATĂ aplicația inclusiv C-STORE SCP
- **Fix**: mutat în `App.xaml.cs` → `OnStartup()` — apelat O SINGURĂ DATĂ

#### Fișiere modificate:
- `App.xaml.cs` — `SkipValidation()` la startup
- `Services/BurnService.cs` — eliminat `SkipValidation()` din per-burn call

### SESSION 2026-03-07 (session 3 — DicomReceiverService Windows Service):

#### Context: eFilm avea efServer.exe — DICOM SCP ca serviciu Windows
Fișierele DICOM erau primite 24/7, chiar și când GUI-ul eFilm nu era pornit.
Implementat aceeași funcționalitate: Windows Service cu fo-dicom C-STORE SCP.

#### Proiect nou: `src/DicomReceiverService/`
```
src/DicomReceiverService/
├── DicomReceiverService.csproj    ← .NET 8.0-windows Worker Service
├── Program.cs                      ← Host builder + UseWindowsService() + SkipValidation()
├── DicomWorker.cs                  ← BackgroundService — pornește/oprește fo-dicom SCP
├── CStoreScp.cs                    ← Duplicat din DicomReceiver (identic, ~130 linii)
└── SettingsService.cs              ← Citește din C:\ProgramData\WeasisBurn\
```

**NuGet packages:**
| Package | Versiune | Rol |
|---------|----------|-----|
| **fo-dicom** | 5.1.3 | C-STORE SCP (identic cu WPF app) |
| **Microsoft.Extensions.Hosting.WindowsServices** | 8.0.1 | Windows Service integration |

#### De ce duplicare cod (nu shared library):
- Doar ~130 linii de cod SCP + ~40 linii SettingsService
- SCP-ul e stabil, nu se schimbă des
- Shared library ar necesita restructurare 3 proiecte + build/deploy complex
- Duplicarea e pragmatică pentru un cod mic și stabil

#### Settings: partajare între Service și WPF
| Componentă | Citește din | Scrie în |
|---|---|---|
| WPF App | `%APPDATA%\WeasisBurn\` (primar) | `%APPDATA%` + `C:\ProgramData\WeasisBurn\` |
| Service | `C:\ProgramData\WeasisBurn\` | Nu scrie (read-only) |

- `C:\ProgramData` accesibil tuturor conturilor (inclusiv LocalSystem)
- Serviciul citește setările o dată la pornire
- Schimbarea setărilor necesită restart serviciu

#### Detecție port conflict (WPF app)
- `MainViewModel.StartScp()` verifică `ServiceController.Status == Running`
- Dacă serviciul rulează → WPF nu pornește SCP, intră în **service mode**
- StatusText: `"SCP Service — AE: WEASIS_BURN | Port: 4006"`
- `ScanIncomingFolder()` — scanare periodică (1 sec) detectează studii noi din `incoming/`

#### ScanIncomingFolder — folder monitoring în service mode
- DispatcherTimer (1 sec) apelează `ScanIncomingFolder()` când `_serviceMode == true`
- Detectează subdirectoare noi în `incoming/` (fiecare = un StudyUID)
- Parsează un .dcm per study (DicomFile.Open cu SkipLargeTags) pentru metadata
- Contorizează toate fișierele din study dir pentru image count exact
- `_knownStudyDirs` HashSet previne procesare duplicată
- Studiile apar în UI la fel ca în modul normal → burn funcționează normal

#### Buton "Restart Service" în Settings dialog
- Apare lângă Cancel/Save, dezactivat dacă serviciul nu e instalat
- `ServiceController.Stop()` + `WaitForStatus(Stopped)` + `Start()` + `WaitForStatus(Running)`
- Tradus RO/RU/EN (RestartService, ServiceRestarted, ServiceRestartFailed, ServiceNotInstalled)
- Necesită drepturi de administrator

#### Script instalare: `scripts/install-service.ps1`
- `sc.exe create` cu `start= auto` (pornește cu Windows)
- Regulă firewall: `netsh advfirewall firewall add rule` pentru portul DICOM
- Parametru `-Uninstall` pentru dezinstalare completă
- Trebuie rulat ca Administrator

#### Fișiere noi:
- `src/DicomReceiverService/DicomReceiverService.csproj`
- `src/DicomReceiverService/Program.cs`
- `src/DicomReceiverService/DicomWorker.cs`
- `src/DicomReceiverService/CStoreScp.cs`
- `src/DicomReceiverService/SettingsService.cs`
- `scripts/install-service.ps1`

#### Fișiere modificate:
- `DicomReceiver.sln` — adăugat proiectul DicomReceiverService
- `DicomReceiver.csproj` — adăugat NuGet `System.ServiceProcess.ServiceController` 8.0.1
- `Services/SettingsService.cs` — `Save()` scrie suplimentar în `C:\ProgramData\WeasisBurn\`
- `ViewModels/MainViewModel.cs` — service detection + `_serviceMode` + `ScanIncomingFolder()`
- `Views/SettingsDialog.xaml` — buton "Restart Service"
- `Views/SettingsDialog.xaml.cs` — `RestartService_Click()` + `UpdateServiceButtonState()`
- `Helpers/LocalizationHelper.cs` — 4 chei noi per limbă (RestartService, etc.)

#### Performanță service (impact minim):
- **Idle (99% din timp)**: ~30-50 MB RAM, 0% CPU
- **Primire studiu**: 1-3% CPU, +5-20 MB temporar
- **Identic cu efServer.exe** — stătea idle ani de zile fără probleme

#### Instalare/Dezinstalare:
```powershell
# Build
dotnet build src/DicomReceiverService -c Release
# Install (Administrator)
.\scripts\install-service.ps1
# Uninstall
.\scripts\install-service.ps1 -Uninstall
```
În producție: installer-ul (MSI/Inno Setup) va instala serviciul automat.

### SESSION 2026-03-07 (session 4 — bug fixes: AutoPurge, ScanIncomingFolder, AutoDelete, burn-gui exit code):

#### Bug 1 FIX: AutoPurge nu ștergea studii Complete
- **Simptom**: studiile Complete se acumulau, nu erau purged când `MaxStudiesKeep` era depășit
- **Root cause**: `AutoPurgeOldStudies()` căuta doar studii Done/Error, ignora Complete
- **Fix**: adăugat Priority 2 — dacă nu există Done/Error de purged, purgează cel mai vechi Complete
- NEVER purgează Receiving sau Burning

#### Bug 2 FIX: Studiile din sesiuni anterioare nu apăreau la restart
- **Simptom**: la repornirea aplicației, studiile primite anterior nu apăreau în DataGrid
- **Root cause**: `ScanIncomingFolder()` era apelat doar din timer în service mode, dar NU la startup
- **Fix**: adăugat apel `ScanIncomingFolder()` direct în constructor (linia 194)
- În service mode, timer-ul face prima scanare la 1 sec — prea târziu
- În non-service mode, timer-ul NU apela ScanIncomingFolder deloc

#### Bug 3 FIX: AutoDelete ștergea fișierele și la eroare de burn
- **Simptom**: dacă burn-ul eșua, fișierele DICOM erau șterse oricum
- **Root cause**: BurnStudyAsync seta `StudyStatus.Error` în catch, dar cleanup-ul după catch verifica doar `AutoDeleteAfterBurn` flag, nu și statusul
- **Fix**: cleanup verifică `study.Status == StudyStatus.Done` înainte de ștergere
- La eroare → studiu rămâne Complete (nu Error) pentru retry
- Fișierele rămân pe disc pentru re-burn

#### Bug 4 FIX: burn-gui.ps1 returna mereu exit 0
- **Simptom**: BurnService vedea exitCode 0 chiar când burn-ul eșua
- **Root cause**: burn-gui.ps1 termina cu `exit 0` necondiționat
- **Fix**: verificare `$sync.Failed` / `$sync.Success` înainte de exit:
  ```powershell
  if ($sync.Failed -or -not $sync.Success) { exit 1 }
  exit 0
  ```

#### Fișiere modificate:
- `ViewModels/MainViewModel.cs` — AutoPurge Priority 2, ScanIncomingFolder la startup
- `Services/BurnService.cs` — cleanup doar la Done, nu la Error
- `scripts/burn-gui.ps1` — exit code corect

### SESSION 2026-03-07 (session 5 — pre-burn disc check cu IMAPI2 polling):

#### Funcționalitate: WaitForDisc — verificare disc înainte de burn
Când utilizatorul apasă Burn, se verifică dacă un disc blank e inserat. Dacă nu, polling 30 sec cu countdown.

**Flux UX:**
```
User clicks Burn
    ↓
study.StatusText = "Așteptare disc..." (status = Burning)
    ↓
Poll IMAPI2 la fiecare 2 sec (max 30 sec = 15 checks)
    ├── Disc detectat → auto-proceed la burn
    └── Timeout 30s → StatusText = "Disc negăsit (F:)"
        → studiu revine la Complete, user apasă Burn = retry
```

#### Implementare:
- **BurnService.cs** — `CheckDiscReady(AppSettings)`: creează COM objects IMAPI2 per apel, verifică `CurrentMediaStatus`, release în `finally`
- **MainViewModel.cs** — `WaitForDisc(ReceivedStudy)`: async loop cu `Task.Delay(2000)`, countdown în StatusText
- **LocalizationHelper.cs** — chei noi: WaitingForDisc, DiscNotFound, DiscDetected (RO/RU/EN)

#### Fișiere modificate:
- `Services/BurnService.cs` — metodă nouă `CheckDiscReady()`
- `ViewModels/MainViewModel.cs` — metodă nouă `WaitForDisc()`, apelată din BurnStudy/BurnSelected
- `Helpers/LocalizationHelper.cs` — 3 chei noi × 3 limbi

### SESSION 2026-03-07 (session 6 — fix "Unknown" patient names + study-info.json):

#### Problema: Studiile apăreau cu "Unknown" după restart
- **Simptom**: după repornirea aplicației, unele studii arătau "Unknown" în loc de PatientName
- **Root cause**: HideAll privacy mode eliminase permanent tag-urile PatientName din fișierele DICOM pe disc
- **Confirmat**: analiza binară a fișierelor — tag-ul (0010,0010) PatientName absent complet din toate fișierele
- **Context**: burn anterior cu HideAll → modificare in-place → burn eșuat → fișiere rămân cu tag-uri șterse → restart → ScanIncomingFolder citește DICOM → "Unknown"

#### Fix: study-info.json — metadata persistentă
- **SaveStudyInfo()**: salvează PatientName, PatientId, StudyDate, Modality, StudyInstanceUid, ImageCount, SeriesCount în `study-info.json`
- Apelat ÎNAINTE de `ApplyPrivacyMode()` — tag-urile sunt încă intacte
- **ScanIncomingFolder()**: citește `study-info.json` FIRST (prioritate), fallback la DICOM headers

#### ScanIncomingFolder() — rescris complet
Gestionează DOUĂ layout-uri de directoare:
1. **Original**: `incoming/{StudyUID}/{SeriesUID}/{SOP}.dcm` (din DicomScpService)
2. **DIR000**: `incoming/{StudyUID}/DIR000/00000000/00000000.DCM` (după RestructureInPlace)

**Metadata priority**:
1. `study-info.json` (salvat de BurnService înainte de privacy) — supraviețuiește HideAll
2. DICOM file headers (poate avea PatientName eliminat de HideAll)

**StoragePath fix**: StudyMonitorService.OnFileReceived() calculează StoragePath urcând 2 nivele de la FilePath — greșit pentru DIR000 layout (dă `study/DIR000` în loc de `study/`). ScanIncomingFolder suprascrie cu calea corectă.

#### Fișiere modificate:
- `Services/BurnService.cs` — `SaveStudyInfo()` nouă, apelată la linia 183 (single) și 407-409 (multi)
- `ViewModels/MainViewModel.cs` — `ScanIncomingFolder()` rescris complet (~230 linii)

### SESSION 2026-03-07 (session 7 — cod audit complet + fix-uri critice):

#### Audit complet: bugs, performanță, memory leaks, resource cleanup

**🔴 BUG CRITIC #1 REZOLVAT: WaitForDisc bloca burn-ul**
- `WaitForDisc()` seta `study.Status = Burning` → `BurnStudyAsync()` verifica `!= Complete` → excepție!
- Burn-ul nu putea porni NICIODATĂ după implementarea WaitForDisc
- Aceeași problemă în `BurnMultipleStudiesAsync()` — prima investigație din listă avea status Burning
- **Fix**: Guard-ul din `BurnStudyAsync` și `BurnMultipleStudiesAsync` acceptă acum atât `Complete` cât și `Burning`:
  ```csharp
  if (study.Status != StudyStatus.Complete && study.Status != StudyStatus.Burning)
      throw new InvalidOperationException("Study is not complete");
  ```

**🔴 BUG MEDIU #2 REZOLVAT: CheckDiscReady detecta orice disc, nu doar blank**
- `(int)CurrentMediaStatus != 0` returna `true` și pentru discuri deja arse (non-blank)
- Utilizatorul vedea "Disc detectat" → burn pornea → burn-gui.ps1 eșua pe disc non-blank
- **Fix**: Verifică flag-urile IMAPI2 corect:
  ```csharp
  int mediaState = (int)format.CurrentMediaStatus;
  bool isBlankOrWritable = mediaState != 0
      && (mediaState & 32768) == 0  // NOT non-empty session
      && (mediaState & 16384) == 0; // NOT erase-required
  ```
  - Respinge discuri cu `NON_EMPTY_SESSION` (32768) și `ERASE_REQUIRED` (16384)
  - Acceptă `RANDOMLY_WRITABLE` (2 = blank) și `OVERWRITE_ONLY` (1 = DVD+RW)

#### Verificat CORECT (fără probleme):
| Componentă | Verificare | Status |
|---|---|---|
| COM cleanup (CheckDiscReady) | `Marshal.ReleaseComObject()` în `finally` | ✅ |
| COM cleanup (SettingsDialog) | Release pe toate obiectele COM | ✅ |
| DicomScpService static fields | Cleared la `Stop()` | ✅ |
| StudyMonitorService HashSets | `TrackingCleaned` flag + cleanup la Done/Error | ✅ |
| ConcurrentDictionary locking | `lock(images)` pe HashSet-uri partajate | ✅ |
| BeginInvoke (nu Invoke) | fo-dicom thread nu blochează UI | ✅ |
| ScanIncomingFolder dedup | `_knownStudyDirs` HashSet | ✅ |
| SaveStudyInfo timing | ÎNAINTE de privacy mode | ✅ |
| RestoreFilesFromStaging | Restaurare la multi-burn failure | ✅ |
| AutoDelete safety | Nu șterge dacă burn eșuat | ✅ |
| DispatcherTimer lifecycle | Start/Stop corect | ✅ |
| Privacy mode cu ReadAll | Închide file handle înainte de Save | ✅ |
| Event handlers lifetime | Aceeași durată cu app-ul | ✅ |

#### Probleme minore (acceptabile, nu necesită fix):
- `AddLog` → `RemoveAt(0)` e O(n) la 500 entries — o dată pe mesaj
- Process burn nu capturează stdout/stderr — funcțional OK, doar exit code
- `_knownStudyDirs` crește dacă foldere șterse extern — string-uri, neglijabil
- Timer iterează Studies de 4 ori/sec — trivial pentru 5-20 studii
- `Shutdown()` nu anulează burn-uri în curs — burn.ps1 continuă independent

#### Fișiere modificate:
- `Services/BurnService.cs` — fix guard BurnStudyAsync + BurnMultipleStudiesAsync + fix CheckDiscReady media state

### SESSION 2026-03-08 (PACS Browser WebView2 — integrare completă în DicomReceiver):

#### Context: port app/pacs-burner.ps1 → C# WPF
Aplicația PowerShell WPF + WebView2 (`app/pacs-burner.ps1`) oferă browser PACS cu auto-login, auto-unlock,
auto "Exclude Viewer", interceptare descărcări ZIP. Portată integral în aplicația C# DicomReceiver ca
tab "PACS Browser" — eliminează necesitatea aplicației separate PowerShell.

#### Arhitectura integrării

```
MainWindow (TabControl)
├── Tab 1 "DICOM Queue"    — conținut existent (toolbar, DataGrid, log, status bar)
└── Tab 2 "PACS Browser"   — PacsBrowserView (UserControl nou)
    ├── Toolbar: ComboBox rețele + Button Conectare + Refresh + Open Downloads
    ├── WebView2 control (Chromium browser integrat)
    └── Status bar: dot culoare + status text + download info

PacsViewModel (logica tab-ului PACS):
├── SetWebView() — primește WebView2 de la code-behind
├── NavigationCompleted → RunPageAutomation() (auto-login + auto-unlock)
├── DOMContentLoaded → InjectModalObserver() (auto exclude viewer)
├── DownloadStarting → interceptare ZIP → PacsDownloadService
└── DownloadStateChanged → ProcessCompletedDownloadAsync()

PacsDownloadService (pipeline descărcare):
├── GetDownloadPath() — cale în downloads/
├── OnBytesReceived() — progres throttled 500ms
└── ProcessCompletedDownloadAsync() — Task.Run():
    ├── ZipFile.ExtractToDirectory()
    ├── Detectare layout ZIP (3 variante)
    ├── Copiere DICOM în incoming/{StudyUID}/
    └── StudyMonitorService.OnFileReceived() per fișier
        → Studiul apare în Tab "DICOM Queue" ca "Complete"
```

#### Fișiere noi (7)

**1. `Models/PacsNetwork.cs`** (~50 linii)
- Model rețea PACS: Name, Url, Username, EncryptedPassword (DPAPI Base64)
- `CryptoHelper` static class: `Encrypt(string)` / `Decrypt(string)`
- `ProtectedData.Protect/Unprotect` cu `DataProtectionScope.CurrentUser`
- `[JsonIgnore] DecryptedPassword` — computed property get/set

**2. `Services/PacsDownloadService.cs`** (~260 linii)
- `GetDownloadPath(originalFilename)` — cale safe în `downloads/`
- `OnBytesReceived(received, total)` — throttled 500ms minim interval
- `ProcessCompletedDownloadAsync(zipPath)` — rulează pe `Task.Run()`:
  - Extrage ZIP cu `ZipFile.ExtractToDirectory()`
  - Detectează 3 layout-uri: "Exclude Viewer" (`DIR000/` la root), "With Viewer" (nested `viewer-mac.app/Contents/DICOM/DIR000/`), flat DCM
  - Copiază fișierele DICOM în `incoming/{StudyUID}/`
  - Parsează metadata cu `DicomFile.Open(path, FileReadOption.SkipLargeTags)`
  - Apelează `StudyMonitorService.OnFileReceived()` per fișier DICOM
- Evenimente: `DownloadProgress`, `DownloadCompleted`, `LogMessage`

**3. `ViewModels/PacsViewModel.cs`** (~490 linii)
- `ObservableObject` cu proprietăți: `StatusText`, `StatusColor`, `DownloadInfo`, `SelectedNetworkIndex`, `NetworkLabels`
- Comenzi: `ConnectCommand`, `RefreshCommand`, `OpenDownloadsFolderCommand`
- `SetWebView(WebView2)` — wire-ează `NavigationCompleted`, `DownloadStarting`, `DOMContentLoaded`, `NewWindowRequested`
- **Auto-login JS** — React native setter:
  ```javascript
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
  + dispatchEvent(new Event('input', {bubbles: true}))
  + submit după 300ms delay
  ```
- **Auto-unlock JS** — detectează `.panel.panel-danger` "Blocat" + aceeași injecție
- **MutationObserver JS** — observă `document.body` childList+subtree, debounce 500ms, caută `.modal-dialog` → "Exclude Viewer" checkbox → click
- **Download interception** — `.zip` redirect la `downloads/`, progres throttled 2/sec, `Completed` → `ProcessCompletedDownloadAsync()`
- Timere: `_autoTimer` (800ms după navigare), `_modalTimer` (1500ms DOMContentLoaded)
- `EscapeJs()` — escape \, ', \n, \r pentru string-uri JS
- `Dispose()` — oprește timere, unwire events, dispose WebView2

**4. `Views/PacsBrowserView.xaml`** (~75 linii)
- UserControl cu 3-row Grid:
  - Row 0 (Auto): Toolbar — TextBlock "Rețea:" + ComboBox rețele + Button "Conectare" (Accent) + Button Refresh + Button "Open Downloads"
  - Row 1 (*): WebView2 control
  - Row 2 (Auto): Status bar — Ellipse (culoare status) + TextBlock status + TextBlock download info
- Dark theme, reutilizează stilurile din App.xaml

**5. `Views/PacsBrowserView.xaml.cs`** (~110 linii)
- `OnLoaded`: lazy WebView2 init (`CoreWebView2Environment.CreateAsync(userDataFolder)` + `EnsureCoreWebView2Async`)
- `UserDataFolder`: `%APPDATA%\WeasisBurn\WebView2Data` (shared cu app PowerShell — păstrează sesiunea/cookies)
- Injectează popup blocker script via `AddScriptToExecuteOnDocumentCreatedAsync`
- Pasează WebView2 la PacsViewModel via `SetWebView()`
- `SetupStatusColorBinding()` — actualizează Ellipse fill când StatusColor se schimbă

**6. `Views/PacsNetworkDialog.xaml`** (~85 linii)
- Dialog modal 600×440 pentru gestiune rețele PACS
- Stânga: ListBox rețele + butoane Move Up/Down
- Dreapta: câmpuri edit (Name, URL, Username, PasswordBox)
- Butoane: Adaugă, Salvează, Șterge, OK, Anulează
- Dark theme identic cu SettingsDialog

**7. `Views/PacsNetworkDialog.xaml.cs`** (~180 linii)
- Deep copy la intrare (anularea discarde modificări)
- `PasswordBox` → `PacsNetwork.DecryptedPassword` (DPAPI transparent)
- Event handlers: Add, Save, Delete, MoveUp, MoveDown, OK, Cancel
- OK auto-saves selecția curentă înainte de închidere
- `ApplyLocalization()` pe toate label-urile

#### Fișiere modificate (6)

**8. `DicomReceiver.csproj`** — 2 NuGet adăugate:
```xml
<PackageReference Include="Microsoft.Web.WebView2" Version="1.0.2903.40" />
<PackageReference Include="System.Security.Cryptography.ProtectedData" Version="8.0.0" />
```

**9. `Models/AppSettings.cs`** — proprietăți PACS noi:
```csharp
public List<PacsNetwork> PacsNetworks { get; set; } = new()
{
    new() { Name = "External", Url = "http://imagistica.scr.md/portal/" },
    new() { Name = "Internal", Url = "http://192.168.22.10/portal/" }
};
public int LastPacsNetworkIndex { get; set; } = 0;
public bool AutoLogin { get; set; } = true;
public bool AutoUnlock { get; set; } = true;
public bool AutoExcludeViewer { get; set; } = true;
```

**10. `MainWindow.xaml`** — wrapat în TabControl:
- Tab 1 "DICOM Queue" (icon &#xE8A5;) — Grid-ul cu 5 rânduri existent
- Tab 2 "PACS Browser" (icon &#xE774;) — `<views:PacsBrowserView />`
- Stil TabItem dark: border-bottom accent verde pe tab selectat, hover #3E3E3E
- `MainTabControl_SelectionChanged` pentru lazy init

**11. `MainWindow.xaml.cs`** — lazy init tab PACS:
- `_pacsViewModel` field — creat la prima selectare tab PACS
- `MainTabControl_SelectionChanged` → `mainVm.CreatePacsViewModel()` factory
- `_pacsViewModel.LogMessage` → `mainVm.AddLogExternal()` (log-ul partajat)
- `Window_Closing` → `_pacsViewModel?.Dispose()`
- Localizare: `TxtQueueTab.Text = L("TabQueue")`, `TxtPacsTab.Text = L("TabPacs")`

**12. `ViewModels/MainViewModel.cs`** — factory + log extern:
- `AddLogExternal(string msg)` — wrapper public peste `AddLog()` privat, thread-safe BeginInvoke
- `CreatePacsViewModel()` — creează `PacsDownloadService` + `PacsViewModel`, wire-ește `DownloadCompleted` → `ScanIncomingFolder()`

**13. `Views/SettingsDialog.xaml`** — secțiune PACS adăugată:
- Height crescut la 680px
- Rows 9-13: PACS section header + 3 CheckBox-uri (AutoLogin, AutoUnlock, AutoExcludeViewer) + Button "Edit Networks"
- RowDefinitions extinse de la 11 la 16 rânduri

**14. `Views/SettingsDialog.xaml.cs`** — load/save PACS settings:
- Constructor deep-copy PACS settings (PacsNetworks, AutoLogin, etc.)
- Populare checkbox-uri PACS
- Save: `Settings.AutoLogin/AutoUnlock/AutoExcludeViewer`
- `EditNetworks_Click` → deschide `PacsNetworkDialog`
- `ApplyLocalization()` — labels PACS section

**15. `Helpers/LocalizationHelper.cs`** — ~36 chei noi × 3 limbi:
- Tab-uri: TabQueue, TabPacs
- Toolbar: PacsNetwork, PacsConnect, PacsRefresh, OpenDownloads
- Status: PacsDisconnected, PacsConnecting, PacsConnected, PacsNavError
- Download: PacsDownloading, PacsDownloadComplete, PacsDownloadInterrupted, PacsDownloadProcessing, PacsDownloadProcessed, PacsDownloadError
- Automatizare: PacsAutoLogin, PacsAutoUnlock, AutoLogin, AutoUnlock, AutoExcludeViewer
- Settings: PacsSectionTitle, EditNetworks
- Dialog rețele: PacsNetworksTitle, NetworkName, NetworkUrl, NetworkUsername, NetworkPassword, AddNetwork, DeleteNetwork, MoveUp, MoveDown, OK, NoNetworks

#### Structura proiectului actualizată

```
src/DicomReceiver/
├── DicomReceiver.csproj
├── App.xaml / App.xaml.cs
├── MainWindow.xaml / .xaml.cs         ← TabControl (Queue + PACS)
├── Helpers/
│   ├── LocalizationHelper.cs          ← ~100 chei × 3 limbi
│   ├── RelayCommand.cs
│   └── StudyStatusToBoolConverter.cs
├── Models/
│   ├── ReceivedStudy.cs
│   ├── AppSettings.cs                 ← + PACS properties
│   └── PacsNetwork.cs                 ← NOU: model + CryptoHelper (DPAPI)
├── Services/
│   ├── DicomScpService.cs
│   ├── StudyMonitorService.cs
│   ├── BurnService.cs
│   ├── SettingsService.cs
│   └── PacsDownloadService.cs         ← NOU: ZIP → incoming/ pipeline
├── ViewModels/
│   ├── MainViewModel.cs               ← + CreatePacsViewModel(), AddLogExternal()
│   └── PacsViewModel.cs               ← NOU: WebView2 + auto-login/unlock/exclude
├── Views/
│   ├── SettingsDialog.xaml / .xaml.cs  ← + PACS section
│   ├── PacsBrowserView.xaml / .xaml.cs ← NOU: WebView2 UserControl
│   └── PacsNetworkDialog.xaml / .xaml.cs ← NOU: edit rețele PACS
└── Resources/
    └── weasis.ico
```

#### NuGet packages actualizate

| Package | Versiune | Rol |
|---------|----------|-----|
| **fo-dicom** | 5.1.3 | C-STORE SCP, DICOM parsing, DICOMDIR |
| **CommunityToolkit.Mvvm** | 8.4.0 | `[ObservableProperty]`, `ObservableObject` |
| **System.ServiceProcess.ServiceController** | 8.0.1 | Detectare Windows Service |
| **Microsoft.Web.WebView2** | 1.0.2903.40 | Browser Chromium integrat (PACS) |
| **System.Security.Cryptography.ProtectedData** | 8.0.0 | DPAPI criptare parole rețele |

#### Patteruri tehnice cheie

**React value injection** (port din pacs-burner.ps1):
- Direct `.value = "text"` e ignorat de React — state intern nu se actualizează
- Soluția: native setter din HTMLInputElement prototype + dispatch `input` event
- React ascultă evenimentul input și actualizează state-ul

**WebView2 shared session**:
- `UserDataFolder` = `%APPDATA%\WeasisBurn\WebView2Data\` — aceeași cale ca app PowerShell
- Cookies și sesiunea sunt păstrate între app-ul C# și cel PowerShell
- Auto-login-ul funcționează datorită sesiunii persistente

**Lazy initialization pattern**:
- `PacsViewModel` creat DOAR la prima selectare tab PACS (nu la startup)
- WebView2 init doar în `PacsBrowserView.OnLoaded`
- Reducere timp startup + memorie

**Download → Study pipeline**:
- WebView2 `DownloadStarting` → redirect la `downloads/`, `e.ResultFilePath` pentru filename
- `BytesReceivedChanged` → progres direct pe UI (throttled 500ms), afișare MB + procent
- Completare: `StateChanged` Completed (primar) SAU file-ready polling timer 3s (fallback — WebView2 bug)
- File-ready check: `FileStream(FileShare.None)` — dacă IOException, WebView2 încă ține handle → retry
- ZIP extract → find DICOM → copy incoming/ → `OnFileReceived()` → `ForceCompleteStudy()` → apare în Queue
- Auto-burn: `DownloadCompleted` event → `RequestBurnDvd()` → `BurnRequested` event → burn-gui.ps1

#### Build status: ✅ 0 erori, 0 warnings

### Module neimplementate încă
1. ~~**PACS Web module** — WebView2 browser (port din pacs-burner.ps1)~~ ✅ IMPLEMENTAT (SESSION 2026-03-08)
2. **IMAPI2 burn nativ C#** — burn direct din C# fără PowerShell — LIPSEȘTE (acum delegă la burn.ps1)
3. **Pipeline paralel** — burn în background + descărcare simultană — LIPSEȘTE
4. **Single exe publish** — neconfigurat
5. **Installer (MSI/Inno Setup)** — instalare automată app WPF + Windows Service + firewall

## DICOM Receive (workflow Siemens/eFilm) — PARȚIAL IMPLEMENTAT

### Concept
Recrearea workflow-ului de la stațiile Siemens: investigațiile se trimit automat prin rețea DICOM
direct la PC-ul de burn, fără descărcare manuală din PACS web. Cel mai rapid flux — studiul se
transmite în timp ce pacientul e încă pe masă.

### Workflow original (eFilm):
1. Stația Siemens (CT/MR) → **DICOM C-STORE** → PC cu eFilm (Win 7)
2. eFilm primea studiile prin rețea → folder local (efServer.exe — serviciu Windows)
3. Operatorul ardea pe disc

### Workflow nou (DicomReceiver):
Două moduri de operare:

| Componentă | Rol | Status |
|------------|-----|--------|
| **DicomReceiverService** (Windows Service) | C-STORE SCP 24/7, primește fișiere | ✅ IMPLEMENTAT |
| **DicomReceiver** (WPF app) | UI: monitorizare studii, DICOMDIR, burn DVD | ✅ IMPLEMENTAT |
| **PACS Web module** (WebView2) | Browser PACS integrat + descărcare ZIP | ✅ IMPLEMENTAT |

### Ce funcționează acum:
- ✅ fo-dicom C-STORE SCP (înlocuiește dcmtk storescp.exe)
- ✅ Windows Service — primește DICOM chiar și când WPF app nu rulează
- ✅ WPF app detectează serviciul → nu pornește SCP propriu (evită port conflict)
- ✅ Scanare folder incoming/ — studiile primite de serviciu apar în UI
- ✅ Study lifecycle: Receiving → Complete (timeout 30s) → Burning → Done
- ✅ DICOMDIR fo-dicom cu SkipValidation() — structură identică cu PACS
- ✅ Fallback dcmmkdir dacă fo-dicom eșuează
- ✅ Settings partajate (WPF → ProgramData → Service)
- ✅ Buton "Restart Service" în Settings dialog
- ✅ **PACS Browser** — WebView2 integrat cu auto-login, auto-unlock, auto "Exclude Viewer"
- ✅ **Descărcare ZIP din PACS** — interceptare, progres, extragere → studiu în Queue
- ✅ **Rețele PACS** — editare/adăugare/ștergere/reordonare, parole DPAPI
- ✅ **Traduceri PACS** — RO/RU/EN pentru toate textele browser PACS

### Configurare pe stația Siemens (face inginerul/administratorul):

| Câmp | Valoare |
|------|---------|
| AE Title | `WEASIS_BURN` (configurabil din Settings) |
| IP | adresa PC-ului receptor |
| Port | `4006` (configurabil din Settings) |

### Detectarea completării studiului
- **Timeout** (implementat): nu mai primești fișiere `StudyTimeoutSeconds` (default 30s) → studiu `Complete`
- Re-send handling: studiu Complete resetat la Receiving dacă primește fișiere noi

### DICOMDIR
- **Primar**: fo-dicom `DicomDirectory` cu `SkipValidation()` — structură `DIR000\00000000\00000000.DCM`
- **Fallback**: dcmmkdir din `tools/dcmtk/` dacă fo-dicom generează 0 IMAGE records

### Cerințe suplimentare
- **Firewall**: portul ales trebuie deschis pe PC-ul receptor
- **Rețea**: PC-ul trebuie să fie în aceeași rețea/VLAN cu stațiile DICOM
- **C-ECHO**: storescp suportă și C-ECHO (ping DICOM) — util pentru verificare conectivitate

### Informații stații Siemens (recon 2026-02-28)
- **Software**: syngoMMWP VE52A, OS: Windows XP/Server 2003 (Version 5.2.3790)
- **User OS**: meduser
- **Rețea**: 192.168.22.0/24 (aceeași cu PACS-ul), gateway gol (rețea locală directă)
- **Stație #1 IP**: 192.168.22.51 (celelalte 3 — de aflat)
- **4 stații total** — fiecare trebuie configurată identic (add destination)
- **DICOM General**: Study Transfer [SCP + SCU] (poate trimite și primi), Print [SCU]
- **DICOM Network Nodes**: pagina unde se adaugă destinații (Select Host, Host Name, TCP/IP, LAN/RAS, buton Test)
- **AutoTransfers**: dezactivat momentan (trebuie activat + adăugat destinația)
- **Offline Devices**: gol (fără service key)
- **Routing**: Configure Gateway + Control Rip Listener (nu DICOM routing)
- **Service key**: necesar pentru modificări — contactat inginer Siemens
- **AE Title-uri + IP-uri** — configurabile din app Settings, nu hardcodate
- **AE Title stații**: de aflat (din consola operatorului sau de la admin PACS)

### eFilm 3.1.0 — configurație recuperată (recon 2026-02-28)
- **Versiune**: eFilm 3.1.0 (din efTitle.txt)
- **AE Title eFilm**: probabil **`eFilmKKD`** (din DICOMdb.mdb: "Merge eFilmKKD", referință "nKKD"; KKD = abrevierea instituției)
- **Port eFilm**: necunoscut (valorile stocate binar în MDB, nu extrase ca text)
- **Build**: 07.53
- **DICOM folder**: studiile stocate per Study Instance UID (prefix `1.3.12.2.1107.5.1.4` = Siemens)
- **DICOMdb.mdb** (Access): tabelele Server + DolphinServer conțin configurația DICOM
  - Schema Server: Server ID, AE Title, Hostname, Port, Description, Type, Format, Priority, etc.
  - Schema DolphinServer: Server ID, AE Title, Hostname, Port, Description, Type, DeviceID, Default, Source
  - Valorile efective binar-encoded, nu extrase — necesită Access sau OleDb pentru citire
- **SOP Classes suportate** (din pdu.txt):
  - Storage: CT, CR, MR, US, NM, MG, PET, RT, DX, XA, RF, SC (practic totul)
  - Query/Retrieve: PatientRoot, StudyRoot
- **Transfer Syntaxes** (din pdu.txt + SyntaxLists.ini):
  - LittleEndianImplicit, LittleEndianExplicit, BigEndianExplicit
  - JPEG Lossless, JPEG Baseline, JPEG 2000
  - RLE Lossless
  - Organizate per tip: Mono/RGB/YBR, Full/Lossy/Lossless
- **Window/Level Presets**: BrainCT, BoneCT, ChestCT, LungCT, Head & NeckCT, Abdomen/PelvisCT, Ultrasound (3 variante)
- **eFilm.exe.config**: doar .NET 2.0 runtime, nimic DICOM
- **Componente eFilm**: efServer.exe (DICOM SCP), efQueue.exe (coadă), StarBurn.dll (burn CD/DVD)
- **Concluzie**: fo-dicom în C# suportă toate aceste SOP classes și transfer syntaxes nativ — compatibilitate 100%

### TODO — de aflat pentru DICOM Receive

**Critic (fără asta nu merge):**
1. ❌ **AE Title-urile celor 4 stații Siemens** — din consola operatorului sau de la admin PACS
2. ❌ **IP-urile celorlalte 3 stații** — `ipconfig` pe fiecare (știm #1: 192.168.22.51)
3. ❌ **IP static pe PC-ul de burn** — trebuie adresă fixă în 192.168.22.x (dacă DHCP → rezervare la admin)
4. ❌ **Contact inginer Siemens** (service key) — adaugă destinația pe 4 stații + activează AutoTransfers

**Util dar nu urgent:**
5. ❌ **AE Title eFilm confirmat** — probabil `eFilmKKD`, de verificat din eFilm Settings sau DICOMdb.mdb cu Access
6. ❌ **Portul eFilm** — ne arată ce port era deja deschis în firewall
7. ❌ **Firewall pe PC-ul de burn** — portul ales (ex: 4006) trebuie deschis

**Ordinea implementării**: afli datele → eu scriu app-ul C# → inginerul configurează stațiile → testare

### SESSION 2026-03-09 (PACS Browser download pipeline — 6 fix-uri):

#### Context: Portarea pacs-burner.ps1 → C# WebView2 în DicomReceiver
Prima testare reală a pipeline-ului PACS Browser: BURN DVD → auto-download → extract → burn.
Găsite 6 buguri, toate rezolvate.

#### Bug 1: Log-uri duplicate (Defender exclusion apărea de 2 ori)
- **Cauza**: `PacsDownloadService.LogMessage` avea 2 subscriberi — MainViewModel (linia 975) ȘI PacsViewModel (linia 112)
- **Fix**: Eliminat subscriber-ul din MainViewModel; mesajele trec prin PacsViewModel → LogMessage → MainWindow → AddLogExternal

#### Bug 2: "Exclude Viewer" nu se bifa + descărcarea nu pornea
- **Cauza**: JS `indexOf('Descarcare')` nu se potrivea cu HTML `'Descărcare'` (diacritice ă). Și selectori strict (`.form-group label.checkbox-inline`)
- **Fix**: Eliminat verificarea titlului modal (PS nu avea), selectori largi `label` + `indexOf` în loc de `===`
- Aplicat în AMBELE: `StartPacsDownload` (poll modal) și `InjectModalObserver` (MutationObserver)

#### Bug 3: Descărcare în C:\Users\Downloads în loc de E:\Weasis Burn\downloads
- **Cauza**: `Path.GetFileName(e.DownloadOperation.Uri)` pe URL HTTP `/api/download?id=xxx` nu returna nume fișier .zip. PS folosea `$e.ResultFilePath`
- **Fix**: Schimbat la `Path.GetFileName(e.ResultFilePath)` — calea sugerată de browser conține numele real

#### Bug 4: Descărcare blocată la ~88% (StateChanged nu se declanșa)
- **Cauza**: `OnDownloadStateChanged` se dezabona la ORICE stare inclusiv `InProgress`, pierzând `Completed`
- **Fix**: Dezabonare doar la stări terminale (Completed, Interrupted)
- Eliminat `CloseDefaultDownloadDialog` handler și `e.Handled=true` pentru non-ZIP (absente în PS)

#### Bug 5: Progress descărcare rămânea la 0%
- **Cauza**: Progresul trecea prin `PacsDownloadService.OnBytesReceived()` → event → handler — prea indirect, nu ajungea la UI
- **Fix**: Actualizare `DownloadInfo` direct din `BytesReceivedChanged` handler cu throttle 500ms local
- Afișare: `filename — 32.9 / 37.5 MB (87%)`; fără Content-Length: `filename — 32.9 MB`

#### Bug 6: WebView2 StateChanged cu Completed NU se declanșează NICIODATĂ pentru server-ul PACS
- **Simptom**: ZIP complet pe disc, progress la 87%, StateChanged nu vine
- **Încercare 1**: Fallback `BytesReceivedChanged` cu `received >= total` → eroare "file is being use" (WebView2 încă ține handle-ul)
- **Fix final**: Timer polling DispatcherTimer la fiecare 3 secunde:
  1. Verifică `File.Exists(dlPath)`
  2. `new FileStream(dlPath, FileMode.Open, FileAccess.Read, FileShare.None)` — dacă `IOException` → retry
  3. Fișier accesibil → procesare ZIP
- Protecție anti-duplicat: `dlProcessed` bool + `_activeDownloads.Remove()` în fallback timer; `OnDownloadStateChanged` verifică `TryGetValue` → early return dacă fallback deja a procesat

#### Bug 7 (din sesiunea precedentă): Pagina PACS se reîncarcă în loc să ardă
- **Cauza**: `ScanIncomingFolder` apela `OnFileReceived` pe fișiere deja procesate → StudyMonitorService reseta Complete→Receiving → `BurnRequested` vedea status Receiving → `OnBurnCompleted(false)` → `Reload()`
- **Fix**: Early-exit în `ScanIncomingFolder` — studiile Complete/Burning/Done nu sunt re-procesate

#### Fișiere modificate:
- **`ViewModels/PacsViewModel.cs`** — toate fix-urile download (6 buguri)
- **`ViewModels/MainViewModel.cs`** — eliminat subscriber duplicat LogMessage + early-exit ScanIncomingFolder
- **`Services/PacsDownloadService.cs`** — Defender exclusion silențios la non-admin

#### Build: ✅ 0 erori, 0 warnings

#### De testat:
- Fallback timer detectează ZIP finalizat → procesare → studiu în DICOM Queue → burn-gui.ps1 se lansează
- Pipeline complet end-to-end: BURN DVD → download → extract → import → burn

## Hardware
- Work: internal DVD writer
- Home: external USB DVD writer (MATSHITA DVD-RAM UJ862AS)
- Both work with IMAPI2, script auto-detects and allows selection if multiple drives.
