using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Threading.Tasks;

namespace DicomReceiver.Services;

/// <summary>
/// Manages PACS download paths and Windows Defender exclusions.
/// ZIP processing is handled directly by burn-gui.ps1 via BurnService.BurnZipAsync().
/// </summary>
public class PacsDownloadService
{
    private readonly string _downloadFolder;

    public event EventHandler<string>? LogMessage;

    public PacsDownloadService(string downloadFolder)
    {
        _downloadFolder = downloadFolder;
        Directory.CreateDirectory(_downloadFolder);

        // Add Defender exclusion in background (permanent, survives reboots)
        Task.Run(() => AddDefenderExclusion(_downloadFolder));
    }

    /// <summary>
    /// Returns the download destination path for a given filename.
    /// Called from PacsViewModel when WebView2 DownloadStarting fires.
    /// </summary>
    public string GetDownloadPath(string originalFilename)
    {
        var safeName = string.Join("_", originalFilename.Split(Path.GetInvalidFileNameChars()));
        if (string.IsNullOrEmpty(safeName)) safeName = $"download-{DateTime.Now:yyyyMMdd-HHmmss}.zip";
        return Path.Combine(_downloadFolder, safeName);
    }

    /// <summary>
    /// Deletes ZIP files in downloads/ older than specified hours.
    /// Called at startup to clean crash-orphaned ZIPs.
    /// </summary>
    public void CleanupOldDownloads(int maxAgeHours = 24)
    {
        try
        {
            foreach (var file in Directory.GetFiles(_downloadFolder, "*.zip"))
            {
                if ((DateTime.Now - File.GetLastWriteTime(file)).TotalHours > maxAgeHours)
                {
                    try
                    {
                        File.Delete(file);
                        Log($"Cleaned up old ZIP: {Path.GetFileName(file)}");
                    }
                    catch { }
                }
            }
        }
        catch { }
    }

    /// <summary>
    /// Adds Windows Defender real-time scanning exclusion for a folder.
    /// Prevents 100% CPU on Antimalware Service Executable during ZIP extraction.
    /// </summary>
    private void AddDefenderExclusion(string folderPath)
    {
        try
        {
            var fullPath = Path.GetFullPath(folderPath);

            // Check if exclusion already exists
            var checkProc = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -Command \"(Get-MpPreference -ErrorAction Stop).ExclusionPath -contains '{fullPath}'\"",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            var checkResult = checkProc?.StandardOutput.ReadToEnd().Trim();
            checkProc?.WaitForExit();

            if (string.Equals(checkResult, "True", StringComparison.OrdinalIgnoreCase))
                return; // Already excluded

            // Add exclusion (requires admin)
            bool isAdmin = new WindowsPrincipal(WindowsIdentity.GetCurrent())
                .IsInRole(WindowsBuiltInRole.Administrator);

            if (isAdmin)
            {
                var addProc = Process.Start(new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -Command \"Add-MpPreference -ExclusionPath '{fullPath}' -ErrorAction Stop\"",
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                addProc?.WaitForExit();
                if (addProc?.ExitCode == 0)
                    Log($"Defender: exclusion added for {fullPath}");
            }
        }
        catch { }
    }

    private void Log(string message) => LogMessage?.Invoke(this, message);
}
