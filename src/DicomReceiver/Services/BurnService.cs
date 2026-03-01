using System;
using System.Diagnostics;
using System.IO;
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
        study.StatusText = "Preparing...";

        try
        {
            // Find project root (burn.ps1 location)
            var projectRoot = FindProjectRoot();
            if (projectRoot == null)
                throw new FileNotFoundException("Cannot find project root (scripts/burn.ps1)");

            var burnScript = Path.Combine(projectRoot, "scripts", "burn-gui.ps1");
            if (!File.Exists(burnScript))
                burnScript = Path.Combine(projectRoot, "scripts", "burn.ps1");

            if (!File.Exists(burnScript))
                throw new FileNotFoundException("Burn script not found");

            // Create a temporary ZIP from the study's DICOM folder
            var tempZip = Path.Combine(Path.GetTempPath(), $"dicom-burn-{study.StudyInstanceUid[..8]}.zip");

            study.StatusText = "Creating ZIP...";
            LogMessage?.Invoke(this, $"Creating ZIP: {tempZip}");

            if (File.Exists(tempZip)) File.Delete(tempZip);
            await Task.Run(() => System.IO.Compression.ZipFile.CreateFromDirectory(study.StoragePath, tempZip));

            study.StatusText = "Burning...";
            LogMessage?.Invoke(this, $"Launching burn: {burnScript}");

            // Launch burn-gui.ps1 with the ZIP
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-ExecutionPolicy Bypass -File \"{burnScript}\" -ZipPath \"{tempZip}\" -BurnSpeed {settings.BurnSpeed}",
                UseShellExecute = false,
                CreateNoWindow = true
            };

            var process = Process.Start(psi);
            if (process != null)
            {
                await process.WaitForExitAsync();

                if (process.ExitCode == 0)
                {
                    study.Status = StudyStatus.Done;
                    study.StatusText = "Burned";
                    LogMessage?.Invoke(this, "Burn completed successfully");
                }
                else
                {
                    study.Status = StudyStatus.Error;
                    study.StatusText = $"Burn failed (exit {process.ExitCode})";
                    LogMessage?.Invoke(this, $"Burn failed with exit code {process.ExitCode}");
                }
            }

            // Cleanup temp ZIP
            try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch { }
        }
        catch (Exception ex)
        {
            study.Status = StudyStatus.Error;
            study.StatusText = $"Error: {ex.Message}";
            LogMessage?.Invoke(this, $"Burn error: {ex.Message}");
        }
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
