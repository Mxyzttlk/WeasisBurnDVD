using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
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
    private readonly ConcurrentDictionary<string, HashSet<string>> _seriesPerStudy = new();
    private Timer? _timer;
    private int _timeoutSeconds = 15;

    public event EventHandler<StudyCompletedEventArgs>? StudyCompleted;
    public event EventHandler<StudyUpdatedEventArgs>? StudyUpdated;

    public IEnumerable<ReceivedStudy> Studies => _studies.Values;

    public void Start(int timeoutSeconds)
    {
        _timeoutSeconds = timeoutSeconds;
        _timer = new Timer(CheckStudyCompletion, null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    public void OnFileReceived(FileReceivedEventArgs args)
    {
        var study = _studies.GetOrAdd(args.StudyInstanceUid, _ => new ReceivedStudy
        {
            StudyInstanceUid = args.StudyInstanceUid,
            PatientName = args.PatientName,
            PatientId = args.PatientId,
            StudyDate = FormatStudyDate(args.StudyDate),
            Modality = args.Modality,
            Status = StudyStatus.Receiving,
            StoragePath = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(args.FilePath))
                ?? Path.GetDirectoryName(args.FilePath) ?? args.FilePath)
        });

        // Update last file time
        study.LastFileReceivedTime = DateTime.Now;
        study.ImageCount++;
        study.TotalSizeBytes += args.FileSize;

        // Track unique series
        var series = _seriesPerStudy.GetOrAdd(args.StudyInstanceUid, _ => new HashSet<string>());
        lock (series)
        {
            series.Add(args.SeriesInstanceUid);
            study.SeriesCount = series.Count;
        }

        // Update modality if we get a more specific one
        if (args.Modality != "OT" && study.Modality == "OT")
            study.Modality = args.Modality;

        // Accumulate modalities if mixed study
        if (args.Modality != study.Modality && !study.Modality.Contains(args.Modality))
            study.Modality = $"{study.Modality}/{args.Modality}";

        study.StatusText = $"Receiving... ({study.ImageCount} images)";

        StudyUpdated?.Invoke(this, new StudyUpdatedEventArgs { Study = study });
    }

    private void CheckStudyCompletion(object? state)
    {
        var now = DateTime.Now;

        foreach (var kvp in _studies)
        {
            var study = kvp.Value;
            if (study.Status != StudyStatus.Receiving) continue;

            var elapsed = (now - study.LastFileReceivedTime).TotalSeconds;
            if (elapsed >= _timeoutSeconds)
            {
                study.Status = StudyStatus.Complete;
                study.StatusText = "Complete";

                // Recalculate size from disk (more accurate)
                RecalculateStudySize(study);

                StudyCompleted?.Invoke(this, new StudyCompletedEventArgs { Study = study });
            }
        }
    }

    private void RecalculateStudySize(ReceivedStudy study)
    {
        try
        {
            if (Directory.Exists(study.StoragePath))
            {
                var dirInfo = new DirectoryInfo(study.StoragePath);
                study.TotalSizeBytes = dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).Sum(f => f.Length);
                study.ImageCount = dirInfo.EnumerateFiles("*.dcm", SearchOption.AllDirectories).Count();
            }
        }
        catch
        {
            // Keep the accumulated values
        }
    }

    public void RemoveStudy(string studyInstanceUid)
    {
        _studies.TryRemove(studyInstanceUid, out _);
        _seriesPerStudy.TryRemove(studyInstanceUid, out _);
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
        _timer?.Dispose();
    }
}
