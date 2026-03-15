using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Windows;
using System.Windows.Controls;
using DicomReceiver.Helpers;
using DicomReceiver.Models;

namespace DicomReceiver.Views;

public partial class SettingsDialog : Window
{
    public AppSettings Settings { get; private set; }

    // Drive cache with 10s TTL — prevents repeated slow COM instantiation (200-500ms per call)
    private static List<(string id, string label)>? _cachedDrives;
    private static DateTime _lastDriveScan = DateTime.MinValue;
    private static readonly TimeSpan DriveCacheTtl = TimeSpan.FromSeconds(10);

    private static string L(string key) => LocalizationHelper.Get(key);

    public SettingsDialog(AppSettings settings)
    {
        InitializeComponent();
        Settings = new AppSettings
        {
            AeTitle = settings.AeTitle,
            Port = settings.Port,
            IncomingFolder = settings.IncomingFolder,
            StudyTimeoutSeconds = settings.StudyTimeoutSeconds,
            BurnSpeed = settings.BurnSpeed,
            Language = settings.Language,
            AutoDeleteAfterBurn = settings.AutoDeleteAfterBurn,
            MaxStudiesKeep = settings.MaxStudiesKeep,
            SelectedDriveId = settings.SelectedDriveId,
            // PACS Browser
            PacsNetworks = settings.PacsNetworks.Select(n => new PacsNetwork
            {
                Name = n.Name, Url = n.Url, Username = n.Username, EncryptedPassword = n.EncryptedPassword
            }).ToList(),
            LastPacsNetworkIndex = settings.LastPacsNetworkIndex,
            SimulateOnly = settings.SimulateOnly,
            IncludeTutorial = settings.IncludeTutorial,
            AutoLogin = settings.AutoLogin,
            AutoUnlock = settings.AutoUnlock,
            AutoExcludeViewer = settings.AutoExcludeViewer
        };

        ApplyLocalization();
        RefreshDrives();

        // Populate fields
        TxtAeTitle.Text = Settings.AeTitle;
        TxtPort.Text = Settings.Port.ToString();
        TxtIncomingFolder.Text = Settings.IncomingFolder;
        TxtTimeout.Text = Settings.StudyTimeoutSeconds.ToString();

        // Select burn speed
        foreach (ComboBoxItem item in CmbBurnSpeed.Items)
        {
            if (item.Tag?.ToString() == Settings.BurnSpeed.ToString())
            {
                CmbBurnSpeed.SelectedItem = item;
                break;
            }
        }
        if (CmbBurnSpeed.SelectedItem == null)
            CmbBurnSpeed.SelectedIndex = 1; // 4x default

        // Select language
        foreach (ComboBoxItem item in CmbLanguage.Items)
        {
            if (item.Tag?.ToString() == Settings.Language)
            {
                CmbLanguage.SelectedItem = item;
                break;
            }
        }
        if (CmbLanguage.SelectedItem == null)
            CmbLanguage.SelectedIndex = 0; // auto

        // Auto-delete + Max studies (mutually exclusive)
        ChkAutoDelete.IsChecked = Settings.AutoDeleteAfterBurn;
        TxtMaxStudies.Text = Settings.MaxStudiesKeep.ToString();
        UpdateMaxStudiesEnabled();

        // PACS Browser checkboxes
        ChkAutoLogin.IsChecked = Settings.AutoLogin;
        ChkAutoUnlock.IsChecked = Settings.AutoUnlock;
        ChkAutoExcludeViewer.IsChecked = Settings.AutoExcludeViewer;
        ChkSimulateOnly.IsChecked = Settings.SimulateOnly;
        ChkIncludeTutorial.IsChecked = Settings.IncludeTutorial;
    }

    private void ApplyLocalization()
    {
        SettingsWindow.Title = L("SettingsTitle");
        LblAeTitle.Text = L("AeTitle") + ":";
        LblPort.Text = L("Port") + ":";
        LblIncomingFolder.Text = L("IncomingFolder") + ":";
        LblTimeout.Text = L("Timeout") + ":";
        LblBurnSpeed.Text = L("BurnSpeed") + ":";
        LblLanguage.Text = L("Language") + ":";
        LblAutoDelete.Text = L("AutoDeleteAfterBurn") + ":";
        ChkAutoDelete.Content = L("AutoDeleteCheckbox");
        LblMaxStudies.Text = L("MaxStudiesKeep") + ":";
        LblMaxStudiesHint.Text = "  " + L("MaxStudiesHint");
        LblDriveWriter.Text = L("DriveWriter") + ":";
        BtnRefreshDrives.Content = "\u21BB";
        BtnSave.Content = L("Save");
        BtnCancel.Content = L("Cancel");
        BtnRestartService.Content = L("RestartService");
        UpdateServiceButtonState();

        // PACS Browser
        LblPacsSection.Text = L("PacsSectionTitle");
        LblAutoLogin.Text = L("AutoLogin") + ":";
        LblAutoUnlock.Text = L("AutoUnlock") + ":";
        LblAutoExcludeViewer.Text = L("AutoExcludeViewer") + ":";
        LblSimulateOnly.Text = L("SimulateOnly") + ":";
        ChkSimulateOnly.Content = L("SimulateOnlyCheckbox");
        LblIncludeTutorial.Text = L("IncludeTutorial") + ":";
        ChkIncludeTutorial.Content = L("IncludeTutorialCheckbox");
        LblEditNetworks.Text = L("PacsNetwork") + ":";
        BtnEditNetworks.Content = L("EditNetworks");
    }

