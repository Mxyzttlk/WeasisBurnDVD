using System.Collections.Generic;

namespace DicomReceiver.Models;

public enum DicomPrivacyMode
{
    None,       // No modification — burn original files
    Anonymize,  // Replace patient data with "Anonymous", blank dates
    HideAll     // Remove all demographics/institutional metadata
}

public class AppSettings
{
    // DICOM SCP settings
    public string AeTitle { get; set; } = "WEASIS_BURN";
    public int Port { get; set; } = 4006;
    public string IncomingFolder { get; set; } = "";
    public int StudyTimeoutSeconds { get; set; } = 30;

    // Burn settings
    public int BurnSpeed { get; set; } = 4;
    public string SelectedDriveId { get; set; } = ""; // empty = auto-detect
    public bool SimulateOnly { get; set; } = false;   // burn-gui.ps1 -SimulateOnly flag

    // General settings
    public string Language { get; set; } = "auto";
    public bool AutoDeleteAfterBurn { get; set; } = true;
    public int MaxStudiesKeep { get; set; } = 0; // 0 = unlimited

    // Window size (remembered between sessions)
    public double WindowWidth { get; set; } = 1100;
    public double WindowHeight { get; set; } = 700;

    // PACS Browser settings
    public List<PacsNetwork> PacsNetworks { get; set; } = new()
    {
        new PacsNetwork { Name = "External", Url = "http://imagistica.scr.md/portal/" },
        new PacsNetwork { Name = "Internal", Url = "http://192.168.22.10/portal/" }
    };
    public int LastPacsNetworkIndex { get; set; } = 0;
    public bool AutoLogin { get; set; } = true;
    public bool AutoUnlock { get; set; } = true;
    public bool AutoExcludeViewer { get; set; } = true;
}
