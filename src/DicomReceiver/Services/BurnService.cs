using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using DicomReceiver.Helpers;
using DicomReceiver.Models;
using FellowOakDicom;
using FellowOakDicom.Media;

namespace DicomReceiver.Services;

public class BurnService
{
    public event EventHandler<string>? LogMessage;

    private void Log(string msg) => LogMessage?.Invoke(this, msg);

    /// <summary>
    /// Checks if a blank disc is inserted in the optical drive using IMAPI2 COM.
    /// Returns (ready, driveName) — ready=true if blank media detected.
    /// Each call creates and releases COM objects (no persistent state).
    /// </summary>
    public (bool ready, string driveName) CheckDiscReady(AppSettings settings)
    {
        object? discMaster = null;
        object? recorderObj = null;
        object? formatObj = null;

        try
        {
            // 1. Enumerate drives
            var masterType = Type.GetTypeFromProgID("IMAPI2.MsftDiscMaster2");
            if (masterType == null) return (false, "");

            discMaster = Activator.CreateInstance(masterType);
            if (discMaster == null) return (false, "");

            dynamic master = discMaster;
            if (master.Count == 0) return (false, "");

            // 2. Find recorder (by SelectedDriveId or first drive)
            var recorderType = Type.GetTypeFromProgID("IMAPI2.MsftDiscRecorder2");
            if (recorderType == null) return (false, "");

            string? driveId = null;
            if (!string.IsNullOrEmpty(settings.SelectedDriveId))
            {
                for (int i = 0; i < master.Count; i++)
                {
                    if ((string)master[i] == settings.SelectedDriveId)
                    {
                        driveId = settings.SelectedDriveId;
                        break;
                    }
                }
            }
            driveId ??= (string)master[0]; // Fallback to first drive

            recorderObj = Activator.CreateInstance(recorderType);
            if (recorderObj == null) return (false, "");

            dynamic recorder = recorderObj;
            recorder.InitializeDiscRecorder(driveId);

            // Get drive letter for display
            string driveName = "";
            try
            {
                object? paths = recorder.VolumePathNames;
                if (paths is string[] volPaths && volPaths.Length > 0)
                    driveName = volPaths[0].TrimEnd('\\');
            }
            catch { /* no volume path */ }

            // 3. Check media status
            var formatType = Type.GetTypeFromProgID("IMAPI2.MsftDiscFormat2Data");
            if (formatType == null) return (false, driveName);

            formatObj = Activator.CreateInstance(formatType);
            if (formatObj == null) return (false, driveName);

            dynamic format = formatObj;
            format.Recorder = recorder;
            format.ClientName = "WeasisBurn";

            // IMAPI2 CurrentMediaStatus is a bitmask (IMAPI_FORMAT2_DATA_MEDIA_STATE):
            //   0 = UNKNOWN (no disc / not readable)
            //   1 = OVERWRITE_ONLY         (DVD+RW, BD-RE — writable)
            //   2 = RANDOMLY_WRITABLE      (blank disc — what we want)
            //   4 = APPENDABLE             (multi-session, can add data)
            //   32768 = NON_EMPTY_SESSION  (already burned, not blank)
            //   16384 = ERASE_REQUIRED     (needs erase before use)
            // Blank DVD+R has BOTH bits 2+4 set (mediaState=6): writable AND appendable
            // We accept: any disc with RANDOMLY_WRITABLE(2) or OVERWRITE_ONLY(1) bit set
            // We reject: APPENDABLE-only (4 without 2 = has data), NON_EMPTY_SESSION, ERASE_REQUIRED
            int mediaState = (int)format.CurrentMediaStatus;
            bool isBlankOrWritable = mediaState != 0
                && ((mediaState & 2) != 0 || (mediaState & 1) != 0)  // must be writable (blank or DVD+RW)
                && (mediaState & 32768) == 0  // NOT non-empty session
                && (mediaState & 16384) == 0; // NOT erase-required (needs format first)

            return (isBlankOrWritable, driveName);
        }
        catch
        {
            // IMAPI2 not available or COM error — can't check
            return (false, "");
        }
        finally
        {
            if (formatObj != null) Marshal.ReleaseComObject(formatObj);
            if (recorderObj != null) Marshal.ReleaseComObject(recorderObj);
            if (discMaster != null) Marshal.ReleaseComObject(discMaster);
        }
    }

    /// <summary>
    /// Burns a ZIP file directly by passing it to burn-gui.ps1 -ZipPath.
    /// burn-gui.ps1 handles everything: extraction, staging, disc check (with retry UI), burning, cleanup.
    /// Used for PACS browser flow — no intermediate incoming/ folder needed.
    /// </summary>
    public async Task<bool> BurnZipAsync(string zipPath, AppSettings settings)
    {
        if (!File.Exists(zipPath))
            throw new FileNotFoundException($"ZIP not found: {zipPath}");

        var projectRoot = FindProjectRoot()
            ?? throw new FileNotFoundException("Cannot find project root (scripts/burn.ps1)");

        var burnScript = Path.Combine(projectRoot, "scripts", "burn-gui.ps1");
        if (!File.Exists(burnScript))
            burnScript = Path.Combine(projectRoot, "scripts", "burn.ps1");
        if (!File.Exists(burnScript))
            throw new FileNotFoundException("Burn script not found");

        Log($"Launching burn: {Path.GetFileName(burnScript)} -ZipPath \"{Path.GetFileName(zipPath)}\"");

        var args = $"-ExecutionPolicy Bypass -File \"{burnScript}\" -ZipPath \"{zipPath}\" -BurnSpeed {settings.BurnSpeed}";
        if (!string.IsNullOrEmpty(settings.SelectedDriveId))
            args += $" -DriveID \"{settings.SelectedDriveId}\"";
        if (settings.SimulateOnly)
            args += " -SimulateOnly";
        if (!settings.IncludeTutorial)
            args += " -ExcludeTutorial";

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start burn process");

        await WaitForProcessOrKill(process);

        bool success = process.ExitCode == 0;
        Log(success ? "Burn completed successfully" : $"Burn exited with code {process.ExitCode}");
        return success;
    }

