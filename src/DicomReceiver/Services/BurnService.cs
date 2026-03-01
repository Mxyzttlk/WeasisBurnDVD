using System;
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

    /// <summary>
    /// Burns a completed study by calling burn.ps1 as an external process.
    /// Prepares a folder with normalized DICOM structure + DICOMDIR (via fo-dicom),
    /// then passes it to burn.ps1 -DicomFolder (no ZIP creation/extraction needed).
    /// </summary>
    public async Task BurnStudyAsync(ReceivedStudy study, AppSettings settings)
    {
        if (study.Status != StudyStatus.Complete)
            throw new InvalidOperationException("Study is not complete");

        study.Status = StudyStatus.Burning;
        study.StatusText = "Validating...";

        string? preparedDir = null;

        try
        {
            // ============================================================
            // CRITICAL: Validate DICOM files exist on disk BEFORE burning
            // Prevents the eFilm bug where burn ran with empty/missing data
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
            LogMessage?.Invoke(this,
                $"Validated: {dcmFiles.Count} DICOM files, {totalSize / (1024.0 * 1024.0):F1} MB");

            // Sanity check: warn if file count doesn't match expected
            if (dcmFiles.Count != study.ImageCount)
            {
                LogMessage?.Invoke(this,
                    $"WARNING: Expected {study.ImageCount} images but found {dcmFiles.Count} on disk");
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
            // Prepare DICOM folder with normalized structure + DICOMDIR
            // No ZIP needed — files are already on disk from C-STORE SCP
            // ============================================================
            preparedDir = Path.Combine(Path.GetTempPath(),
                $"dicom-prepared-{study.StudyInstanceUid[..Math.Min(8, study.StudyInstanceUid.Length)]}");

            if (Directory.Exists(preparedDir))
                Directory.Delete(preparedDir, true);

            study.StatusText = "Preparing...";
            LogMessage?.Invoke(this, "Preparing DICOM folder + DICOMDIR...");

            await Task.Run(() => PrepareDicomFolder(study.StoragePath, preparedDir));

            // Verify DICOMDIR was created
            var dicomdirPath = Path.Combine(preparedDir, "DICOMDIR");
            if (File.Exists(dicomdirPath))
            {
                LogMessage?.Invoke(this, "DICOMDIR generated (fo-dicom)");
            }
            else
            {
                LogMessage?.Invoke(this, "WARNING: DICOMDIR generation failed — disc will work with Weasis but not medical workstations");
            }

            // ============================================================
            // Launch burn script with -DicomFolder (no ZIP)
            // ============================================================
            study.StatusText = "Burning...";
            LogMessage?.Invoke(this, $"Launching burn: {Path.GetFileName(burnScript)}");

            var args = $"-ExecutionPolicy Bypass -File \"{burnScript}\" -DicomFolder \"{preparedDir}\" -BurnSpeed {settings.BurnSpeed}";
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
                    LogMessage?.Invoke(this, $"Burn completed: {study.PatientName}");
                }
                else
                {
                    study.Status = StudyStatus.Error;
                    study.StatusText = $"Burn failed (exit {process.ExitCode})";
                    LogMessage?.Invoke(this, $"Burn failed with exit code {process.ExitCode}");
                }
            }
            else
            {
                throw new InvalidOperationException("Failed to start burn process");
            }

            // Cleanup prepared folder (temp data)
            try { if (Directory.Exists(preparedDir)) Directory.Delete(preparedDir, true); } catch { }
            preparedDir = null;

            // Cleanup incoming DICOM files after successful burn — prevents disk filling up
            // 100 patients × 80 MB = 8 GB accumulated without cleanup
            if (study.Status == StudyStatus.Done)
            {
                try
                {
                    if (Directory.Exists(study.StoragePath))
                    {
                        Directory.Delete(study.StoragePath, true);
                        LogMessage?.Invoke(this, $"Cleaned up: {study.StoragePath}");
                    }
                }
                catch (Exception cleanupEx)
                {
                    LogMessage?.Invoke(this, $"Cleanup warning: {cleanupEx.Message}");
                    // Non-fatal — burn succeeded, files can be cleaned manually
                }
            }
        }
        catch (Exception ex)
        {
            study.Status = StudyStatus.Error;
            study.StatusText = $"Error: {ex.Message}";
            LogMessage?.Invoke(this, $"Burn error: {ex.Message}");

            // Cleanup prepared folder on error too
            try { if (preparedDir != null && Directory.Exists(preparedDir)) Directory.Delete(preparedDir, true); } catch { }
        }
    }

    /// <summary>
    /// Prepares a folder with normalized DICOM structure + DICOMDIR for burning.
    /// Structure matches what burn.ps1 expects (mimics PACS "Exclude Viewer" ZIP):
    ///   prepared/
    ///   ├── DICOMDIR          ← generated by fo-dicom (paths match IMAGES/)
    ///   └── IMAGES/           ← normalized DICOM files (8.3 naming, DICOM Part 10 compliant)
    ///       ├── 001/          ← series 1
    ///       │   ├── 00001.DCM
    ///       │   └── 00002.DCM
    ///       └── 002/          ← series 2
    ///
    /// burn.ps1 sees DICOMDIR at root → treats it like a PACS ZIP → junctions IMAGES/ to disc root.
    /// Medical workstations read DICOMDIR → paths point to IMAGES\001\00001.DCM → correct!
    /// </summary>
    private void PrepareDicomFolder(string studyPath, string outputDir)
    {
        Directory.CreateDirectory(outputDir);
        var imagesDir = Path.Combine(outputDir, "IMAGES");
        Directory.CreateDirectory(imagesDir);

        var dicomDir = new DicomDirectory();
        var sourceDir = new DirectoryInfo(studyPath);

        // Enumerate series directories (incoming/{StudyUID}/{SeriesUID}/)
        var seriesDirs = sourceDir.GetDirectories();
        int seriesNum = 0;

        foreach (var seriesDir in seriesDirs)
        {
            seriesNum++;
            var seriesName = seriesNum.ToString("D3"); // 001, 002, ...
            var destSeriesDir = Path.Combine(imagesDir, seriesName);
            Directory.CreateDirectory(destSeriesDir);

            var files = seriesDir.GetFiles("*.dcm", SearchOption.AllDirectories);
            int fileNum = 0;

            foreach (var file in files)
            {
                fileNum++;
                var fileName = fileNum.ToString("D5") + ".DCM"; // 00001.DCM, 00002.DCM, ...
                var destPath = Path.Combine(destSeriesDir, fileName);
                File.Copy(file.FullName, destPath);

                // Add to DICOMDIR with correct relative path
                try
                {
                    var dcmFile = DicomFile.Open(destPath);
                    var refFileId = $@"IMAGES\{seriesName}\{fileName}";
                    dicomDir.AddFile(dcmFile, refFileId);
                }
                catch
                {
                    // Skip files that can't be parsed as DICOM
                }
            }
        }

        // Also handle .dcm files directly in study root (no series subdirectory)
        var rootFiles = sourceDir.GetFiles("*.dcm", SearchOption.TopDirectoryOnly);
        if (rootFiles.Length > 0)
        {
            seriesNum++;
            var seriesName = seriesNum.ToString("D3");
            var destSeriesDir = Path.Combine(imagesDir, seriesName);
            Directory.CreateDirectory(destSeriesDir);

            int fileNum = 0;
            foreach (var file in rootFiles)
            {
                fileNum++;
                var fileName = fileNum.ToString("D5") + ".DCM";
                var destPath = Path.Combine(destSeriesDir, fileName);
                File.Copy(file.FullName, destPath);

                try
                {
                    var dcmFile = DicomFile.Open(destPath);
                    var refFileId = $@"IMAGES\{seriesName}\{fileName}";
                    dicomDir.AddFile(dcmFile, refFileId);
                }
                catch { }
            }
        }

        // Save DICOMDIR at prepared root (same level as IMAGES/)
        dicomDir.Save(Path.Combine(outputDir, "DICOMDIR"));
    }

    private static string FormatSize(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
        if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024.0):F1} MB";
        return $"{bytes / (1024.0 * 1024.0 * 1024.0):F2} GB";
    }

    private static string? FindProjectRoot()
    {
        // Walk up from exe directory looking for scripts/burn.ps1
        var dir = AppDomain.CurrentDomain.BaseDirectory;
        for (int i = 0; i < 5; i++)
        {
            if (File.Exists(Path.Combine(dir, "scripts", "burn.ps1")))
                return dir;
            var parent = Directory.GetParent(dir);
            if (parent == null) break;
            dir = parent.FullName;
        }

        // Try known project path
        var knownPath = @"E:\Weasis Burn";
        if (File.Exists(Path.Combine(knownPath, "scripts", "burn.ps1")))
            return knownPath;

        return null;
    }
}
