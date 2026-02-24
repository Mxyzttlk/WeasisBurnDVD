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
| 3 | `Expand-PatientZip` | Extract ZIP (`Expand-Archive`) | 5-30 sec | ⚡ marginal |
| 4 | `Copy-DicomToStaging` | Copy DICOM files + PACS DICOMDIR to staging | 5-30 sec | ⚡⚡ yes |
| 4b | Patient info extraction | Read PatientName/StudyDate from DICOM header | <1 sec | ❌ |
| 5 | `Copy-WeasisToStaging` | NTFS junctions for large dirs + copy small files (~3 MB) | **<2 sec** | ✅ **DONE** |
| 6 | `Copy-TemplatesToStaging` | Copy autorun.inf, start-weasis.bat, splash-loader.ps1 | <1 sec | ❌ |
| 7 | `Build-LauncherWrapper` | Copy weasis.ico, create .lnk shortcut, .bat wrapper | 1-2 sec | ❌ |
| 8 | `Generate-Dicomdir` | Skip if PACS DICOMDIR used; fallback: dcmmkdir | <1 sec | ❌ |
| 8b | Config modification | Add `../DIR000` to `weasis.portable.dicom.directory` | <1 sec | ❌ |
| 9 | `Show-DiscSummary` | Calculate sizes, show disc structure | 1-2 sec | ❌ |
| 10 | **`Burn-ToDisc`** | **IMAPI2: create ISO image + burn at x8** | **3-5 min** | ❌ (x8 max) |
| 11 | `Cleanup` | Delete staging + source ZIP | 2-5 sec | ❌ |

**Optimization implemented (2026-02-25)**: Step 5 used to copy ~225 MB Weasis+JRE to staging every burn (30-60 sec). Now uses **NTFS junctions** for large directories (`bundle/`, `jre/`, `resources/`, `bundle-i18n/`) — instant links, zero bytes copied. Only `conf/` (modified) and loose files (~3 MB) are real copies. IMAPI2 `AddTree` reads transparently through junctions.

**CRITICAL cleanup rule**: `Cleanup` must remove junctions BEFORE `Remove-Item -Recurse`, otherwise PowerShell follows junctions and deletes source files in `tools/weasis-portable/`. Junctions removed with `cmd /c rmdir` (removes link only, not target).

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

### NEXT STEPS:
- Add "Open Source Attribution" section to `templates/README.html`
- ~~Create .gitignore (tools/, downloads/ excluded)~~ DONE
- Test on another computer (clean environment, no .weasis cache)
- Test PACS Burner: auto-login, download interception, burn integration
- Test auto-unlock on locked session

## Known Issues

### WebView2 Runtime detection in registry
- `setup.ps1` Step 3b checks 3 registry paths for WebView2 Runtime
- On some Windows 10/11 PCs with Edge pre-installed, the registry keys don't exist even though WebView2 works (Edge bundles the runtime internally without separate registry entry)
- Result: setup.ps1 may try to install WebView2 Runtime even when it's already functional via Edge
- Impact: low -- the bootstrapper installer is harmless if runtime already exists (installs standalone copy)
- Future fix: also check if `msedgewebview2.exe` exists in Edge or WebView2 paths before attempting install

## Hardware
- Work: internal DVD writer
- Home: external USB DVD writer (MATSHITA DVD-RAM UJ862AS)
- Both work with IMAPI2, script auto-detects and allows selection if multiple drives.
