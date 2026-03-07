using System;
using System.IO;
using System.Text.Json;
using DicomReceiver.Models;

namespace DicomReceiver.Services;

public class SettingsService
{
    private static readonly string SettingsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
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
                    // Set default incoming folder if empty
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

        var defaults = new AppSettings
        {
            IncomingFolder = GetDefaultIncomingFolder()
        };
        Save(defaults);
        return defaults;
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(SettingsDir);
        var json = JsonSerializer.Serialize(settings, JsonOptions);
        File.WriteAllText(SettingsFile, json);

        // Also write to ProgramData for the Windows Service to read
        try
        {
            Directory.CreateDirectory(SharedSettingsDir);
            File.WriteAllText(SharedSettingsFile, json);
        }
        catch
        {
            // ProgramData write may fail without admin rights — non-critical
        }
    }

    // Shared location accessible by Windows Service (LocalSystem account)
    private static readonly string SharedSettingsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "WeasisBurn");

    private static readonly string SharedSettingsFile = Path.Combine(SharedSettingsDir, "dicom-receiver-settings.json");

    private string GetDefaultIncomingFolder()
    {
        // Default: next to the executable
        var exeDir = AppDomain.CurrentDomain.BaseDirectory;
        return Path.Combine(exeDir, "incoming");
    }
}