    /// <summary>
    /// Burns a completed study by calling burn.ps1 as an external process.
    /// Restructures DICOM files IN-PLACE (File.Move) to PACS-compatible layout,
    /// generates DICOMDIR, then passes the folder to burn.ps1 -DicomFolder.
    /// No temporary copy — instant on same drive.
    /// </summary>
    public async Task BurnStudyAsync(ReceivedStudy study, AppSettings settings)
    {
        // Accept Complete (direct call), Burning (after WaitForDisc), and Done (re-burn)
        if (study.Status != StudyStatus.Complete && study.Status != StudyStatus.Burning && study.Status != StudyStatus.Done)
            throw new InvalidOperationException("Study is not complete");

        study.Status = StudyStatus.Burning;
        study.StatusText = "Validating...";

        try
        {
            // ============================================================
            // CRITICAL: Validate DICOM files exist on disk BEFORE burning
            // ============================================================
            if (!Directory.Exists(study.StoragePath))
            {
                throw new DirectoryNotFoundException(
                    $"Study folder not found: {study.StoragePath}");
            }

            var dirInfo = new DirectoryInfo(study.StoragePath);
            var dcmFiles = dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).ToList();

            if (dcmFiles.Count == 0)
            {
                throw new FileNotFoundException(
                    $"No DICOM files found in {study.StoragePath}");
            }

            var totalSize = dcmFiles.Sum(f => f.Length);
            Log($"Validated: {dcmFiles.Count} DICOM files, {totalSize / (1024.0 * 1024.0):F1} MB");

            if (dcmFiles.Count != study.ImageCount)
            {
                Log($"WARNING: Expected {study.ImageCount} images but found {dcmFiles.Count} on disk");
            }

            // ============================================================
            // Find burn script
            // ============================================================
            var projectRoot = FindProjectRoot();
            if (projectRoot == null)
                throw new FileNotFoundException("Cannot find project root (scripts/burn.ps1)");

            var burnScript = Path.Combine(projectRoot, "scripts", "burn-gui.ps1");
            if (!File.Exists(burnScript))
                burnScript = Path.Combine(projectRoot, "scripts", "burn.ps1");

            if (!File.Exists(burnScript))
                throw new FileNotFoundException("Burn script not found");

            // ============================================================
            // Restructure DICOM files IN-PLACE to PACS-compatible layout
            // File.Move() is instant on the same drive (no data copy)
            // incoming/{StudyUID}/{SeriesUID}/{SOP}.dcm
            //   → incoming/{StudyUID}/DIR000/00000000/00000000.DCM
            // ============================================================
            study.StatusText = "Preparing...";
            Log("Restructuring DICOM folder in-place (DIR000 layout)...");

            // If privacy mode is active, skip DICOMDIR during restructure —
            // generate it AFTER privacy so DICOMDIR matches the actual file metadata
            bool hasPrivacy = study.PrivacyMode != DicomPrivacyMode.None;
            var prepResult = await Task.Run(() => RestructureInPlace(
                study.StoragePath, projectRoot, generateDicomdir: !hasPrivacy));

            Log($"Moved {prepResult.FilesCopied} files in {prepResult.SeriesCount} series to DIR000/");

            // Save study metadata BEFORE privacy mode modifies DICOM tags.
            // If burn fails and app restarts, ScanIncomingFolder() can recover
            // PatientName/StudyDate from study-info.json (DICOM tags may be gone).
            SaveStudyInfo(study);

            // Apply privacy mode (Anonymize / HideAll) BEFORE DICOMDIR generation
            // Per-study: each study has its own PrivacyMode toggle
            if (hasPrivacy)
            {
                var dir000Path = Path.Combine(study.StoragePath, "DIR000");
                var privacyCount = await Task.Run(() => ApplyPrivacyMode(dir000Path, study.PrivacyMode));
                var modeKey = study.PrivacyMode == DicomPrivacyMode.Anonymize ? "AnonymizeApplied" : "HideAllApplied";
                Log(string.Format(LocalizationHelper.Get(modeKey), privacyCount));

                // Generate DICOMDIR AFTER privacy — metadata in DICOMDIR matches actual files
                // Task.Run to avoid blocking UI thread (fo-dicom reads all DICOM headers)
                Log("Generating DICOMDIR after privacy mode...");
                var dir000 = Path.Combine(study.StoragePath, "DIR000");
                var dicomdirAfterPrivacy = Path.Combine(study.StoragePath, "DICOMDIR");
                prepResult.ImageRecordsAdded = await Task.Run(() =>
                    TryGenerateDicomdirFoDicom(dir000, dicomdirAfterPrivacy, prepResult.Errors));
                if (prepResult.ImageRecordsAdded > 0)
                {
                    prepResult.DicomdirSource = "fo-dicom";
                }
                else
                {
                    var dcmmkdirPath = FindDcmmkdir(projectRoot);
                    if (dcmmkdirPath != null && TryGenerateDicomdirDcmtk(dcmmkdirPath, study.StoragePath, dicomdirAfterPrivacy, prepResult.Errors))
                    {
                        prepResult.DicomdirSource = "dcmmkdir";
                        prepResult.ImageRecordsAdded = prepResult.FilesCopied;
                    }
                    else
                    {
                        prepResult.DicomdirSource = "FAILED";
                    }
                }
            }

            var dicomdirPath = Path.Combine(study.StoragePath, "DICOMDIR");

            foreach (var err in prepResult.Errors)
            {
                Log($"DICOMDIR: {err}");
            }

            if (!File.Exists(dicomdirPath) || prepResult.ImageRecordsAdded == 0)
            {
                var reason = !File.Exists(dicomdirPath)
                    ? "DICOMDIR generation failed completely"
                    : $"DICOMDIR has 0 IMAGE records (source: {prepResult.DicomdirSource})";
                throw new InvalidOperationException(
                    $"Burn blocked: {reason}. Disc would not import on Siemens/GE/Philips.");
            }

            var dicomdirSize = new FileInfo(dicomdirPath).Length;
            Log($"DICOMDIR: {dicomdirSize / 1024.0:F1} KB, {prepResult.ImageRecordsAdded} IMAGE records ({prepResult.DicomdirSource})");

            // ============================================================
            // Launch burn script with -DicomFolder (study folder, now restructured)
            // ============================================================
            study.StatusText = "Burning...";
            Log($"Launching burn: {Path.GetFileName(burnScript)}");

            var args = $"-ExecutionPolicy Bypass -File \"{burnScript}\" -DicomFolder \"{study.StoragePath}\" -BurnSpeed {settings.BurnSpeed}";
            if (!string.IsNullOrEmpty(settings.SelectedDriveId))
                args += $" -DriveID \"{settings.SelectedDriveId}\"";
            if (settings.SimulateOnly)
                args += " -SimulateOnly";
            if (!settings.IncludeTutorial)
                args += " -ExcludeTutorial";

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = args,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi);
            if (process == null)
                throw new InvalidOperationException("Failed to start burn process");