    private void RefreshDrives(bool forceRefresh = false)
    {
        CmbDriveWriter.Items.Clear();

        // Use cached drives if available and fresh
        if (!forceRefresh && _cachedDrives != null && (DateTime.UtcNow - _lastDriveScan) < DriveCacheTtl)
        {
            PopulateDriveCombo(_cachedDrives);
            return;
        }

        var drives = new List<(string id, string label)>();

        try
        {
            var discMasterType = Type.GetTypeFromProgID("IMAPI2.MsftDiscMaster2");
            if (discMasterType == null) goto done;

            var discMaster = Activator.CreateInstance(discMasterType);
            if (discMaster == null) goto done;

            try
            {
                dynamic master = discMaster;
                int count = master.Count;

                for (int i = 0; i < count; i++)
                {
                    string uniqueId = master[i];
                    var recorderType = Type.GetTypeFromProgID("IMAPI2.MsftDiscRecorder2");
                    if (recorderType == null) continue;

                    var recorderObj = Activator.CreateInstance(recorderType);
                    if (recorderObj == null) continue;

                    try
                    {
                        dynamic recorder = recorderObj;
                        recorder.InitializeDiscRecorder(uniqueId);

                        string vendor = (recorder.VendorId ?? "").ToString().Trim();
                        string product = (recorder.ProductId ?? "").ToString().Trim();

                        // Get volume path (drive letter)
                        string driveLetter = "";
                        try
                        {
                            object? paths = recorder.VolumePathNames;
                            if (paths is string[] volPaths && volPaths.Length > 0)
                                driveLetter = volPaths[0].TrimEnd('\\');
                        }
                        catch { /* no volume path */ }

                        string label = string.IsNullOrEmpty(driveLetter)
                            ? $"{vendor} {product}".Trim()
                            : $"{driveLetter} — {vendor} {product}".Trim();

                        if (!string.IsNullOrEmpty(label))
                            drives.Add((uniqueId, label));
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(recorderObj);
                    }
                }
            }
            finally
            {
                Marshal.ReleaseComObject(discMaster);
            }
        }
        catch
        {
            // IMAPI2 not available
        }

        done:
        _cachedDrives = drives;
        _lastDriveScan = DateTime.UtcNow;
        PopulateDriveCombo(drives);
    }

    private void PopulateDriveCombo(List<(string id, string label)> drives)
    {
        if (drives.Count == 0)
        {
            // No drives found
            CmbDriveWriter.Items.Add(new ComboBoxItem
            {
                Content = L("NoDrives"),
                Tag = "",
                IsEnabled = false
            });
            CmbDriveWriter.SelectedIndex = 0;
            CmbDriveWriter.IsEnabled = false;
        }
        else
        {
            foreach (var (id, label) in drives)
            {
                CmbDriveWriter.Items.Add(new ComboBoxItem { Content = label, Tag = id });
            }

            // Select saved drive or first one
            bool found = false;
            if (!string.IsNullOrEmpty(Settings.SelectedDriveId))
            {
                for (int i = 0; i < CmbDriveWriter.Items.Count; i++)
                {
                    if (CmbDriveWriter.Items[i] is ComboBoxItem item &&
                        item.Tag?.ToString() == Settings.SelectedDriveId)
                    {
                        CmbDriveWriter.SelectedIndex = i;
                        found = true;
                        break;
                    }
                }
            }
            if (!found)
                CmbDriveWriter.SelectedIndex = 0;

            // 1 drive → disabled (auto-selected, can't change)
            // 2+ drives → enabled
            CmbDriveWriter.IsEnabled = drives.Count > 1;
        }
    }

    private void RefreshDrives_Click(object sender, RoutedEventArgs e)
    {
        RefreshDrives(forceRefresh: true);
    }

