using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DicomReceiver.Models;

namespace DicomReceiver.Services;

public class StudyCompletedEventArgs : EventArgs
{
    public required ReceivedStudy Study { get; init; }
}

public class StudyUpdatedEventArgs : EventArgs
{
    public required ReceivedStudy Study { get; init; }
}

public class StudyMonitorService : IDisposable
{
    private readonly ConcurrentDictionary<string, ReceivedStudy> _studies = new();
    private readonly ConcurrentDictionary<string, HashSet<string>> _imagesPerStudy = new();
    // Per-series image tracking: key = "{studyUID}\t{seriesUID}" — dedup SOPInstanceUID per series
    private readonly ConcurrentDictionary<string, HashSet<string>> _imagesPerSeries = new();
    private int _timeoutSeconds = 30;

    public event EventHandler<StudyCompletedEventArgs>? StudyCompleted;
    public event EventHandler<StudyUpdatedEventArgs>? StudyUpdated;

    public IEnumerable<ReceivedStudy> Studies => _studies.Values;

    public void Start(int timeoutSeconds)
    {
        _timeoutSeconds = timeoutSeconds;
        // No separate timer — CheckAndCompleteStudies() is called from UI DispatcherTimer
    }

    public void Stop()
    {
        // Nothing to dispose — no separate timer
    }

