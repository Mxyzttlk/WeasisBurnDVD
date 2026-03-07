using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
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
    /// Burns a completed study by calling burn.ps1 as an external process.
    /// Restructures DICOM files IN-PLACE (File.Move) to PACS-compatible layout,
    /// generates DICOMDIR, then passes the folder to burn.ps1 -DicomFolder.
    /// No temporary copy — instant on same drive.
    /// </summary>
    public async Task BurnStudyAsync(ReceivedStudy study, AppSettings settings)
    {
        if (study.Status != StudyStatus.Complete)
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

            var prepResult = await Task.Run(() => RestructureInPlace(study.StoragePath, projectRoot));

            Log($"Moved {prepResult.FilesCopied} files in {prepResult.SeriesCount} series to DIR000/");

            // Apply privacy mode (Anonymize / HideAll) BEFORE DICOMDIR generation
            // Per-study: each study has its own PrivacyMode toggle
            if (study.PrivacyMode != DicomPrivacyMode.None)
            {
                var dir000Path = Path.Combine(study.StoragePath, "DIR000");
                var privacyCount = await Task.Run(() => ApplyPrivacyMode(dir000Path, study.PrivacyMode));
                var modeKey = study.PrivacyMode == DicomPrivacyMode.Anonymize ? "AnonymizeApplied" : "HideAllApplied";
                Log(string.Format(LocalizationHelper.Get(modeKey), privacyCount));
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

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = args,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi);
            if (process != null)
            {
                await process.WaitForExitAsync();

                if (process.ExitCode == 0)
                {
                    study.Status = StudyStatus.Done;
                    study.StatusText = "Burned";
                    Log($"Burn completed: {study.PatientName}");
                }
                else
                {
                    study.Status = StudyStatus.Error;
                    study.StatusText = $"Burn failed (exit {process.ExitCode})";
                    Log($"Burn failed with exit code {process.ExitCode}");
                }
            }
            else
            {
                throw new InvalidOperationException("Failed to start burn process");
            }

            // Cleanup study folder after successful burn — prevents disk filling up
            if (study.Status == StudyStatus.Done)
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
            study.Status = StudyStatus.Error;
            study.StatusText = $"Error: {ex.Message}";
            Log($"Burn error: {ex.Message}");
        }
    }

    /// <summary>
    /// Burns multiple completed studies onto a single disc.
    /// Creates a staging folder, merges all studies' DICOM files into DIR000/ with
    /// continuous series numbering, generates a single DICOMDIR, then burns.
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

        try
        {
            foreach (var study in studies)
            {
                if (study.Status != StudyStatus.Complete)
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
            // Merge all studies into staging/DIR000/ with continuous numbering
            // ============================================================
            foreach (var study in studies)
                study.StatusText = "Preparing...";

            int seriesOffset = 0;
            int totalMoved = 0;
            int totalSeries = 0;
            var allErrors = new List<string>();

            // Track per-study series ranges for per-study privacy application
            var studySeriesRanges = new List<(ReceivedStudy study, int fromSeries, int toSeriesExclusive)>();

            await Task.Run(() =>
            {
                foreach (var study in studies)
                {
                    int startSeries = seriesOffset;

                    var prepResult = RestructureInPlace(
                        study.StoragePath, projectRoot,
                        stagingDir: stagingDir,
                        seriesOffset: seriesOffset);

                    totalMoved += prepResult.FilesCopied;
                    totalSeries += prepResult.SeriesCount;
                    seriesOffset = prepResult.NextSeriesOffset;
                    allErrors.AddRange(prepResult.Errors);

                    studySeriesRanges.Add((study, startSeries, seriesOffset));

                    Log($"Merged: {study.PatientName} — {prepResult.FilesCopied} files, {prepResult.SeriesCount} series (offset → {seriesOffset})");
                }
            });

            Log($"Total merged: {totalMoved} files in {totalSeries} series to DIR000/");

            // Apply privacy mode per-study — each study has its own PrivacyMode toggle
            // Process only the series directories belonging to each study (by series range)
            // Batched into single Task.Run() to avoid thread pool overhead per study
            var privacyRanges = studySeriesRanges
                .Where(r => r.study.PrivacyMode != DicomPrivacyMode.None)
                .ToList();

            if (privacyRanges.Count > 0)
            {
                var dir000 = Path.Combine(stagingDir, "DIR000");
                var privacyResults = await Task.Run(() =>
                {
                    var results = new List<(ReceivedStudy study, int count)>();
                    foreach (var (study, fromSeries, toSeriesExclusive) in privacyRanges)
                    {
                        var count = ApplyPrivacyModeRange(dir000, study.PrivacyMode, fromSeries, toSeriesExclusive);
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
            // Generate DICOMDIR from merged staging/DIR000/
            // ============================================================
            var dir000Path = Path.Combine(stagingDir, "DIR000");
            var dicomdirPath = Path.Combine(stagingDir, "DICOMDIR");

            int imageRecords = TryGenerateDicomdirFoDicom(dir000Path, dicomdirPath, allErrors);
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

            await process.WaitForExitAsync();

            if (process.ExitCode == 0)
            {
                // Determine disc label for log
                var patients = studies.Select(s => s.PatientName).Distinct().ToList();
                var label = patients.Count == 1 ? patients[0] : "Multiple";

                foreach (var study in studies)
                {
                    study.Status = StudyStatus.Done;
                    study.StatusText = "Burned";
                }
                Log($"Burn completed: {label} ({studies.Count} studies, {totalFiles} images)");
            }
            else
            {
                foreach (var study in studies)
                {
                    study.Status = StudyStatus.Error;
                    study.StatusText = $"Burn failed (exit {process.ExitCode})";
                }
                Log($"Burn failed with exit code {process.ExitCode}");
            }

            // ============================================================
            // Cleanup: staging folder + original study folders
            // ============================================================
            if (studies.All(s => s.Status == StudyStatus.Done))
            {
                // Delete staging folder
                try
                {
                    if (Directory.Exists(stagingDir))
                    {
                        Directory.Delete(stagingDir, true);
                        Log($"Cleaned up staging: {stagingDir}");
                    }
                }
                catch (Exception ex) { Log($"Staging cleanup warning: {ex.Message}"); }

                // Delete original study folders (files already moved to staging, may be empty or have leftovers)
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
        catch (Exception ex)
        {
            foreach (var study in studies)
            {
                study.Status = StudyStatus.Error;
                study.StatusText = $"Error: {ex.Message}";
            }
            Log($"Multi-burn error: {ex.Message}");

            // Cleanup staging folder on error (prevent disk space accumulation)
            if (stagingDir != null)
            {
                try
                {
                    if (Directory.Exists(stagingDir))
                    {
                        Directory.Delete(stagingDir, true);
                        Log($"Cleaned up staging after error: {stagingDir}");
                    }
                }
                catch { /* best effort */ }
            }
        }
    }

    private class PrepareResult
    {
        public int FilesCopied { get; set; }
        public int SeriesCount { get; set; }
        public int NextSeriesOffset { get; set; } // For multi-study: next available series number
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
    /// <param name="stagingDir">If set, move files to stagingDir/DIR000/ instead of studyPath/DIR000/ (multi-study)</param>
    /// <param name="seriesOffset">Starting series number (for multi-study continuous numbering)</param>
    private PrepareResult RestructureInPlace(string studyPath, string? projectRoot,
        string? stagingDir = null, int seriesOffset = 0)
    {
        var result = new PrepareResult();

        // Multi-study: output to staging folder; single-study: output in-place
        var outputRoot = stagingDir ?? studyPath;
        var dir000 = Path.Combine(outputRoot, "DIR000");
        Directory.CreateDirectory(dir000);

        var sourceDir = new DirectoryInfo(studyPath);
        int seriesNum = seriesOffset;

        // ============================================================
        // Step 1: Move DICOM files to DIR000/ with PACS naming (8-digit)
        // File.Move() is instant on the same drive (NTFS metadata update only)
        // ============================================================

        // Enumerate series directories (skip DIR000 we just created)
        var seriesDirs = sourceDir.GetDirectories()
            .Where(d => !d.Name.Equals("DIR000", StringComparison.OrdinalIgnoreCase))
            .ToArray();

        foreach (var seriesDir in seriesDirs)
        {
            var seriesName = seriesNum.ToString("D8"); // 00000000, 00000001, ...
            var destSeriesDir = Path.Combine(dir000, seriesName);
            Directory.CreateDirectory(destSeriesDir);

            var files = seriesDir.GetFiles("*.dcm", SearchOption.AllDirectories);
            int fileNum = 0;

            foreach (var file in files)
            {
                var fileName = fileNum.ToString("D8") + ".DCM"; // Keep .DCM like PACS
                var destPath = Path.Combine(destSeriesDir, fileName);
                File.Move(file.FullName, destPath);
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
                Directory.Delete(destSeriesDir); // Remove empty DIR000 series dir
            }
        }

        // Handle .dcm files directly in study root (no series subdirectory)
        var rootFiles = sourceDir.GetFiles("*.dcm", SearchOption.TopDirectoryOnly);
        if (rootFiles.Length > 0)
        {
            var seriesName = seriesNum.ToString("D8");
            var destSeriesDir = Path.Combine(dir000, seriesName);
            Directory.CreateDirectory(destSeriesDir);

            int fileNum = 0;
            foreach (var file in rootFiles)
            {
                var fileName = fileNum.ToString("D8") + ".DCM";
                var destPath = Path.Combine(destSeriesDir, fileName);
                File.Move(file.FullName, destPath);
                result.FilesCopied++;
                fileNum++;
            }
            seriesNum++;
        }

        result.SeriesCount = seriesNum - seriesOffset;
        result.NextSeriesOffset = seriesNum;

        // ============================================================
        // Step 2: Generate DICOMDIR — fo-dicom first, dcmmkdir fallback
        // (skipped in multi-study mode — caller generates DICOMDIR after all studies merged)
        // ============================================================
        if (stagingDir != null)
            return result; // Multi-study: DICOMDIR generated by caller after merging all studies

        var dicomdirPath = Path.Combine(outputRoot, "DICOMDIR");

        result.ImageRecordsAdded = TryGenerateDicomdirFoDicom(dir000, dicomdirPath, result.Errors);

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
    /// Generates DICOMDIR using fo-dicom DicomDirectory.
    /// Returns the number of IMAGE records successfully added.
    /// Uses FileReadOption.SkipLargeTags — DICOMDIR needs only metadata,
    /// not pixel data. Saves ~250 MB RAM for a 500-image study.
    /// </summary>
    private static int TryGenerateDicomdirFoDicom(string dir000Path, string dicomdirPath, List<string> errors)
    {
        int imageRecords = 0;

        try
        {
            var dicomDir = new DicomDirectory();

            var dir000 = new DirectoryInfo(dir000Path);
            foreach (var seriesDir in dir000.GetDirectories().OrderBy(d => d.Name))
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
                        // Path: DIR000\00000000\00000000.DCM (matches PACS format)
                        var refFileId = $@"DIR000\{seriesDir.Name}\{file.Name}";
                        dicomDir.AddFile(dcmFile, refFileId);
                        imageRecords++;
                    }
                    catch (Exception ex)
                    {
                        errors.Add($"fo-dicom AddFile {seriesDir.Name}/{file.Name}: {ex.Message}");
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

            // Read stderr async to prevent deadlock (buffer full blocks process)
            var stderrTask = process.StandardError.ReadToEndAsync();
            var exited = process.WaitForExit(60_000); // 60 sec timeout

            if (!exited)
            {
                try { process.Kill(); } catch { }
                errors.Add("dcmmkdir: timed out after 60 sec (killed)");
                return false;
            }

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
        // Study info
        DicomTag.StudyDate,
        DicomTag.StudyTime,
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
        // Series text (keep SeriesInstanceUID, Modality, Number)
        DicomTag.SeriesDescription,
        DicomTag.ProtocolName,
    };

    /// <summary>
    /// Applies privacy mode to a range of series directories in DIR000/ (for multi-study burn).
    /// Series directories are named 00000000, 00000001, etc. — applies only to [fromSeries, toSeriesExclusive).
    /// </summary>
    private int ApplyPrivacyModeRange(string dir000Path, DicomPrivacyMode mode, int fromSeries, int toSeriesExclusive)
    {
        if (mode == DicomPrivacyMode.None) return 0;

        var dir000 = new DirectoryInfo(dir000Path);
        if (!dir000.Exists) return 0;

        int processed = 0;

        for (int s = fromSeries; s < toSeriesExclusive; s++)
        {
            var seriesDir = new DirectoryInfo(Path.Combine(dir000Path, s.ToString("D8")));
            if (!seriesDir.Exists) continue;

            foreach (var file in seriesDir.EnumerateFiles("*.DCM", SearchOption.AllDirectories))
            {
                try
                {
                    // ReadAll: reads entire file (including pixel data) into memory and CLOSES the file handle.
                    // Default (ReadLargeOnDemand) keeps the FileStream open for lazy pixel data loading,
                    // which blocks Save() to the same file → "The process cannot access the file" error.
                    var dcmFile = DicomFile.Open(file.FullName, FileReadOption.ReadAll);
                    var ds = dcmFile.Dataset;

                    if (mode == DicomPrivacyMode.Anonymize)
                    {
                        foreach (var (tag, replaceValue) in AnonymizeTags)
                        {
                            if (replaceValue == null)
                                ds.Remove(tag);
                            else
                                ds.AddOrUpdate(tag, replaceValue);
                        }
                    }
                    else if (mode == DicomPrivacyMode.HideAll)
                    {
                        foreach (var tag in HideAllTags)
                            ds.Remove(tag);
                    }

                    dcmFile.Save(file.FullName);
                    processed++;
                }
                catch (Exception ex)
                {
                    Log($"Privacy mode error ({file.Name}): {ex.Message}");
                }
            }
        }

        return processed;
    }

    /// <summary>
    /// Applies privacy mode to all DICOM files in DIR000/.
    /// Opens each file, modifies/removes tags, saves in-place.
    /// Returns count of files processed.
    /// </summary>
    private int ApplyPrivacyMode(string dir000Path, DicomPrivacyMode mode)
    {
        if (mode == DicomPrivacyMode.None) return 0;

        var dir000 = new DirectoryInfo(dir000Path);
        if (!dir000.Exists) return 0;

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
                        else
                            ds.AddOrUpdate(tag, replaceValue);
                    }
                }
                else if (mode == DicomPrivacyMode.HideAll)
                {
                    foreach (var tag in HideAllTags)
                        ds.Remove(tag);
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
}
