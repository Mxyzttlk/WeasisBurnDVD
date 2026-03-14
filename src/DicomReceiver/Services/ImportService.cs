using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading.Tasks;
using FellowOakDicom;

namespace DicomReceiver.Services;

public enum ImportSource { Zip, Folder, Disc }

public class ImportedStudyInfo
{
    public required string StudyInstanceUid { get; init; }
    public required string StudyFolder { get; init; }
    public required List<FileReceivedEventArgs> FileArgs { get; init; }
}

public class ImportService
{
    public event EventHandler<string>? LogMessage;

    private void Log(string msg) => LogMessage?.Invoke(this, msg);

    // ====================================================================
    // ZIP Import — extracted from MainViewModel.ImportZipToQueueAsync
    // ====================================================================
    public async Task<List<ImportedStudyInfo>> ImportFromZipAsync(string zipPath, string incomingFolder)
    {
        if (!File.Exists(zipPath))
            throw new FileNotFoundException($"ZIP not found: {zipPath}");

        var tempDir = Path.Combine(Path.GetTempPath(), $"WeasisBurn-import-{DateTime.Now:yyyyMMdd-HHmmss}");
        Directory.CreateDirectory(tempDir);

        try
        {
            Log("Extracting ZIP...");
            await Task.Run(() => ZipFile.ExtractToDirectory(zipPath, tempDir));

            var (dicomSourceDir, pacsDicomdirPath) = DetectLayout(tempDir);
            if (dicomSourceDir == null)
                throw new InvalidOperationException("No DICOM files found in ZIP");

            var results = await ImportFromDicomSourceAsync(dicomSourceDir, pacsDicomdirPath, incomingFolder);
            return results;
        }
        finally
        {
            try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true); } catch { }
        }
    }

    // ====================================================================
    // Folder Import — scan for DICOM files, copy preserving structure
    // ====================================================================
    public async Task<List<ImportedStudyInfo>> ImportFromFolderAsync(string folderPath, string incomingFolder)
    {
        if (!Directory.Exists(folderPath))
            throw new DirectoryNotFoundException($"Folder not found: {folderPath}");

        var (dicomSourceDir, pacsDicomdirPath) = DetectLayout(folderPath);

        if (dicomSourceDir != null)
        {
            // Structured layout (DIR000/ etc.) — import like ZIP
            return await ImportFromDicomSourceAsync(dicomSourceDir, pacsDicomdirPath, incomingFolder);
        }

        // Flat or series-based layout — scan all DICOM files
        return await ImportFlatFolderAsync(folderPath, incomingFolder);
    }

    // ====================================================================
    // Disc Import — read from optical drive
    // ====================================================================
    public async Task<List<ImportedStudyInfo>> ImportFromDiscAsync(string driveRoot, string incomingFolder)
    {
        var driveInfo = new DriveInfo(driveRoot[..1]);
        if (!driveInfo.IsReady)
            throw new InvalidOperationException("No disc inserted in drive");

        // Our burned disc layout: DIR000/ at root + DICOMDIR
        // Also handles other disc layouts with DIR* folders
        var (dicomSourceDir, pacsDicomdirPath) = DetectLayout(driveRoot);

        if (dicomSourceDir != null)
        {
            return await ImportFromDicomSourceAsync(dicomSourceDir, pacsDicomdirPath, incomingFolder);
        }

        // Fallback: scan entire disc for DICOM files
        return await ImportFlatFolderAsync(driveRoot, incomingFolder);
    }

    // ====================================================================
    // Layout detection — 3 variants (same logic as ImportZipToQueueAsync)
    // ====================================================================
    private static (string? dicomSourceDir, string? pacsDicomdirPath) DetectLayout(string rootDir)
    {
        // Layout 1: DIR000/ at root (Exclude Viewer ZIP, our burned disc)
        if (Directory.Exists(Path.Combine(rootDir, "DIR000")))
        {
            var dicomdirPath = Path.Combine(rootDir, "DICOMDIR");
            return (rootDir, File.Exists(dicomdirPath) ? dicomdirPath : null);
        }

        // Layout 2: nested in viewer-mac.app (With Viewer PACS ZIP)
        var nestedDicom = Path.Combine(rootDir, "viewer-mac.app", "Contents", "DICOM");
        if (Directory.Exists(nestedDicom))
        {
            return (nestedDicom, null); // With-Viewer DICOMDIR has wrong paths
        }

        // Layout 3: any DIR* directories at root
        var dirDirs = new DirectoryInfo(rootDir).GetDirectories("DIR*");
        if (dirDirs.Length > 0)
        {
            var dicomdirPath = Path.Combine(rootDir, "DICOMDIR");
            return (rootDir, File.Exists(dicomdirPath) ? dicomdirPath : null);
        }

        return (null, null);
    }

    // ====================================================================
    // Structured import — DIR* directories with DICOM files
    // ====================================================================
    private async Task<List<ImportedStudyInfo>> ImportFromDicomSourceAsync(
        string dicomSourceDir, string? pacsDicomdirPath, string incomingFolder)
    {
        var sourceInfo = new DirectoryInfo(dicomSourceDir);
        var dirDirs = sourceInfo.GetDirectories("DIR*");

        if (dirDirs.Length == 0)
            throw new InvalidOperationException("No DIR* directories found");

        // Group DIR directories by StudyInstanceUID
        var studyDirMap = new Dictionary<string, List<DirectoryInfo>>();
        var studyMetadata = new Dictionary<string, (string PatientName, string PatientId,
            string StudyDate, string Modality)>();

        await Task.Run(() =>
        {
            foreach (var dirDir in dirDirs)
            {
                var firstDcm = dirDir.EnumerateFiles("*.dcm", SearchOption.AllDirectories).FirstOrDefault()
                    ?? dirDir.EnumerateFiles("*.DCM", SearchOption.AllDirectories).FirstOrDefault();

                if (firstDcm == null) continue;

                try
                {
                    var dcm = DicomFile.Open(firstDcm.FullName, FileReadOption.SkipLargeTags);
                    var ds = dcm.Dataset;
                    var studyUid = ds.GetSingleValueOrDefault(DicomTag.StudyInstanceUID, "");
                    if (string.IsNullOrEmpty(studyUid)) continue;

                    if (!studyDirMap.ContainsKey(studyUid))
                    {
                        studyDirMap[studyUid] = new List<DirectoryInfo>();
                        studyMetadata[studyUid] = (
                            ds.GetSingleValueOrDefault(DicomTag.PatientName, "Unknown"),
                            ds.GetSingleValueOrDefault(DicomTag.PatientID, ""),
                            ds.GetSingleValueOrDefault(DicomTag.StudyDate, ""),
                            ds.GetSingleValueOrDefault(DicomTag.Modality, "OT")
                        );
                    }
                    studyDirMap[studyUid].Add(dirDir);
                }
                catch { /* Skip unreadable directories */ }
            }
        });

        if (studyDirMap.Count == 0)
            throw new InvalidOperationException("No valid DICOM studies found");

        bool isSinglePatient = studyDirMap.Count == 1;
        Log($"Found {studyDirMap.Count} study(ies)");

        var results = new List<ImportedStudyInfo>();

        foreach (var (studyUid, dirs) in studyDirMap)
        {
            var meta = studyMetadata[studyUid];
            var studyFolder = Path.Combine(incomingFolder, studyUid);

            if (Directory.Exists(studyFolder))
            {
                Log($"Study already exists, skipping: {meta.PatientName}");
                continue;
            }

            Directory.CreateDirectory(studyFolder);

            await Task.Run(() =>
            {
                foreach (var dirDir in dirs)
                {
                    var targetDir = Path.Combine(studyFolder, dirDir.Name);
                    CopyDirectoryRecursive(dirDir.FullName, targetDir);
                }

                if (isSinglePatient && pacsDicomdirPath != null)
                {
                    File.Copy(pacsDicomdirPath,
                        Path.Combine(studyFolder, "DICOMDIR"), overwrite: true);
                }
            });

            var fileArgs = await BuildFileArgsAsync(studyFolder, studyUid, meta);

            results.Add(new ImportedStudyInfo
            {
                StudyInstanceUid = studyUid,
                StudyFolder = studyFolder,
                FileArgs = fileArgs
            });

            Log($"Imported: {meta.PatientName} -- {fileArgs.Count} images");
        }

        return results;
    }

    // ====================================================================
    // Flat folder import — no DIR* structure, scan all DICOM files
    // ====================================================================
    private async Task<List<ImportedStudyInfo>> ImportFlatFolderAsync(
        string folderPath, string incomingFolder)
    {
        Log("Scanning for DICOM files...");

        // Find all DICOM files (*.dcm + extensionless with DICM magic)
        var allDcmFiles = await Task.Run(() =>
        {
            var files = new List<FileInfo>();
            var dirInfo = new DirectoryInfo(folderPath);

            // .dcm files (case-insensitive on NTFS)
            files.AddRange(dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories));

            // Extensionless files with DICM preamble
            foreach (var file in dirInfo.EnumerateFiles("*", SearchOption.AllDirectories))
            {
                if (file.Extension == "" && file.Length > 132)
                {
                    try
                    {
                        var buf = new byte[132];
                        using var fs = file.OpenRead();
                        if (fs.Read(buf, 0, 132) == 132 &&
                            buf[128] == 'D' && buf[129] == 'I' && buf[130] == 'C' && buf[131] == 'M')
                        {
                            files.Add(file);
                        }
                    }
                    catch { }
                }
            }

            return files;
        });

        if (allDcmFiles.Count == 0)
            throw new InvalidOperationException("No DICOM files found in folder");

        Log($"Found {allDcmFiles.Count} DICOM files");

        // Group by StudyInstanceUID
        var studyFiles = new Dictionary<string, List<FileInfo>>();
        var studyMetadata = new Dictionary<string, (string PatientName, string PatientId,
            string StudyDate, string Modality)>();

        await Task.Run(() =>
        {
            foreach (var file in allDcmFiles)
            {
                try
                {
                    var dcm = DicomFile.Open(file.FullName, FileReadOption.SkipLargeTags);
                    var ds = dcm.Dataset;
                    var studyUid = ds.GetSingleValueOrDefault(DicomTag.StudyInstanceUID, "");
                    if (string.IsNullOrEmpty(studyUid)) continue;

                    if (!studyFiles.ContainsKey(studyUid))
                    {
                        studyFiles[studyUid] = new List<FileInfo>();
                        studyMetadata[studyUid] = (
                            ds.GetSingleValueOrDefault(DicomTag.PatientName, "Unknown"),
                            ds.GetSingleValueOrDefault(DicomTag.PatientID, ""),
                            ds.GetSingleValueOrDefault(DicomTag.StudyDate, ""),
                            ds.GetSingleValueOrDefault(DicomTag.Modality, "OT")
                        );
                    }
                    studyFiles[studyUid].Add(file);
                }
                catch { }
            }
        });

        if (studyFiles.Count == 0)
            throw new InvalidOperationException("No valid DICOM studies found");

        Log($"Found {studyFiles.Count} study(ies)");

        var results = new List<ImportedStudyInfo>();

        foreach (var (studyUid, files) in studyFiles)
        {
            var meta = studyMetadata[studyUid];
            var studyFolder = Path.Combine(incomingFolder, studyUid);

            if (Directory.Exists(studyFolder))
            {
                Log($"Study already exists, skipping: {meta.PatientName}");
                continue;
            }

            Directory.CreateDirectory(studyFolder);

            // Group files by SeriesInstanceUID for organized copy
            await Task.Run(() =>
            {
                var seriesGroups = new Dictionary<string, List<FileInfo>>();
                foreach (var file in files)
                {
                    try
                    {
                        var dcm = DicomFile.Open(file.FullName, FileReadOption.SkipLargeTags);
                        var seriesUid = dcm.Dataset.GetSingleValueOrDefault(
                            DicomTag.SeriesInstanceUID, "UNKNOWN");
                        if (!seriesGroups.ContainsKey(seriesUid))
                            seriesGroups[seriesUid] = new List<FileInfo>();
                        seriesGroups[seriesUid].Add(file);
                    }
                    catch
                    {
                        // Put unreadable files in UNKNOWN series
                        if (!seriesGroups.ContainsKey("UNKNOWN"))
                            seriesGroups["UNKNOWN"] = new List<FileInfo>();
                        seriesGroups["UNKNOWN"].Add(file);
                    }
                }

                // Copy preserving series as subdirectories (SeriesUID as folder name)
                foreach (var (seriesUid, seriesFiles) in seriesGroups)
                {
                    var seriesDir = Path.Combine(studyFolder, seriesUid);
                    Directory.CreateDirectory(seriesDir);
                    foreach (var file in seriesFiles)
                    {
                        var destPath = Path.Combine(seriesDir, file.Name);
                        // Avoid collision for same-named files
                        if (File.Exists(destPath))
                            destPath = Path.Combine(seriesDir,
                                $"{Path.GetFileNameWithoutExtension(file.Name)}_{Guid.NewGuid():N}{file.Extension}");
                        File.Copy(file.FullName, destPath);
                    }
                }
            });

            var fileArgs = await BuildFileArgsAsync(studyFolder, studyUid, meta);

            results.Add(new ImportedStudyInfo
            {
                StudyInstanceUid = studyUid,
                StudyFolder = studyFolder,
                FileArgs = fileArgs
            });

            Log($"Imported: {meta.PatientName} -- {fileArgs.Count} images");
        }

        return results;
    }

    // ====================================================================
    // Build FileReceivedEventArgs from study folder (same as ImportZipToQueueAsync)
    // ====================================================================
    private static async Task<List<FileReceivedEventArgs>> BuildFileArgsAsync(
        string studyFolder, string studyUid,
        (string PatientName, string PatientId, string StudyDate, string Modality) meta)
    {
        return await Task.Run(() =>
        {
            var studyDirInfo = new DirectoryInfo(studyFolder);
            var allDcmFiles = studyDirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).ToList();

            var args = new List<FileReceivedEventArgs>(allDcmFiles.Count);
            var processedSeriesDirs = new HashSet<string>();
            var seriesMetaCache = new Dictionary<string, (string uid, string mod, string desc)>();

            foreach (var dcmFile in allDcmFiles)
            {
                var parentDir = dcmFile.Directory?.FullName ?? "";
                string seriesUid = dcmFile.Directory?.Name ?? "UNKNOWN";
                string modality = meta.Modality;
                string seriesDesc = "";

                if (seriesMetaCache.TryGetValue(parentDir, out var cached))
                {
                    seriesUid = cached.uid;
                    modality = cached.mod;
                    seriesDesc = cached.desc;
                }
                else if (!processedSeriesDirs.Contains(parentDir))
                {
                    processedSeriesDirs.Add(parentDir);
                    try
                    {
                        var dcm = DicomFile.Open(dcmFile.FullName, FileReadOption.SkipLargeTags);
                        seriesUid = dcm.Dataset.GetSingleValueOrDefault(
                            DicomTag.SeriesInstanceUID, seriesUid);
                        modality = dcm.Dataset.GetSingleValueOrDefault(
                            DicomTag.Modality, modality);
                        seriesDesc = dcm.Dataset.GetSingleValueOrDefault(
                            DicomTag.SeriesDescription, "");
                    }
                    catch { }
                    seriesMetaCache[parentDir] = (seriesUid, modality, seriesDesc);
                }

                args.Add(new FileReceivedEventArgs
                {
                    StudyInstanceUid = studyUid,
                    PatientName = meta.PatientName,
                    PatientId = meta.PatientId,
                    StudyDate = meta.StudyDate,
                    Modality = modality,
                    SeriesInstanceUid = seriesUid,
                    SeriesDescription = seriesDesc,
                    FilePath = dcmFile.FullName,
                    FileSize = dcmFile.Length
                });
            }

            return args;
        });
    }

    // ====================================================================
    // Helper: recursive directory copy
    // ====================================================================
    private static void CopyDirectoryRecursive(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.GetFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        foreach (var dir in Directory.GetDirectories(source))
            CopyDirectoryRecursive(dir, Path.Combine(destination, Path.GetFileName(dir)));
    }
}
