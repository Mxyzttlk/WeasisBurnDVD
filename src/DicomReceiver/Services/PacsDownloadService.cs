using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using FellowOakDicom;

namespace DicomReceiver.Services;

public class DownloadProgressEventArgs : EventArgs
{
    public string FileName { get; init; } = "";
    public long BytesReceived { get; init; }
    public long TotalBytes { get; init; }
    public int PercentComplete { get; init; }
}

public class DownloadCompleteEventArgs : EventArgs
{
    public string ZipPath { get; init; } = "";
    public string FileName { get; init; } = "";
    public long SizeBytes { get; init; }
    public bool Success { get; init; }
    public string? Error { get; init; }
    public int ImageCount { get; init; }
    public string PatientName { get; init; } = "";
    public string StudyInstanceUid { get; init; } = "";
}

public class PacsDownloadService
{
    private readonly StudyMonitorService _monitorService;
    private readonly string _downloadFolder;
    private readonly string _incomingFolder;
    private DateTime _lastProgressUpdate = DateTime.MinValue;
    private readonly SemaphoreSlim _processingLock = new(1, 1);

    public event EventHandler<DownloadProgressEventArgs>? DownloadProgress;
    public event EventHandler<DownloadCompleteEventArgs>? DownloadCompleted;
    public event EventHandler<string>? LogMessage;

    public bool IsProcessing => _processingLock.CurrentCount == 0;

