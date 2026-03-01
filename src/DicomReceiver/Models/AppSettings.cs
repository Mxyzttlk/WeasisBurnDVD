namespace DicomReceiver.Models;

public class AppSettings
{
    public string AeTitle { get; set; } = "WEASIS_BURN";
    public int Port { get; set; } = 4006;
    public string IncomingFolder { get; set; } = "";
    public int StudyTimeoutSeconds { get; set; } = 30;
    public int BurnSpeed { get; set; } = 4;
    public string Language { get; set; } = "auto";
    public bool AutoDeleteAfterBurn { get; set; } = true;
    public int MaxStudiesKeep { get; set; } = 0; // 0 = unlimited
    public string SelectedDriveId { get; set; } = ""; // empty = auto-detect
}
