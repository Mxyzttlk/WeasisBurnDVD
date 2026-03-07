using System;
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace DicomReceiver.Models;

public enum StudyStatus
{
    Receiving,
    Complete,
    Burning,
    Done,
    Error
}

public partial class ReceivedStudy : ObservableObject
{
    [ObservableProperty]
    private string _studyInstanceUid = "";

    [ObservableProperty]
    private string _patientName = "";

    [ObservableProperty]
    private string _patientId = "";

    [ObservableProperty]
    private string _studyDate = "";

    [ObservableProperty]
    private string _modality = "";

    [ObservableProperty]
    private int _seriesCount;

    [ObservableProperty]
    private int _imageCount;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(TotalSizeFormatted))]
    private long _totalSizeBytes;

    [ObservableProperty]
    private StudyStatus _status = StudyStatus.Receiving;

    [ObservableProperty]
    private string _statusText = "";

    [ObservableProperty]
    private DateTime _lastFileReceivedTime = DateTime.Now;

    [ObservableProperty]
    private string _storagePath = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ExpandButtonText))]
    private bool _isExpanded;

    /// <summary>
    /// Collection of series within this study — populated by StudyMonitorService.
    /// Used for expandable row details in DataGrid.
    /// </summary>
    public ObservableCollection<ReceivedSeries> Series { get; } = new();

    /// <summary>
    /// Flag set by StudyMonitorService after dedup HashSets are cleaned for Done/Error studies.
    /// Prevents repeated TryRemove on subsequent DispatcherTimer ticks.
    /// Reset to false if study returns to Receiving (re-send scenario).
    /// </summary>
    public bool TrackingCleaned { get; set; }

    public string ExpandButtonText => IsExpanded ? "−" : "+";

    public string TotalSizeFormatted
    {
        get
        {
            if (TotalSizeBytes < 1024) return $"{TotalSizeBytes} B";
            if (TotalSizeBytes < 1024 * 1024) return $"{TotalSizeBytes / 1024.0:F1} KB";
            if (TotalSizeBytes < 1024 * 1024 * 1024) return $"{TotalSizeBytes / (1024.0 * 1024.0):F1} MB";
            return $"{TotalSizeBytes / (1024.0 * 1024.0 * 1024.0):F2} GB";
        }
    }
}