    private void BrowseFolder_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = L("IncomingFolder"),
            SelectedPath = TxtIncomingFolder.Text
        };

        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            TxtIncomingFolder.Text = dialog.SelectedPath;
        }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        Settings.AeTitle = TxtAeTitle.Text.Trim();
        if (string.IsNullOrEmpty(Settings.AeTitle))
        {
            MessageBox.Show("AE Title cannot be empty", "Validation", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (!int.TryParse(TxtPort.Text, out var port) || port < 1 || port > 65535)
        {
            MessageBox.Show("Port must be between 1 and 65535", "Validation", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        Settings.Port = port;

        Settings.IncomingFolder = TxtIncomingFolder.Text.Trim();

        if (!int.TryParse(TxtTimeout.Text, out var timeout) || timeout < 5 || timeout > 300)
        {
            MessageBox.Show("Timeout must be between 5 and 300 seconds", "Validation", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        Settings.StudyTimeoutSeconds = timeout;

        if (CmbBurnSpeed.SelectedItem is ComboBoxItem speedItem)
            Settings.BurnSpeed = int.Parse(speedItem.Tag.ToString()!);

        if (CmbLanguage.SelectedItem is ComboBoxItem langItem)
            Settings.Language = langItem.Tag.ToString()!;

        if (CmbDriveWriter.SelectedItem is ComboBoxItem driveItem)
            Settings.SelectedDriveId = driveItem.Tag?.ToString() ?? "";

        Settings.AutoDeleteAfterBurn = ChkAutoDelete.IsChecked == true;

        // PACS Browser
        Settings.AutoLogin = ChkAutoLogin.IsChecked == true;
        Settings.AutoUnlock = ChkAutoUnlock.IsChecked == true;
        Settings.AutoExcludeViewer = ChkAutoExcludeViewer.IsChecked == true;
        Settings.SimulateOnly = ChkSimulateOnly.IsChecked == true;
        Settings.IncludeTutorial = ChkIncludeTutorial.IsChecked == true;

        // MaxStudiesKeep only relevant when AutoDelete is OFF
        if (!Settings.AutoDeleteAfterBurn)
        {
            if (!int.TryParse(TxtMaxStudies.Text, out var maxStudies) || maxStudies < 0)
            {
                MessageBox.Show("Max studies must be 0 or greater (0 = unlimited)", "Validation", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Settings.MaxStudiesKeep = maxStudies;
        }
        else
        {
            Settings.MaxStudiesKeep = 0; // Reset — not used when AutoDelete is ON
        }

        DialogResult = true;
        Close();
    }

    private void ChkAutoDelete_Changed(object sender, RoutedEventArgs e)
    {
        UpdateMaxStudiesEnabled();
    }

    /// <summary>
    /// AutoDelete ON → MaxStudies disabled (irrelevant — studies deleted immediately after burn).
    /// AutoDelete OFF → MaxStudies enabled (controls when old studies get purged).
    /// </summary>
    private void UpdateMaxStudiesEnabled()
    {
        var enabled = ChkAutoDelete.IsChecked != true;
        TxtMaxStudies.IsEnabled = enabled;
        LblMaxStudies.Opacity = enabled ? 1.0 : 0.4;
        LblMaxStudiesHint.Opacity = enabled ? 1.0 : 0.4;
    }

    private void UpdateServiceButtonState()
    {
        try
        {
            using var sc = new ServiceController("DicomReceiverService");
            // Service exists — enable button
            BtnRestartService.IsEnabled = true;
            BtnRestartService.Opacity = 1.0;
        }
        catch
        {
            // Service not installed — disable button
            BtnRestartService.IsEnabled = false;
            BtnRestartService.Opacity = 0.4;
        }
    }

    private void RestartService_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            using var sc = new ServiceController("DicomReceiverService");

            if (sc.Status == ServiceControllerStatus.Running)
            {
                sc.Stop();
                sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(10));
            }

            sc.Start();
            sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(10));

            MessageBox.Show(L("ServiceRestarted"), L("RestartService"),
                MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (InvalidOperationException ex)
        {
            // InvalidOperationException can mean: service not installed OR service failed to start
            var inner = ex.InnerException?.Message ?? ex.Message;
            // Check if service actually exists — "Cannot open" means not installed
            bool notInstalled = inner.Contains("Cannot open", StringComparison.OrdinalIgnoreCase)
                || inner.Contains("was not found", StringComparison.OrdinalIgnoreCase);
            var msg = notInstalled ? L("ServiceNotInstalled") : $"{L("ServiceRestartFailed")}\n\n{inner}";
            MessageBox.Show(msg, L("RestartService"),
                MessageBoxButton.OK, notInstalled ? MessageBoxImage.Information : MessageBoxImage.Warning);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"{L("ServiceRestartFailed")}\n\n{ex.Message}", L("RestartService"),
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void EditNetworks_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new PacsNetworkDialog(Settings.PacsNetworks) { Owner = this };
        if (dialog.ShowDialog() == true)
        {
            Settings.PacsNetworks = dialog.Networks;
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