            // Monitor: if user closed burn-gui window, PowerShell may hang on runspace cleanup.
            // Check every 5 sec if the main window disappeared; if so, kill after 10 sec grace period.
            await WaitForProcessOrKill(process);

            if (process.ExitCode == 0)
            {
                study.Status = StudyStatus.Done;
                study.StatusText = "Burned";
                Log($"Burn completed: {study.PatientName}");
            }
            else
            {
                // Burn failed — set back to Complete so user can retry
                // Files remain in DIR000/ layout — RestructureInPlace is idempotent
                // (skips DIR000 when scanning for series dirs, DICOMDIR regenerated on retry)
                study.Status = StudyStatus.Complete;
                study.StatusText = $"Burn failed (exit {process.ExitCode})";
                Log($"Burn failed with exit code {process.ExitCode} — study available for retry");
            }

            // Cleanup study folder after successful burn
            // Only delete when AutoDeleteAfterBurn is ON — user may want to re-burn
            if (study.Status == StudyStatus.Done && settings.AutoDeleteAfterBurn)
            {
                try
                {
                    if (Directory.Exists(study.StoragePath))
                    {
                        Directory.Delete(study.StoragePath, true);
                        Log($"Cleaned up: {study.StoragePath}");
                    }
                }
                catch (Exception cleanupEx)
                {
                    Log($"Cleanup warning: {cleanupEx.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            study.Status = StudyStatus.Complete; // retryable — user can click Burn again
            study.StatusText = $"Error: {ex.Message}";
            Log($"Burn error: {ex.Message}");
        }
    }

    /// <summary>
    /// Burns multiple completed studies onto a single disc.
    /// Creates a staging folder with a separate DIR folder per patient (DIR000/, DIR001/, DIR002/...),
    /// each with independent series numbering starting at 0. Generates a single DICOMDIR
    /// referencing all DIR folders, then burns.
    /// </summary>
    public async Task BurnMultipleStudiesAsync(List<ReceivedStudy> studies, AppSettings settings)
    {
        if (studies.Count == 0)
            throw new InvalidOperationException("No studies to burn");

        if (studies.Count == 1)
        {
            // Single study — use existing optimized in-place method
            await BurnStudyAsync(studies[0], settings);
            return;
        }

        // ============================================================
        // Validate ALL studies before starting
        // ============================================================
        int totalFiles = 0;
        long totalSize = 0;
        string? stagingDir = null;

        // Declared outside try — needed in catch for file restoration on error
        var studyDirMappings = new List<(ReceivedStudy study, string dirFolderName)>();

        try
        {
            foreach (var study in studies)
            {
                // Accept Complete (direct call), Burning (after WaitForDisc), and Done (re-burn)
                if (study.Status != StudyStatus.Complete && study.Status != StudyStatus.Burning && study.Status != StudyStatus.Done)
                    throw new InvalidOperationException($"Study {study.PatientName} is not complete");

                study.Status = StudyStatus.Burning;
                study.StatusText = "Validating...";
            }

            foreach (var study in studies)
            {
                if (!Directory.Exists(study.StoragePath))
                    throw new DirectoryNotFoundException($"Study folder not found: {study.StoragePath}");

                var dirInfo = new DirectoryInfo(study.StoragePath);
                var dcmFiles = dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).ToList();
                if (dcmFiles.Count == 0)
                    throw new FileNotFoundException($"No DICOM files in {study.StoragePath}");

                var studySize = dcmFiles.Sum(f => f.Length);
                totalFiles += dcmFiles.Count;
                totalSize += studySize;

                Log($"Validated: {study.PatientName} — {dcmFiles.Count} files, {studySize / (1024.0 * 1024.0):F1} MB");
            }

            // Check total fits on disc (DVD-R ~4700 MB, leave margin for DICOMDIR + filesystem overhead)
            var totalSizeMB = totalSize / (1024.0 * 1024.0);
            Log($"Total: {totalFiles} files, {totalSizeMB:F1} MB from {studies.Count} studies");

            if (totalSizeMB > 4600)
            {
                throw new InvalidOperationException(
                    $"Total size {totalSizeMB:F0} MB exceeds DVD capacity (~4600 MB usable)");
            }

            // ============================================================
            // Find burn script
            // ============================================================
            var projectRoot = FindProjectRoot();
            if (projectRoot == null)
                throw new FileNotFoundException("Cannot find project root (scripts/burn.ps1)");

            var burnScript = Path.Combine(projectRoot, "scripts", "burn-gui.ps1");
            if (!File.Exists(burnScript))
                burnScript = Path.Combine(projectRoot, "scripts", "burn.ps1");
            if (!File.Exists(burnScript))
                throw new FileNotFoundException("Burn script not found");

            // ============================================================
            // Create staging folder — sibling to incoming directories
            // ============================================================
            var incomingParent = Path.GetDirectoryName(studies[0].StoragePath) ?? studies[0].StoragePath;
            stagingDir = Path.Combine(incomingParent,
                $"_burn_staging_{DateTime.Now:yyyyMMdd_HHmmss}");
            Directory.CreateDirectory(stagingDir);

            Log($"Staging folder: {stagingDir}");

            // ============================================================
            // Place each study into its own DIR folder: DIR000/, DIR001/, DIR002/...
            // Each study's series numbering starts at 0 (independent per patient)
            // ============================================================
            foreach (var study in studies)
                study.StatusText = "Preparing...";

            int totalMoved = 0;
            int totalSeries = 0;
            var allErrors = new List<string>();

            await Task.Run(() =>
            {
                for (int i = 0; i < studies.Count; i++)
                {
                    var study = studies[i];
                    var dirFolderName = $"DIR{i:D3}"; // DIR000, DIR001, DIR002...

                    var prepResult = RestructureInPlace(
                        study.StoragePath, projectRoot,
                        stagingDir: stagingDir,
                        seriesOffset: 0,
                        dirFolderName: dirFolderName);

                    totalMoved += prepResult.FilesCopied;
                    totalSeries += prepResult.SeriesCount;
                    allErrors.AddRange(prepResult.Errors);

                    studyDirMappings.Add((study, dirFolderName));

                    Log($"Prepared: {study.PatientName} → {dirFolderName}/ ({prepResult.FilesCopied} files, {prepResult.SeriesCount} series)");
                }
            });

            Log($"Total: {totalMoved} files in {totalSeries} series across {studies.Count} DIR folders");

            // Save study metadata BEFORE privacy mode modifies DICOM tags.
            foreach (var study in studies)
                SaveStudyInfo(study);

            // Apply privacy mode per-study — each study has its own PrivacyMode toggle
            // Each study has its own DIR folder, apply to entire folder
            // Batched into single Task.Run() to avoid thread pool overhead per study
            var privacyStudies = studyDirMappings
                .Where(m => m.study.PrivacyMode != DicomPrivacyMode.None)
                .ToList();

            if (privacyStudies.Count > 0)
            {
                var privacyResults = await Task.Run(() =>
                {
                    var results = new List<(ReceivedStudy study, int count)>();
                    int anonIndex = 1;
                    foreach (var (study, dirFolderName) in privacyStudies)
                    {
                        var dirPath = Path.Combine(stagingDir, dirFolderName);
                        // Unique label per study — prevents Siemens from merging patients
                        var anonLabel = privacyStudies.Count > 1
                            ? $"Anonymous {anonIndex++}"
                            : null; // single study: use default "Anonymous"
                        var count = ApplyPrivacyMode(dirPath, study.PrivacyMode, anonLabel);
                        results.Add((study, count));
                    }
                    return results;
                });

                foreach (var (study, count) in privacyResults)
                {
                    var modeKey = study.PrivacyMode == DicomPrivacyMode.Anonymize ? "AnonymizeApplied" : "HideAllApplied";
                    Log($"{study.PatientName}: {string.Format(LocalizationHelper.Get(modeKey), count)}");
                }
            }

            // ============================================================
            // Generate DICOMDIR from all DIR folders (DIR000/, DIR001/, ...)
            // ============================================================
            var dirFoldersList = studyDirMappings
                .Select(m => (Path.Combine(stagingDir, m.dirFolderName), m.dirFolderName))
                .ToList();
            var dicomdirPath = Path.Combine(stagingDir, "DICOMDIR");

            int imageRecords = await Task.Run(() => TryGenerateDicomdirFoDicom(dirFoldersList, dicomdirPath, allErrors));
            string dicomdirSource;

            if (imageRecords > 0)
            {
                dicomdirSource = "fo-dicom";
            }
            else
            {
                allErrors.Add($"fo-dicom created 0 IMAGE records out of {totalMoved} files");

                var dcmmkdirPath = FindDcmmkdir(projectRoot);
                if (dcmmkdirPath != null && TryGenerateDicomdirDcmtk(dcmmkdirPath, stagingDir, dicomdirPath, allErrors))
                {
                    dicomdirSource = "dcmmkdir";
                    imageRecords = totalMoved;
                }
                else
                {
                    dicomdirSource = "FAILED";
                }
            }

            foreach (var err in allErrors)
                Log($"DICOMDIR: {err}");

            if (!File.Exists(dicomdirPath) || imageRecords == 0)
            {
                var reason = !File.Exists(dicomdirPath)
                    ? "DICOMDIR generation failed completely"
                    : $"DICOMDIR has 0 IMAGE records (source: {dicomdirSource})";
                throw new InvalidOperationException(
                    $"Burn blocked: {reason}. Disc would not import on Siemens/GE/Philips.");
            }

            var dicomdirSize = new FileInfo(dicomdirPath).Length;
            Log($"DICOMDIR: {dicomdirSize / 1024.0:F1} KB, {imageRecords} IMAGE records ({dicomdirSource})");

            // ============================================================
            // Launch burn script with staging folder
            // ============================================================
            foreach (var study in studies)
                study.StatusText = "Burning...";

            Log($"Launching burn: {Path.GetFileName(burnScript)} ({studies.Count} studies)");

            var args = $"-ExecutionPolicy Bypass -File \"{burnScript}\" -DicomFolder \"{stagingDir}\" -BurnSpeed {settings.BurnSpeed}";
            if (!string.IsNullOrEmpty(settings.SelectedDriveId))
                args += $" -DriveID \"{settings.SelectedDriveId}\"";
            if (settings.SimulateOnly)
                args += " -SimulateOnly";
            if (!settings.IncludeTutorial)
                args += " -ExcludeTutorial";

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = args,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi);
            if (process == null)
                throw new InvalidOperationException("Failed to start burn process");

            await WaitForProcessOrKill(process);

            if (process.ExitCode == 0)
            {
                // Determine disc label for log — group by normalized patient name
                var patients = studies
                    .Select(s => (s.PatientName ?? "").Trim().ToUpperInvariant())
                    .Distinct()
                    .ToList();
                var label = patients.Count == 1 ? studies[0].PatientName : "Multiple";

                foreach (var study in studies)
                {
                    study.Status = StudyStatus.Done;
                    study.StatusText = "Burned";
                }
                Log($"Burn completed: {label} ({studies.Count} studies, {totalFiles} images)");
            }
            else
            {
                Log($"Burn failed with exit code {process.ExitCode}");

                // Burn failed — restore files from staging back to individual study folders
                // so each study can be re-burned individually
                RestoreFilesFromStaging(stagingDir!, studyDirMappings);

                foreach (var study in studies)
                {
                    study.Status = StudyStatus.Complete;
                    study.StatusText = $"Burn failed (exit {process.ExitCode})";
                }
                Log("Files restored — studies available for retry");
            }

            // ============================================================
            // Cleanup: staging folder (always) + original study folders (if AutoDelete)
            // Only runs on SUCCESS — burn failure restores files above
            // ============================================================
            if (studies.All(s => s.Status == StudyStatus.Done))
            {
                // Staging folder: ALWAYS delete (temp merge area, not useful to keep)
                try
                {
                    if (Directory.Exists(stagingDir))
                    {
                        Directory.Delete(stagingDir, true);
                        Log($"Cleaned up staging: {stagingDir}");
                    }
                }
                catch (Exception ex) { Log($"Staging cleanup warning: {ex.Message}"); }

                // Original study folders: only delete when AutoDelete is ON
                if (settings.AutoDeleteAfterBurn)
                {
                    foreach (var study in studies)
                    {
                        try
                        {
                            if (Directory.Exists(study.StoragePath))
                            {
                                Directory.Delete(study.StoragePath, true);
                                Log($"Cleaned up: {study.StoragePath}");
                            }
                        }
                        catch (Exception ex) { Log($"Cleanup warning: {ex.Message}"); }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log($"Multi-burn error: {ex.Message}");

            // Try to restore files from staging back to study folders
            // If staging exists and has files, they were moved from original study folders
            if (stagingDir != null && studyDirMappings.Count > 0)
            {
                try
                {
                    RestoreFilesFromStaging(stagingDir, studyDirMappings);
                    // Restoration succeeded — clean up empty staging folder
                    try
                    {
                        if (Directory.Exists(stagingDir))
                            Directory.Delete(stagingDir, true);
                    }
                    catch { /* best effort */ }
                    // Set Complete for retry
                    foreach (var study in studies)
                    {
                        study.Status = StudyStatus.Complete;
                        study.StatusText = $"Error: {ex.Message}";
                    }
                    Log("Files restored — studies available for retry");
                }
                catch (Exception restoreEx)
                {
                    // Restoration failed — keep staging (has the files!), set Error
                    Log($"File restoration failed: {restoreEx.Message}");
                    Log($"IMPORTANT: Files preserved in staging folder: {stagingDir}");
                    foreach (var study in studies)
                    {
                        study.Status = StudyStatus.Error;
                        study.StatusText = $"Error: {ex.Message}";
                    }
                }
            }
            else
            {
                // No files were moved (error happened before restructuring) — retryable
                foreach (var study in studies)
                {
                    study.Status = StudyStatus.Complete; // retryable — no files were moved
                    study.StatusText = $"Error: {ex.Message}";
                }

                if (stagingDir != null)
                {
                    try
                    {
                        if (Directory.Exists(stagingDir))
                            Directory.Delete(stagingDir, true);
                    }
                    catch { /* best effort */ }
                }
            }
        }
    }

    private class PrepareResult
    {
        public int FilesCopied { get; set; }
        public int SeriesCount { get; set; }
        public int ImageRecordsAdded { get; set; }
        public string DicomdirSource { get; set; } = "";
        public List<string> Errors { get; set; } = new();
    }

    /// <summary>
    /// Restructures DICOM files IN-PLACE from fo-dicom SCP layout to PACS-compatible layout.
    /// Uses File.Move() — instant on the same drive (no data copy, just metadata update).
    ///
    /// BEFORE (fo-dicom SCP):               AFTER (PACS-compatible):
    ///   incoming/{StudyUID}/                  incoming/{StudyUID}/
    ///     {SeriesUID1}/                         DIR000/
    ///       {SOP1}.dcm                            00000000/
    ///       {SOP2}.dcm           ──MOVE──►          00000000.DCM
    ///     {SeriesUID2}/                               00000001.DCM
    ///       {SOP3}.dcm                            00000001/
    ///                                                 00000000.DCM
    ///                                           DICOMDIR
    ///
    /// After restructuring, the folder is ready for burn.ps1 -DicomFolder.
    /// No %TEMP% copy needed — files are deleted after burn anyway.
    /// </summary>
    /// <param name="studyPath">Source study folder with series subdirectories</param>
    /// <param name="projectRoot">Project root for dcmmkdir fallback</param>
    /// <param name="stagingDir">If set, move files to stagingDir/{dirFolderName}/ instead of studyPath/DIR000/ (multi-study)</param>
    /// <param name="seriesOffset">Starting series number (default 0)</param>
    /// <param name="dirFolderName">Target DIR folder name (default "DIR000", multi-study uses DIR001, DIR002...)</param>
    private PrepareResult RestructureInPlace(string studyPath, string? projectRoot,
        string? stagingDir = null, int seriesOffset = 0, bool generateDicomdir = true,
        string dirFolderName = "DIR000")
    {
        var result = new PrepareResult();

        // Multi-study: output to staging folder; single-study: output in-place
        var outputRoot = stagingDir ?? studyPath;
        var dirFolder = Path.Combine(outputRoot, dirFolderName);
        Directory.CreateDirectory(dirFolder);

        var sourceDir = new DirectoryInfo(studyPath);
        int seriesNum = seriesOffset;

        // ============================================================
        // Step 1: Move DICOM files to dirFolderName/ with PACS naming (8-digit)
        // File.Move() is instant on the same drive (NTFS metadata update only)
        // ============================================================

        // Enumerate series directories (skip the target DIR folder we just created)
        var seriesDirs = sourceDir.GetDirectories()
            .Where(d => !d.Name.Equals(dirFolderName, StringComparison.OrdinalIgnoreCase)
                     && !d.Name.Equals("DIR000", StringComparison.OrdinalIgnoreCase))
            .ToArray();

        foreach (var seriesDir in seriesDirs)
        {
            var seriesName = seriesNum.ToString("D8"); // 00000000, 00000001, ...
            var destSeriesDir = Path.Combine(dirFolder, seriesName);
            Directory.CreateDirectory(destSeriesDir);

            var files = seriesDir.GetFiles("*.dcm", SearchOption.AllDirectories);
            int fileNum = 0;

            foreach (var file in files)
            {
                var fileName = fileNum.ToString("D8") + ".DCM"; // Keep .DCM like PACS
                var destPath = Path.Combine(destSeriesDir, fileName);
                // overwrite: true prevents IOException if partial restructure left files behind
                File.Move(file.FullName, destPath, overwrite: true);
                result.FilesCopied++;
                fileNum++;
            }

            if (fileNum > 0)
            {
                seriesNum++;
                // Delete the now-empty original series directory
                try { seriesDir.Delete(true); } catch { }
            }
            else
            {
                Directory.Delete(destSeriesDir); // Remove empty series dir
            }
        }

        // Handle .dcm files directly in study root (no series subdirectory)
        var rootFiles = sourceDir.GetFiles("*.dcm", SearchOption.TopDirectoryOnly);
        if (rootFiles.Length > 0)
        {
            var seriesName = seriesNum.ToString("D8");
            var destSeriesDir = Path.Combine(dirFolder, seriesName);
            Directory.CreateDirectory(destSeriesDir);

            int fileNum = 0;
            foreach (var file in rootFiles)
            {
                var fileName = fileNum.ToString("D8") + ".DCM";
                var destPath = Path.Combine(destSeriesDir, fileName);
                File.Move(file.FullName, destPath, overwrite: true);
                result.FilesCopied++;
                fileNum++;
            }
            seriesNum++;
        }

        // Handle already-restructured studies (files already in DIR000/ from previous burn/restore)
        if (result.FilesCopied == 0)
        {
            var existingDir000 = Path.Combine(studyPath, "DIR000");
            if (Directory.Exists(existingDir000))
            {
                if (stagingDir != null)
                {
                    // Multi-study: re-group ALL files by SeriesInstanceUID for proper series separation.
                    // PACS downloads put all series into a single folder (DIR000/00000000/),
                    // while SCP receives already have proper separation. Re-grouping handles both cases.
                    var allDcmFiles = new DirectoryInfo(existingDir000)
                        .GetFiles("*.DCM", SearchOption.AllDirectories)
                        .ToList();

                    var seriesGroups = new SortedDictionary<string, List<FileInfo>>();
                    foreach (var file in allDcmFiles)
                    {
                        string seriesUid = "unknown";
                        try
                        {
                            var dcm = DicomFile.Open(file.FullName, FileReadOption.SkipLargeTags);
                            seriesUid = dcm.Dataset.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, "unknown");
                        }
                        catch { }

                        if (!seriesGroups.ContainsKey(seriesUid))
                            seriesGroups[seriesUid] = new List<FileInfo>();
                        seriesGroups[seriesUid].Add(file);
                    }

                    foreach (var group in seriesGroups.Values)
                    {
                        var destSeriesName = seriesNum.ToString("D8");
                        var destSeriesDir = Path.Combine(dirFolder, destSeriesName);
                        Directory.CreateDirectory(destSeriesDir);

                        int fileNum = 0;
                        foreach (var file in group.OrderBy(f => f.Name))
                        {
                            var fileName = fileNum.ToString("D8") + ".DCM";
                            File.Move(file.FullName, Path.Combine(destSeriesDir, fileName), overwrite: true);
                            result.FilesCopied++;
                            fileNum++;
                        }
                        seriesNum++;
                    }

                    // Clean up empty source directories
                    try
                    {
                        foreach (var dir in new DirectoryInfo(existingDir000).GetDirectories())
                            try { dir.Delete(true); } catch { }
                    }
                    catch { }
                }
                else
                {
                    // Single-study: files already in place, just count
                    var existingSeries = new DirectoryInfo(existingDir000).GetDirectories()
                        .OrderBy(d => d.Name)
                        .ToArray();
                    foreach (var srcSeriesDir in existingSeries)
                    {
                        var files = srcSeriesDir.GetFiles("*", SearchOption.TopDirectoryOnly);
                        if (files.Length == 0) continue;
                        result.FilesCopied += files.Length;
                        seriesNum++;
                    }
                }
            }
        }

        result.SeriesCount = seriesNum - seriesOffset;

        // ============================================================
        // Step 2: Generate DICOMDIR — fo-dicom first, dcmmkdir fallback
        // (skipped in multi-study mode — caller generates DICOMDIR after all studies merged)
        // ============================================================
        if (stagingDir != null || !generateDicomdir)
            return result; // Multi-study or privacy-first: DICOMDIR generated by caller

        var dicomdirPath = Path.Combine(outputRoot, "DICOMDIR");

        result.ImageRecordsAdded = TryGenerateDicomdirFoDicom(dirFolder, dicomdirPath, result.Errors);

        if (result.ImageRecordsAdded > 0)
        {
            result.DicomdirSource = "fo-dicom";
        }
        else
        {
            result.Errors.Add($"fo-dicom created 0 IMAGE records out of {result.FilesCopied} files");

            var dcmmkdirPath = FindDcmmkdir(projectRoot);
            if (dcmmkdirPath != null)
            {
                var dcmSuccess = TryGenerateDicomdirDcmtk(dcmmkdirPath, outputRoot, dicomdirPath, result.Errors);
                if (dcmSuccess)
                {
                    result.DicomdirSource = "dcmmkdir";
                    result.ImageRecordsAdded = result.FilesCopied;
                }
                else
                {
                    result.DicomdirSource = "FAILED";
                }
            }
            else
            {
                result.Errors.Add("dcmmkdir not found — no fallback available");
                result.DicomdirSource = "FAILED";
            }
        }

        return result;
    }

    /// <summary>
    /// Generates DICOMDIR using fo-dicom DicomDirectory (single DIR folder).
    /// Delegates to multi-DIR overload.
    /// </summary>
    private static int TryGenerateDicomdirFoDicom(string dirPath, string dicomdirPath, List<string> errors)
    {
        var dirName = Path.GetFileName(dirPath); // "DIR000" from full path
        return TryGenerateDicomdirFoDicom(
            new[] { (dirPath, dirName) },
            dicomdirPath, errors);
    }

    /// <summary>
    /// Generates DICOMDIR using fo-dicom DicomDirectory for multiple DIR folders.
    /// Each DIR folder gets its own ReferencedFileID prefix: DIR000\series\file, DIR001\series\file, etc.
    /// Returns the number of IMAGE records successfully added.
    /// Uses FileReadOption.SkipLargeTags — DICOMDIR needs only metadata,
    /// not pixel data. Saves ~250 MB RAM for a 500-image study.
    /// </summary>
    private static int TryGenerateDicomdirFoDicom(IList<(string path, string name)> dirFolders,
        string dicomdirPath, List<string> errors)
    {
        int imageRecords = 0;

        try
        {
            var dicomDir = new DicomDirectory();

            foreach (var (dirPath, dirName) in dirFolders)
            {
                var dirInfo = new DirectoryInfo(dirPath);
                if (!dirInfo.Exists) continue;

                foreach (var seriesDir in dirInfo.GetDirectories().OrderBy(d => d.Name))
                {
                    foreach (var file in seriesDir.GetFiles("*.DCM", SearchOption.AllDirectories).OrderBy(f => f.Name))
                    {
                        try
                        {
                            // SkipLargeTags: skip pixel data and other large tags (>64KB)
                            // DICOMDIR needs only metadata (Patient/Study/Series/SOP tags)
                            // Saves ~250 MB RAM on a 500-image study
                            var dcmFile = DicomFile.Open(file.FullName, FileReadOption.SkipLargeTags);

                            // DICOM Part 10: ReferencedFileID relative to DICOMDIR location
                            // Path: DIR000\00000000\00000000.DCM or DIR001\00000000\00000000.DCM
                            var refFileId = $@"{dirName}\{seriesDir.Name}\{file.Name}";
                            dicomDir.AddFile(dcmFile, refFileId);
                            imageRecords++;
                        }
                        catch (Exception ex)
                        {
                            errors.Add($"fo-dicom AddFile {dirName}/{seriesDir.Name}/{file.Name}: {ex.Message}");
                        }
                    }
                }
            }

            if (imageRecords > 0)
            {
                dicomDir.Save(dicomdirPath);
            }
        }
        catch (Exception ex)
        {
            errors.Add($"fo-dicom DicomDirectory: {ex.Message}");
        }

        return imageRecords;
    }

    /// <summary>
    /// Generates DICOMDIR using dcmmkdir (dcmtk) as fallback.
    /// Runs: dcmmkdir +r --input-directory "outputDir" --output-file "DICOMDIR"
    /// dcmmkdir generates paths relative to input directory: DIR000\00000000\00000000.DCM
    /// </summary>
    private static bool TryGenerateDicomdirDcmtk(string dcmmkdirPath, string outputDir, string dicomdirPath, List<string> errors)
    {
        try
        {
            // Remove failed fo-dicom DICOMDIR if exists
            if (File.Exists(dicomdirPath))
                File.Delete(dicomdirPath);

            var psi = new ProcessStartInfo
            {
                FileName = dcmmkdirPath,
                // +r = recurse, +id = input directory, +D = output file
                // Run from outputDir so paths are relative: DIR000\00000000\00000000.DCM
                Arguments = $"+r +id \"{outputDir}\" +D \"{dicomdirPath}\"",
                WorkingDirectory = outputDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using var process = Process.Start(psi);
            if (process == null)
            {
                errors.Add("dcmmkdir: failed to start process");
                return false;
            }

            // Read BOTH stdout and stderr async to prevent deadlock
            // (if either buffer fills up ~4KB, process blocks forever)
            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            var exited = process.WaitForExit(60_000); // 60 sec timeout

            if (!exited)
            {
                try { process.Kill(); } catch { }
                process.WaitForExit(); // wait for kill to take effect + flush async readers
                try { _ = stdoutTask.Result; } catch { }
                try { _ = stderrTask.Result; } catch { }
                errors.Add("dcmmkdir: timed out after 60 sec (killed)");
                return false;
            }

            _ = stdoutTask.Result; // discard stdout, just prevent deadlock
            var stderr = stderrTask.Result;
            if (process.ExitCode != 0)
            {
                errors.Add($"dcmmkdir exit code {process.ExitCode}: {stderr.Trim()}");
                return false;
            }

            return File.Exists(dicomdirPath);
        }
        catch (Exception ex)
        {
            errors.Add($"dcmmkdir: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Restores DICOM files from staging DIR folders back to individual study folders.
    /// Used when multi-burn fails — moves each study's DIR folder back as DIR000/ so it can be re-burned.
    /// Files end up in study.StoragePath/DIR000/{seriesNum}/*.DCM — ready for single burn retry.
    /// After restoration, deletes the now-empty staging folder.
    /// </summary>
    private void RestoreFilesFromStaging(string stagingDir,
        List<(ReceivedStudy study, string dirFolderName)> mappings)
    {
        foreach (var (study, dirFolderName) in mappings)
        {
            var stagingDirFolder = Path.Combine(stagingDir, dirFolderName);
            if (!Directory.Exists(stagingDirFolder)) continue;

            // Restore as DIR000/ (standard single-study layout) regardless of staging DIR name
            var studyDir000 = Path.Combine(study.StoragePath, "DIR000");
            Directory.CreateDirectory(studyDir000);

            foreach (var srcSeriesDir in Directory.GetDirectories(stagingDirFolder))
            {
                var seriesName = Path.GetFileName(srcSeriesDir);
                var dstSeriesDir = Path.Combine(studyDir000, seriesName);
                Directory.CreateDirectory(dstSeriesDir);

                foreach (var file in Directory.GetFiles(srcSeriesDir))
                {
                    File.Move(file, Path.Combine(dstSeriesDir, Path.GetFileName(file)), overwrite: true);
                }

                try { Directory.Delete(srcSeriesDir); } catch { }
            }

            try { Directory.Delete(stagingDirFolder); } catch { }

            Log($"Restored: {study.PatientName} — files moved back from {dirFolderName}/ to {study.StoragePath}");
        }

        // Delete staging folder ONLY if no DICOM files remain (safety check).
        // If a study's RestructureInPlace partially moved files but its range was never
        // recorded (exception during merge), those orphaned files must be preserved.
        try
        {
            if (Directory.Exists(stagingDir))
            {
                var remainingDcm = Directory.EnumerateFiles(stagingDir, "*.DCM", SearchOption.AllDirectories).Any();
                if (!remainingDcm)
                {
                    Directory.Delete(stagingDir, true);
                }
                else
                {
                    Log($"WARNING: staging folder has unreferenced DICOM files, preserved: {stagingDir}");
                }
            }
        }
        catch { /* non-critical */ }
    }

    private static string? FindDcmmkdir(string? projectRoot)
    {
        // Check project tools directory
        if (projectRoot != null)
        {
            var path = Path.Combine(projectRoot, "tools", "dcmtk", "bin", "dcmmkdir.exe");
            if (File.Exists(path)) return path;
        }

        // Check known project path
        var knownPath = @"E:\Weasis Burn\tools\dcmtk\bin\dcmmkdir.exe";
        if (File.Exists(knownPath)) return knownPath;

        return null;
    }

    /// <summary>
    /// Waits for the burn process (burn-gui.ps1) to exit.
    /// burn-gui.ps1 is launched with CreateNoWindow=true, so MainWindowHandle is always Zero —
    /// we cannot detect window close via handle. Instead, rely on burn-gui.ps1's own cleanup
    /// (workerCmd.Stop() on window close) and add a 60-minute safety timeout for truly stuck processes.
    /// </summary>
    private async Task WaitForProcessOrKill(Process process)
    {
        var maxWait = TimeSpan.FromMinutes(60);
        var sw = System.Diagnostics.Stopwatch.StartNew();

        while (!process.HasExited)
        {
            await Task.Delay(3000);

            if (sw.Elapsed > maxWait)
            {
                Log("Burn process exceeded 60-minute timeout — killing...");
                try { process.Kill(); } catch { }
                await Task.Delay(500);
                return;
            }
        }
    }

    private static string? FindProjectRoot()
    {
        var dir = AppDomain.CurrentDomain.BaseDirectory;
        for (int i = 0; i < 5; i++)
        {
            if (File.Exists(Path.Combine(dir, "scripts", "burn.ps1")))
                return dir;
            var parent = Directory.GetParent(dir);
            if (parent == null) break;
            dir = parent.FullName;
        }

        var knownPath = @"E:\Weasis Burn";
        if (File.Exists(Path.Combine(knownPath, "scripts", "burn.ps1")))
            return knownPath;

        return null;
    }

    // ================================================================
    // DICOM Privacy — Anonymize / Hide All metadata
    // Applied AFTER RestructureInPlace (files already in DIR000/)
    // and BEFORE DICOMDIR generation (so DICOMDIR reflects changes)
    // ================================================================

    /// <summary>
    /// Tags to REMOVE for Anonymize mode (blanked or deleted).
    /// Text fields get "Anonymous", date/time fields get blanked.
    /// </summary>
    private static readonly (DicomTag tag, string? replaceValue)[] AnonymizeTags =
    {
        (DicomTag.PatientName, "Anonymous"),
        (DicomTag.PatientID, "Anonymous"),
        (DicomTag.PatientBirthDate, ""),        // VR=DA, can't hold text
        (DicomTag.StudyDate, ""),                // VR=DA
        (DicomTag.StudyTime, ""),                // VR=TM
        (DicomTag.SeriesDate, ""),
        (DicomTag.SeriesTime, ""),
        (DicomTag.AcquisitionDate, ""),
        (DicomTag.AcquisitionTime, ""),
        (DicomTag.ContentDate, ""),
        (DicomTag.ContentTime, ""),
        (DicomTag.AcquisitionDateTime, ""),
        (DicomTag.AccessionNumber, "Anonymous"),
        (DicomTag.OtherPatientIDsSequence, null), // null = remove tag entirely
    };

    /// <summary>
    /// Tags to REMOVE for HideAll mode — comprehensive demographics/institutional cleanup.
    /// Keeps: pixel data, geometry (MPR/3D), UIDs (DICOMDIR), modality, transfer syntax.
    /// </summary>
    private static readonly DicomTag[] HideAllTags =
    {
        // Patient demographics
        DicomTag.PatientName,
        DicomTag.PatientID,
        DicomTag.PatientBirthDate,
        DicomTag.PatientSex,
        DicomTag.PatientAge,
        DicomTag.PatientWeight,
        DicomTag.PatientSize,
        DicomTag.OtherPatientIDsSequence,
        DicomTag.EthnicGroup,
        DicomTag.PatientComments,
        // Study/Series/Acquisition dates and times
        DicomTag.StudyDate,
        DicomTag.StudyTime,
        DicomTag.SeriesDate,
        DicomTag.SeriesTime,
        DicomTag.AcquisitionDate,
        DicomTag.AcquisitionTime,
        DicomTag.ContentDate,
        DicomTag.ContentTime,
        DicomTag.AcquisitionDateTime,
        DicomTag.StudyDescription,
        DicomTag.AccessionNumber,
        DicomTag.StudyID,
        // Physician / institution
        DicomTag.ReferringPhysicianName,
        DicomTag.PhysiciansOfRecord,
        DicomTag.PerformingPhysicianName,
        DicomTag.NameOfPhysiciansReadingStudy,
        DicomTag.OperatorsName,
        DicomTag.InstitutionName,
        DicomTag.InstitutionalDepartmentName,
        DicomTag.StationName,
        // Series text (keep SeriesInstanceUID, Modality, Number, SeriesDescription)
        DicomTag.ProtocolName,
    };

    /// <summary>
    /// Applies privacy mode to all DICOM files in DIR000/.
    /// Opens each file, modifies/removes tags, saves in-place.
    /// Returns count of files processed.
    /// </summary>
    /// <param name="anonymousLabel">Unique label per study for Anonymize mode (e.g. "Anonymous 1").
    /// When null, defaults to "Anonymous". MUST be unique per study in multi-study burns,
    /// otherwise Siemens merges all studies into one PATIENT record.</param>
    private int ApplyPrivacyMode(string dir000Path, DicomPrivacyMode mode, string? anonymousLabel = null)
    {
        if (mode == DicomPrivacyMode.None) return 0;

        var dir000 = new DirectoryInfo(dir000Path);
        if (!dir000.Exists) return 0;

        var anonName = anonymousLabel ?? "Anonymous";
        int processed = 0;

        foreach (var file in dir000.EnumerateFiles("*.DCM", SearchOption.AllDirectories))
        {
            try
            {
                // ReadAll: closes file handle before Save() — see ApplyPrivacyModeRange comment
                var dcmFile = DicomFile.Open(file.FullName, FileReadOption.ReadAll);
                var ds = dcmFile.Dataset;

                if (mode == DicomPrivacyMode.Anonymize)
                {
                    foreach (var (tag, replaceValue) in AnonymizeTags)
                    {
                        if (replaceValue == null)
                            ds.Remove(tag);
                        else if (tag == DicomTag.PatientName || tag == DicomTag.PatientID || tag == DicomTag.AccessionNumber)
                            ds.AddOrUpdate(tag, anonName);
                        else
                            ds.AddOrUpdate(tag, replaceValue);
                    }
                }
                else if (mode == DicomPrivacyMode.HideAll)
                {
                    foreach (var tag in HideAllTags)
                        ds.Remove(tag);
                    // Keep unique PatientName/ID for multi-study DICOMDIR separation
                    // Without this, Siemens merges all studies into one empty PATIENT record
                    if (anonName != "Anonymous")
                    {
                        ds.AddOrUpdate(DicomTag.PatientName, anonName);
                        ds.AddOrUpdate(DicomTag.PatientID, anonName);
                    }
                }

                dcmFile.Save(file.FullName);
                processed++;
            }
            catch (Exception ex)
            {
                Log($"Privacy mode error ({file.Name}): {ex.Message}");
            }
        }

        return processed;
    }

    // ================================================================
    // Study metadata persistence — saved BEFORE privacy mode is applied
    // so that PatientName/StudyDate can be recovered on app restart
    // even if HideAll removed all demographic tags from DICOM files.
    // ================================================================

    private static readonly JsonSerializerOptions StudyInfoJsonOptions = new()
    {
        WriteIndented = true
    };

    /// <summary>
    /// Saves study metadata to study-info.json in the study directory.
    /// Called BEFORE ApplyPrivacyMode() to preserve PatientName, StudyDate, etc.
    /// On app restart, ScanIncomingFolder() reads this file first (before DICOM headers).
    /// </summary>
    public void SaveStudyInfo(ReceivedStudy study)
    {
        try
        {
            var info = new Dictionary<string, string>
            {
                ["PatientName"] = study.PatientName,
                ["PatientId"] = study.PatientId,
                ["StudyDate"] = study.StudyDate,
                ["Modality"] = study.Modality,
                ["StudyInstanceUid"] = study.StudyInstanceUid,
                ["ImageCount"] = study.ImageCount.ToString(),
                ["SeriesCount"] = study.SeriesCount.ToString()
            };

            var jsonPath = Path.Combine(study.StoragePath, "study-info.json");
            var json = JsonSerializer.Serialize(info, StudyInfoJsonOptions);
            File.WriteAllText(jsonPath, json);
        }
        catch (Exception ex)
        {
            Log($"Warning: Could not save study-info.json: {ex.Message}");
        }
    }
}
