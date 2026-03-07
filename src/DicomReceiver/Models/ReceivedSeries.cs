using CommunityToolkit.Mvvm.ComponentModel;

namespace DicomReceiver.Models;

public partial class ReceivedSeries : ObservableObject
{
    [ObservableProperty]
    private string _seriesInstanceUid = "";

    [ObservableProperty]
    private string _seriesDescription = "";

    [ObservableProperty]
    private string _modality = "";

    [ObservableProperty]
    private int _imageCount;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SizeFormatted))]
    private long _totalSizeBytes;

    [ObservableProperty]
    private string _storagePath = "";

    public string SizeFormatted
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
