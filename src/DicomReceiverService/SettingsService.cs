using System;
using System.IO;
using System.Text.Json;

namespace DicomReceiverService;

public class AppSettings
{
    public string AeTitle { get; set; } = "WEASIS_BURN";
    public int Port { get; set; } = 4006;
    public string IncomingFolder { get; set; } = "";
}

public class SettingsService
{
    // ProgramData is accessible by all accounts including LocalSystem
    private static readonly string SettingsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "WeasisBurn");

    private static readonly string SettingsFile = Path.Combine(SettingsDir, "dicom-receiver-settings.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    public AppSettings Load()
    {
        try
        {
            if (File.Exists(SettingsFile))
            {
                var json = File.ReadAllText(SettingsFile);
                var settings = JsonSerializer.Deserialize<AppSettings>(json, JsonOptions);
                if (settings != null)
                {
                    if (string.IsNullOrEmpty(settings.IncomingFolder))
                        settings.IncomingFolder = GetDefaultIncomingFolder();
                    return settings;
                }
            }
        }
        catch
        {
            // Corrupted settings — return defaults
        }

        return new AppSettings
        {
            IncomingFolder = GetDefaultIncomingFolder()
        };
    }

    private static string GetDefaultIncomingFolder()
    {
        // Use the executable's directory for the incoming folder
        var exePath = Environment.ProcessPath;
        var exeDir = exePath != null
            ? Path.GetDirectoryName(exePath) ?? AppDomain.CurrentDomain.BaseDirectory
            : AppDomain.CurrentDomain.BaseDirectory;
        return Path.Combine(exeDir, "incoming");
    }
}
