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
    /// DataGrid row selection for multi-study burn (Click/Ctrl+Click/Shift+Click).
    /// Synced by SelectionChanged handler in code-behind.
    /// Only Complete studies count for burn — others are ignored in selection info.
    /// Cleared by RequestClearSelection event after burn starts.
    /// </summary>
    [ObservableProperty]
    private bool _isSelected;

    /// <summary>
    /// Per-study privacy mode: None (default), Anonymize, or HideAll.
    /// Toggle buttons in each DataGrid row — mutually exclusive.
    /// Applied at burn time (after RestructureInPlace, before DICOMDIR generation).
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsAnonymizeActive))]
    [NotifyPropertyChangedFor(nameof(IsHideAllActive))]
    private DicomPrivacyMode _privacyMode = DicomPrivacyMode.None;

    public bool IsAnonymizeActive => PrivacyMode == DicomPrivacyMode.Anonymize;
    public bool IsHideAllActive => PrivacyMode == DicomPrivacyMode.HideAll;

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
