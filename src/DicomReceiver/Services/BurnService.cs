using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
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
    private PrepareResult RestructureInPlace(string studyPath, string? projectRoot)
    {
        var result = new PrepareResult();

        var dir000 = Path.Combine(studyPath, "DIR000");
        Directory.CreateDirectory(dir000);

        var sourceDir = new DirectoryInfo(studyPath);
        int seriesNum = 0;

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

        result.SeriesCount = seriesNum;

        // ============================================================
        // Step 2: Generate DICOMDIR — fo-dicom first, dcmmkdir fallback
        // ============================================================
        var dicomdirPath = Path.Combine(studyPath, "DICOMDIR");

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
                var dcmSuccess = TryGenerateDicomdirDcmtk(dcmmkdirPath, studyPath, dicomdirPath, result.Errors);
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
}