    public void OnFileReceived(FileReceivedEventArgs args)
    {
        var study = _studies.GetOrAdd(args.StudyInstanceUid, _ => new ReceivedStudy
        {
            StudyInstanceUid = args.StudyInstanceUid,
            PatientName = FormatPatientName(args.PatientName),
            PatientId = args.PatientId,
            StudyDate = FormatStudyDate(args.StudyDate),
            Modality = args.Modality,
            Status = StudyStatus.Receiving,
            StoragePath = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(args.FilePath))
                ?? Path.GetDirectoryName(args.FilePath) ?? args.FilePath)
        });

        // If study was already Complete, reset to Receiving (new series arriving later)
        // Do NOT clear _imagesPerStudy HashSet — old SOPUIDs must be kept for dedup.
        // RecalculateStudySize() corrects counts from disk when study completes again.
        if (study.Status == StudyStatus.Complete)
        {
            study.Status = StudyStatus.Receiving;
            study.TrackingCleaned = false; // Re-enable tracking cleanup for next completion
        }

        // Update last file time
        study.LastFileReceivedTime = DateTime.Now;

        // Extract SOPInstanceUID from filename (filename = SOPUID.dcm)
        var sopUid = Path.GetFileNameWithoutExtension(args.FilePath);

        // Track unique images at study level — deduplicate on SOPInstanceUID
        var images = _imagesPerStudy.GetOrAdd(args.StudyInstanceUid, _ => new HashSet<string>());
        bool isNewImage;
        lock (images)
        {
            isNewImage = images.Add(sopUid);
            study.ImageCount = images.Count;
        }

        // Only add size for new images; for duplicates, file is overwritten (same size)
        if (isNewImage)
            study.TotalSizeBytes += args.FileSize;

        // Track/update ReceivedSeries in study.Series collection
        var seriesObj = study.Series.FirstOrDefault(s => s.SeriesInstanceUid == args.SeriesInstanceUid);
        if (seriesObj == null)
        {
            seriesObj = new ReceivedSeries
            {
                SeriesInstanceUid = args.SeriesInstanceUid,
                SeriesDescription = args.SeriesDescription,
                Modality = args.Modality,
                StoragePath = Path.GetDirectoryName(args.FilePath) ?? ""
            };
            study.Series.Add(seriesObj);
        }
        else if (string.IsNullOrEmpty(seriesObj.SeriesDescription) && !string.IsNullOrEmpty(args.SeriesDescription))
        {
            // Update description if first file didn't have it but subsequent file does
            seriesObj.SeriesDescription = args.SeriesDescription;
        }
        study.SeriesCount = study.Series.Count;

        // Track unique images at series level
        var seriesKey = $"{args.StudyInstanceUid}\t{args.SeriesInstanceUid}";
        var seriesImages = _imagesPerSeries.GetOrAdd(seriesKey, _ => new HashSet<string>());
        bool isNewSeriesImage;
        lock (seriesImages)
        {
            isNewSeriesImage = seriesImages.Add(sopUid);
            seriesObj.ImageCount = seriesImages.Count;
        }

        if (isNewSeriesImage)
            seriesObj.TotalSizeBytes += args.FileSize;

        // Update modality if we get a more specific one
        if (args.Modality != "OT" && study.Modality == "OT")
            study.Modality = args.Modality;

        // Accumulate modalities if mixed study
        if (args.Modality != study.Modality && !study.Modality.Contains(args.Modality))
            study.Modality = $"{study.Modality}/{args.Modality}";

        study.StatusText = $"⬆ {study.ImageCount} img ({study.SeriesCount} ser)";

        StudyUpdated?.Invoke(this, new StudyUpdatedEventArgs { Study = study });
    }

    /// <summary>
    /// Checks all Receiving studies for completion (timeout elapsed).
    /// Also cleans up tracking data for finished studies (Done/Error) to prevent memory accumulation.
    /// MUST be called from UI thread (DispatcherTimer) — avoids cross-thread race conditions.
    /// </summary>
    /// <summary>
    /// Force a study to Complete status immediately (skip timeout).
    /// Used after PACS ZIP import where all files arrive at once.
    /// </summary>
    public void ForceCompleteStudy(string studyInstanceUid)
    {
        if (_studies.TryGetValue(studyInstanceUid, out var study) && study.Status == StudyStatus.Receiving)
        {
            study.Status = StudyStatus.Complete;
            RecalculateStudySize(study);
            StudyCompleted?.Invoke(this, new StudyCompletedEventArgs { Study = study });
        }
    }

    public void CheckAndCompleteStudies()
    {
        var now = DateTime.Now;

        foreach (var kvp in _studies)
        {
            var study = kvp.Value;

            // Check for completion
            if (study.Status == StudyStatus.Receiving)
            {
                var elapsed = (now - study.LastFileReceivedTime).TotalSeconds;
                if (elapsed >= _timeoutSeconds)
                {
                    study.Status = StudyStatus.Complete;

                    // Recalculate size from disk (more accurate) — single enumeration
                    RecalculateStudySize(study);

                    StudyCompleted?.Invoke(this, new StudyCompletedEventArgs { Study = study });
                }
            }

            // Cleanup tracking HashSets for finished studies (free memory)
            // Study.Series collection STAYS (needed for UI display of expandable rows)
            // Only dedup HashSets are released — 100 patients × 500 SOP UIDs = ~2.5 MB saved
            // TrackingCleaned flag prevents repeated TryRemove on subsequent ticks
            if ((study.Status == StudyStatus.Done || study.Status == StudyStatus.Error)
                && !study.TrackingCleaned)
            {
                _imagesPerStudy.TryRemove(kvp.Key, out _);

                // Clean per-series tracking
                foreach (var series in study.Series)
                {
                    var seriesKey = $"{kvp.Key}\t{series.SeriesInstanceUid}";
                    _imagesPerSeries.TryRemove(seriesKey, out _);
                }

                study.TrackingCleaned = true;
            }
        }
    }

    /// <summary>
    /// Updates StatusText for active studies (Receiving/Complete) with elapsed time.
    /// Skips Done/Burned/Error studies — no work needed, prevents unnecessary iteration.
    /// MUST be called from UI thread (DispatcherTimer) every 1 second.
    /// </summary>
    public void UpdateElapsedTimes()
    {
        var now = DateTime.Now;

        foreach (var kvp in _studies)
        {
            var study = kvp.Value;

            // Skip finished studies — their StatusText is final, nothing to update
            if (study.Status == StudyStatus.Done ||
                study.Status == StudyStatus.Error ||
                study.Status == StudyStatus.Burning)
                continue;

            switch (study.Status)
            {
                case StudyStatus.Receiving:
                {
                    var elapsed = now - study.LastFileReceivedTime;
                    if (elapsed.TotalSeconds < 3)
                    {
                        // Actively receiving
                        study.StatusText = $"⬆ {study.ImageCount} img ({study.SeriesCount} ser)";
                    }
                    else
                    {
                        // Idle — waiting for more files
                        study.StatusText = $"⬆ {study.ImageCount} img — idle {FormatElapsed(elapsed)}";
                    }
                    break;
                }
                case StudyStatus.Complete:
                {
                    var elapsed = now - study.LastFileReceivedTime;
                    if (elapsed.TotalMinutes < 2)
                    {
                        study.StatusText = $"✓ {study.ImageCount} img — {FormatElapsed(elapsed)}";
                    }
                    else if (study.StatusText != "✓ Complete")
                    {
                        // Set once, then skip — no unnecessary string allocations
                        study.StatusText = "✓ Complete";
                    }
                    break;
                }
            }
        }
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed.TotalSeconds < 60)
            return $"{(int)elapsed.TotalSeconds}s";
        if (elapsed.TotalMinutes < 60)
            return $"{(int)elapsed.TotalMinutes}m{elapsed.Seconds:D2}s";
        return $"{(int)elapsed.TotalHours}h{elapsed.Minutes:D2}m";
    }

    private void RecalculateStudySize(ReceivedStudy study)
    {
        try
        {
            if (Directory.Exists(study.StoragePath))
            {
                var dirInfo = new DirectoryInfo(study.StoragePath);
                // Single enumeration — was two separate enumerations before (Sum + Count)
                var files = dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).ToList();
                study.TotalSizeBytes = files.Sum(f => f.Length);
                study.ImageCount = files.Count;
            }
        }
        catch
        {
            // Keep the accumulated values
        }
    }

    /// <summary>
    /// Validates that a study has actual DICOM files on disk before burning.
    /// Returns (fileCount, totalSize) or (0, 0) if no files found.
    /// Prevents the eFilm bug where burn ran with empty/missing DICOM data.
    /// </summary>
    public (int fileCount, long totalSize) ValidateStudyOnDisk(ReceivedStudy study)
    {
        try
        {
            if (!Directory.Exists(study.StoragePath))
                return (0, 0);

            var dirInfo = new DirectoryInfo(study.StoragePath);
            var files = dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).ToList();
            return (files.Count, files.Sum(f => f.Length));
        }
        catch
        {
            return (0, 0);
        }
    }

    public void RemoveStudy(string studyInstanceUid)
    {
        if (_studies.TryRemove(studyInstanceUid, out var study))
        {
            // Clean per-series tracking
            foreach (var series in study.Series)
            {
                var seriesKey = $"{studyInstanceUid}\t{series.SeriesInstanceUid}";
                _imagesPerSeries.TryRemove(seriesKey, out _);
            }
        }
        _imagesPerStudy.TryRemove(studyInstanceUid, out _);
    }

    /// <summary>
    /// Removes a single series from tracking and recalculates study totals.
    /// Called when user deletes a specific series from the expandable row.
    /// </summary>
    public void RemoveSeries(ReceivedStudy study, ReceivedSeries series)
    {
        // Remove per-series tracking
        var seriesKey = $"{study.StudyInstanceUid}\t{series.SeriesInstanceUid}";
        _imagesPerSeries.TryRemove(seriesKey, out _);

        // Remove from study's series collection
        study.Series.Remove(series);

        // Recalculate study totals from remaining series
        RecalculateStudyFromSeries(study);
    }

    /// <summary>
    /// Recalculates SeriesCount, ImageCount, and TotalSizeBytes from the study's Series collection.
    /// Used after series deletion to keep totals accurate.
    /// </summary>
    public void RecalculateStudyFromSeries(ReceivedStudy study)
    {
        study.SeriesCount = study.Series.Count;
        study.ImageCount = study.Series.Sum(s => s.ImageCount);
        study.TotalSizeBytes = study.Series.Sum(s => s.TotalSizeBytes);

        // Rebuild study-level image tracking from remaining series
        if (_imagesPerStudy.TryGetValue(study.StudyInstanceUid, out var studyImages))
        {
            lock (studyImages)
            {
                studyImages.Clear();
                foreach (var s in study.Series)
                {
                    var sKey = $"{study.StudyInstanceUid}\t{s.SeriesInstanceUid}";
                    if (_imagesPerSeries.TryGetValue(sKey, out var seriesImages))
                    {
                        lock (seriesImages)
                        {
                            foreach (var uid in seriesImages)
                                studyImages.Add(uid);
                        }
                    }
                }
            }
        }
    }

    private static string FormatPatientName(string rawName)
    {
        // DICOM format: LastName^FirstName^MiddleName^Prefix^Suffix → "LastName FirstName"
        return rawName.Replace('^', ' ').Trim();
    }

    private static string FormatStudyDate(string rawDate)
    {
        // DICOM date format: YYYYMMDD → DD.MM.YYYY
        if (rawDate.Length == 8 &&
            int.TryParse(rawDate[..4], out var y) &&
            int.TryParse(rawDate[4..6], out var m) &&
            int.TryParse(rawDate[6..8], out var d))
        {
            return $"{d:D2}.{m:D2}.{y}";
        }
        return rawDate;
    }

    public void Dispose()
    {
        // No resources to dispose — timer management moved to ViewModel's DispatcherTimer
    }
}
