using System;
using System.IO;
using System.Linq;
using System.Windows;
using DicomReceiver.Helpers;
using DicomReceiver.Services;

namespace DicomReceiver.Views;

public partial class ImportDialog : Window
{
    public ImportSource SelectedSource { get; private set; }
    public string SelectedPath { get; private set; } = "";

    public ImportDialog()
    {
        InitializeComponent();
        ApplyLocalization();
        RefreshDrives();
    }

    private void ApplyLocalization()
    {
        Title = L("ImportTitle");
        TxtTitle.Text = L("ImportTitle");
        TxtZipLabel.Text = L("ImportZip");
        TxtFolderLabel.Text = L("ImportFolder");
        TxtDiscLabel.Text = L("ImportDisc");
        BtnImport.Content = L("Import");
        BtnCancel.Content = L("ImportCancel");
    }

    private void RefreshDrives()
    {
        CmbDrives.Items.Clear();
        try
        {
            var cdDrives = DriveInfo.GetDrives()
                .Where(d => d.DriveType == DriveType.CDRom)
                .ToList();

            foreach (var drive in cdDrives)
            {
                string label;
                try
                {
                    label = drive.IsReady
                        ? $"{drive.Name.TrimEnd('\\')} ({drive.VolumeLabel})"
                        : $"{drive.Name.TrimEnd('\\')} ({L("ImportNoDisc")})";
                }
                catch
                {
                    label = $"{drive.Name.TrimEnd('\\')} ({L("ImportNoDisc")})";
                }
                CmbDrives.Items.Add(label);
            }

            if (CmbDrives.Items.Count > 0)
                CmbDrives.SelectedIndex = 0;
        }
        catch { }
    }

    private void BrowseZip_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "ZIP files (*.zip)|*.zip|All files (*.*)|*.*",
            Title = L("ImportZip")
        };
        if (dlg.ShowDialog() == true)
        {
            TxtZipPath.Text = dlg.FileName;
            RbZip.IsChecked = true;
        }
    }

    private void BrowseFolder_Click(object sender, RoutedEventArgs e)
    {
        using var dlg = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = L("ImportFolder"),
            ShowNewFolderButton = false
        };
        if (dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            TxtFolderPath.Text = dlg.SelectedPath;
            RbFolder.IsChecked = true;
        }
    }

    private void RefreshDrives_Click(object sender, RoutedEventArgs e)
    {
        RefreshDrives();
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        if (RbZip.IsChecked == true)
        {
            if (string.IsNullOrEmpty(TxtZipPath.Text))
            {
                MessageBox.Show(L("ImportSelectSource"), L("ImportTitle"),
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            SelectedSource = ImportSource.Zip;
            SelectedPath = TxtZipPath.Text;
        }
        else if (RbFolder.IsChecked == true)
        {
            if (string.IsNullOrEmpty(TxtFolderPath.Text))
            {
                MessageBox.Show(L("ImportSelectSource"), L("ImportTitle"),
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            SelectedSource = ImportSource.Folder;
            SelectedPath = TxtFolderPath.Text;
        }
        else if (RbDisc.IsChecked == true)
        {
            if (CmbDrives.SelectedItem == null)
            {
                MessageBox.Show(L("ImportNoDiscInserted"), L("ImportTitle"),
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            SelectedSource = ImportSource.Disc;
            // Extract drive letter from "F: (label)" format
            var driveText = CmbDrives.SelectedItem.ToString() ?? "";
            SelectedPath = driveText.Length >= 2 ? driveText[..2] + "\\" : driveText;
        }

        DialogResult = true;
    }

    private static string L(string key) => LocalizationHelper.Get(key);
}