    public PacsDownloadService(
        StudyMonitorService monitorService,
        string downloadFolder,
        string incomingFolder)
    {
        _monitorService = monitorService;
        _downloadFolder = downloadFolder;
        _incomingFolder = incomingFolder;
        Directory.CreateDirectory(_downloadFolder);
        Directory.CreateDirectory(_incomingFolder);

        // Add Windows Defender exclusions for download + incoming folders
        // Prevents 100% CPU (Antimalware Service Executable) during ZIP extraction
        Task.Run(() =>
        {
            AddDefenderExclusion(_downloadFolder);
            AddDefenderExclusion(_incomingFolder);
        });
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
    /// Throttled progress update — max 2 updates/sec (500ms interval).
    /// Called from PacsViewModel on BytesReceivedChanged.
    /// </summary>
    public void OnBytesReceived(string filename, long received, long total)
    {
        var now = DateTime.UtcNow;
        if ((now - _lastProgressUpdate).TotalMilliseconds < 500) return;
        _lastProgressUpdate = now;

        int pct = total > 0 ? (int)(received * 100 / total) : 0;
        DownloadProgress?.Invoke(this, new DownloadProgressEventArgs
        {
            FileName = filename,
            BytesReceived = received,
            TotalBytes = total,
            PercentComplete = pct
        });
    }

    /// <summary>
    /// Process a completed ZIP download: extract, find DICOM, add to incoming/ folder.
    /// Runs on Task.Run() to avoid blocking UI. Feeds StudyMonitorService.OnFileReceived().
    /// </summary>
    public async Task ProcessCompletedDownloadAsync(string zipPath)
    {
        // SemaphoreSlim serializes concurrent ZIPs (real queue, not dropped)
        await _processingLock.WaitAsync();
        var fileName = Path.GetFileName(zipPath);

        try
        {
            Log($"Processing ZIP: {fileName}...");

            var result = await Task.Run(() => ExtractAndImport(zipPath));

            DownloadCompleted?.Invoke(this, new DownloadCompleteEventArgs
            {
                ZipPath = zipPath,
                FileName = fileName,
                SizeBytes = new FileInfo(zipPath).Length,
                Success = true,
                ImageCount = result.ImageCount,
                PatientName = result.PatientName,
                StudyInstanceUid = result.StudyInstanceUid
            });
        }
        catch (Exception ex)
        {
            Log($"ZIP processing error: {ex.Message}");
            DownloadCompleted?.Invoke(this, new DownloadCompleteEventArgs
            {
                ZipPath = zipPath,
                FileName = fileName,
                SizeBytes = File.Exists(zipPath) ? new FileInfo(zipPath).Length : 0,
                Success = false,
                Error = ex.Message
            });
        }
        finally
        {
            _processingLock.Release();
        }
    }

    private (int ImageCount, string PatientName, string StudyInstanceUid) ExtractAndImport(string zipPath)
    {
        // 1. Extract ZIP to temp folder
        var extractDir = Path.Combine(_downloadFolder, $"extract-{DateTime.Now:yyyyMMdd-HHmmss}");
        Directory.CreateDirectory(extractDir);

        try
        {
            ZipFile.ExtractToDirectory(zipPath, extractDir);
            Log($"ZIP extracted to {extractDir}");

            // 2. Find DICOM files — check two layouts
            string? dicomRoot = null;
            string? dicomdirPath = null;

            // Layout A: "Exclude Viewer" ZIP — DIR000/ at root
            var dir000AtRoot = Path.Combine(extractDir, "DIR000");
            if (Directory.Exists(dir000AtRoot))
            {
                dicomRoot = dir000AtRoot;
                var rootDicomdir = Path.Combine(extractDir, "DICOMDIR");
                if (File.Exists(rootDicomdir))
                    dicomdirPath = rootDicomdir;
                Log("ZIP layout: Exclude Viewer (DIR000 at root)");
            }

            // Layout B: "With Viewer" ZIP — DICOM inside viewer-mac.app/Contents/DICOM/DIR000/
            if (dicomRoot == null)
            {
                var viewerMacDicom = Directory.GetDirectories(extractDir, "DIR000", SearchOption.AllDirectories)
                    .FirstOrDefault();
                if (viewerMacDicom != null)
                {
                    dicomRoot = viewerMacDicom;
                    // Look for DICOMDIR one level above DIR000
                    var parentDicomdir = Path.Combine(Path.GetDirectoryName(viewerMacDicom)!, "DICOMDIR");
                    if (File.Exists(parentDicomdir))
                        dicomdirPath = parentDicomdir;
                    Log("ZIP layout: With Viewer (DIR000 nested)");
                }
            }

            // Layout C: No DIR000 — search for .dcm files directly
            if (dicomRoot == null)
            {
                var dcmFiles = Directory.GetFiles(extractDir, "*.dcm", SearchOption.AllDirectories)
                    .Concat(Directory.GetFiles(extractDir, "*.DCM", SearchOption.AllDirectories))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();

                if (dcmFiles.Count == 0)
                    throw new InvalidOperationException("No DICOM files found in ZIP");

                // Use the parent of the first DCM file as root
                dicomRoot = Path.GetDirectoryName(dcmFiles[0])!;
                Log($"ZIP layout: flat ({dcmFiles.Count} DCM files found)");
            }

            // 3. Parse one DICOM file for metadata
            var firstDcm = Directory.EnumerateFiles(dicomRoot, "*.*", SearchOption.AllDirectories)
                .FirstOrDefault(f => f.EndsWith(".dcm", StringComparison.OrdinalIgnoreCase) ||
                                     f.EndsWith(".DCM", StringComparison.OrdinalIgnoreCase) ||
                                     !Path.HasExtension(f));

            string studyUid = Guid.NewGuid().ToString();
            string patientName = "Unknown";
            string patientId = "";
            string studyDate = "";
            string modality = "";

            if (firstDcm != null)
            {
                try
                {
                    var dcmFile = DicomFile.Open(firstDcm, FileReadOption.SkipLargeTags);
                    var ds = dcmFile.Dataset;
                    studyUid = ds.GetSingleValueOrDefault(DicomTag.StudyInstanceUID, Guid.NewGuid().ToString());
                    patientName = ds.GetSingleValueOrDefault(DicomTag.PatientName, "Unknown");
                    patientId = ds.GetSingleValueOrDefault(DicomTag.PatientID, "");
                    studyDate = ds.GetSingleValueOrDefault(DicomTag.StudyDate, "");
                    modality = ds.GetSingleValueOrDefault(DicomTag.Modality, "");
                }
                catch (Exception ex)
                {
                    Log($"Warning: could not parse DICOM header: {ex.Message}");
                }
            }

            // 4. Copy to incoming/{StudyUID}/
            var studyDir = Path.Combine(_incomingFolder, studyUid);
            Directory.CreateDirectory(studyDir);

            // Copy DIR000 structure
            var destDir000 = Path.Combine(studyDir, "DIR000");
            if (Path.GetFileName(dicomRoot) == "DIR000")
            {
                CopyDirectory(dicomRoot, destDir000);
            }
            else
            {
                // Non-standard layout — copy all DICOM files into DIR000/00000000/
                Directory.CreateDirectory(Path.Combine(destDir000, "00000000"));
                int idx = 0;
                foreach (var f in Directory.EnumerateFiles(dicomRoot, "*.*", SearchOption.AllDirectories))
                {
                    var dest = Path.Combine(destDir000, "00000000", $"{idx:D8}.DCM");
                    File.Copy(f, dest);
                    idx++;
                }
            }

            // Copy DICOMDIR if exists
            if (dicomdirPath != null)
            {
                File.Copy(dicomdirPath, Path.Combine(studyDir, "DICOMDIR"), overwrite: true);
            }

            // 5. Feed files through StudyMonitorService.OnFileReceived()
            var allDcmFiles = Directory.GetFiles(destDir000, "*.*", SearchOption.AllDirectories);
            int imageCount = 0;
            var seriesUids = new HashSet<string>();

            foreach (var dcmPath in allDcmFiles)
            {
                string seriesUid = "1";
                string seriesDesc = "";
                string sopModality = modality;

                try
                {
                    var dcmFile = DicomFile.Open(dcmPath, FileReadOption.SkipLargeTags);
                    var ds = dcmFile.Dataset;
                    seriesUid = ds.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, "1");
                    seriesDesc = ds.GetSingleValueOrDefault(DicomTag.SeriesDescription, "");
                    sopModality = ds.GetSingleValueOrDefault(DicomTag.Modality, modality);
                }
                catch { }

                seriesUids.Add(seriesUid);

                _monitorService.OnFileReceived(new FileReceivedEventArgs
                {
                    StudyInstanceUid = studyUid,
                    PatientName = patientName,
                    PatientId = patientId,
                    StudyDate = studyDate,
                    Modality = sopModality,
                    SeriesInstanceUid = seriesUid,
                    SeriesDescription = seriesDesc,
                    FilePath = dcmPath,
                    FileSize = new FileInfo(dcmPath).Length
                });

                imageCount++;
            }

            Log($"Imported: {patientName} — {imageCount} images, {seriesUids.Count} series");

            // Force study to Complete immediately (skip 30s timeout — all files already on disk)
            _monitorService.ForceCompleteStudy(studyUid);

            return (imageCount, patientName, studyUid);
        }
        finally
        {
            // 6. Cleanup extracted temp folder (keep ZIP for reference)
            try
            {
                if (Directory.Exists(extractDir))
                    Directory.Delete(extractDir, true);
            }
            catch { }
        }
    }

    private static void CopyDirectory(string source, string dest)
    {
        Directory.CreateDirectory(dest);

        foreach (var file in Directory.GetFiles(source))
        {
            File.Copy(file, Path.Combine(dest, Path.GetFileName(file)));
        }

        foreach (var dir in Directory.GetDirectories(source))
        {
            CopyDirectory(dir, Path.Combine(dest, Path.GetFileName(dir)));
        }
    }

    /// <summary>
    /// Adds Windows Defender real-time scanning exclusion for a folder.
    /// Prevents 100% CPU on Antimalware Service Executable during ZIP extraction.
    /// Mirrors burn-gui.ps1 STEP 2b logic. Exclusion is permanent (survives reboots).
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
                return; // Already excluded — nothing to do

            // Try to add exclusion — requires admin privileges
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
            // Non-admin: silently skip — UAC prompt would be intrusive for a non-critical optimization
        }
        catch
        {
            // Defender disabled, not installed, or other issue — silently ignore
        }
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(this, message);
    }
}
