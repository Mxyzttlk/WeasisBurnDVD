using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using DicomReceiver.Models;

namespace DicomReceiver.Services;

public class BurnService
{
    public event EventHandler<string>? LogMessage;

    /// <summary>
    /// Burns a completed study by calling burn-gui.ps1 as an external process.
    /// The study's DICOM folder is zipped first, then passed to the burn pipeline.
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
            // Create ZIP from DICOM folder
            // ============================================================
            var tempZip = Path.Combine(Path.GetTempPath(), $"dicom-burn-{study.StudyInstanceUid[..8]}.zip");

            study.StatusText = "Creating ZIP...";
            LogMessage?.Invoke(this, $"Creating ZIP: {tempZip}");

            if (File.Exists(tempZip)) File.Delete(tempZip);
            await Task.Run(() => System.IO.Compression.ZipFile.CreateFromDirectory(study.StoragePath, tempZip));

            // Verify ZIP was actually created and is not empty
            var zipInfo = new FileInfo(tempZip);
            if (!zipInfo.Exists || zipInfo.Length == 0)
            {
                throw new IOException("ZIP creation failed — file is empty or missing");
            }

            LogMessage?.Invoke(this, $"ZIP created: {FormatSize(zipInfo.Length)}");

            // ============================================================
            // Launch burn script
            // ============================================================
            study.StatusText = "Burning...";
            LogMessage?.Invoke(this, $"Launching burn: {Path.GetFileName(burnScript)}");

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-ExecutionPolicy Bypass -File \"{burnScript}\" -ZipPath \"{tempZip}\" -BurnSpeed {settings.BurnSpeed}",
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

            // Cleanup temp ZIP
            try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch { }

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
        }
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
