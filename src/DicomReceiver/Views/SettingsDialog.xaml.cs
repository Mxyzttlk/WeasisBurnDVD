using System.Linq;
using System.Windows;
using System.Windows.Controls;
using DicomReceiver.Models;

namespace DicomReceiver.Views;

public partial class SettingsDialog : Window
{
    public AppSettings Settings { get; private set; }

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
            MaxStudiesKeep = settings.MaxStudiesKeep
        };

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
    }

    private void BrowseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "Select incoming DICOM folder",
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

        Settings.AutoDeleteAfterBurn = ChkAutoDelete.IsChecked == true;

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

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
