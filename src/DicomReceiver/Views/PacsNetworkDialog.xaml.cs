using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using DicomReceiver.Helpers;
using DicomReceiver.Models;

namespace DicomReceiver.Views;

public partial class PacsNetworkDialog : Window
{
    public List<PacsNetwork> Networks { get; private set; }
    public bool Saved { get; private set; }

    public PacsNetworkDialog(List<PacsNetwork> networks)
    {
        InitializeComponent();

        // Deep copy — cancel discards changes
        Networks = networks.Select(n => new PacsNetwork
        {
            Name = n.Name,
            Url = n.Url,
            Username = n.Username,
            EncryptedPassword = n.EncryptedPassword
        }).ToList();

        ApplyLocalization();
        RefreshList();
    }

    private void ApplyLocalization()
    {
        TxtTitle.Text = L("PacsNetworksTitle");
        LblName.Text = L("NetworkName") + ":";
        LblUrl.Text = L("NetworkUrl") + ":";
        LblUsername.Text = L("NetworkUsername") + ":";
        LblPassword.Text = L("NetworkPassword") + ":";
        BtnAdd.Content = L("AddNetwork");
        BtnSave.Content = L("Save");
        BtnDelete.Content = L("DeleteNetwork");
        BtnOK.Content = L("OK");
        BtnCancel.Content = L("Cancel");
        BtnMoveUp.ToolTip = L("MoveUp");
        BtnMoveDown.ToolTip = L("MoveDown");
    }

    private void RefreshList()
    {
        var selected = LstNetworks.SelectedIndex;
        LstNetworks.Items.Clear();
        foreach (var net in Networks)
        {
            LstNetworks.Items.Add($"{net.Name} — {net.Url}");
        }
        if (selected >= 0 && selected < Networks.Count)
            LstNetworks.SelectedIndex = selected;
    }

    private void LstNetworks_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var idx = LstNetworks.SelectedIndex;
        if (idx < 0 || idx >= Networks.Count)
        {
            TxtName.Text = "";
            TxtUrl.Text = "";
            TxtUsername.Text = "";
            TxtPassword.Password = "";
            return;
        }

        var net = Networks[idx];
        TxtName.Text = net.Name;
        TxtUrl.Text = net.Url;
        TxtUsername.Text = net.Username;
        TxtPassword.Password = net.DecryptedPassword;
    }

    private void BtnAdd_Click(object sender, RoutedEventArgs e)
    {
        Networks.Add(new PacsNetwork
        {
            Name = "New Network",
            Url = "http://",
            Username = "",
            EncryptedPassword = ""
        });
        RefreshList();
        LstNetworks.SelectedIndex = Networks.Count - 1;
    }

    private void BtnSave_Click(object sender, RoutedEventArgs e)
    {
        var idx = LstNetworks.SelectedIndex;
        if (idx < 0 || idx >= Networks.Count) return;

        var net = Networks[idx];
        net.Name = TxtName.Text.Trim();
        net.Url = TxtUrl.Text.Trim();
        net.Username = TxtUsername.Text.Trim();
        if (!string.IsNullOrEmpty(TxtPassword.Password))
            net.DecryptedPassword = TxtPassword.Password;

        RefreshList();
    }

    private void BtnDelete_Click(object sender, RoutedEventArgs e)
    {
        var idx = LstNetworks.SelectedIndex;
        if (idx < 0 || idx >= Networks.Count) return;

        var result = MessageBox.Show(
            $"{L("ConfirmDelete")}\n\n{Networks[idx].Name}",
            L("DeleteNetwork"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (result != MessageBoxResult.Yes) return;

        Networks.RemoveAt(idx);
        RefreshList();
        if (Networks.Count > 0)
            LstNetworks.SelectedIndex = System.Math.Min(idx, Networks.Count - 1);
    }

    private void BtnMoveUp_Click(object sender, RoutedEventArgs e)
    {
        var idx = LstNetworks.SelectedIndex;
        if (idx <= 0) return;

        (Networks[idx - 1], Networks[idx]) = (Networks[idx], Networks[idx - 1]);
        RefreshList();
        LstNetworks.SelectedIndex = idx - 1;
    }

    private void BtnMoveDown_Click(object sender, RoutedEventArgs e)
    {
        var idx = LstNetworks.SelectedIndex;
        if (idx < 0 || idx >= Networks.Count - 1) return;

        (Networks[idx + 1], Networks[idx]) = (Networks[idx], Networks[idx + 1]);
        RefreshList();
        LstNetworks.SelectedIndex = idx + 1;
    }

    private void BtnOK_Click(object sender, RoutedEventArgs e)
    {
        // Auto-save current selection before closing
        BtnSave_Click(sender, e);
        Saved = true;
        DialogResult = true;
        Close();
    }

    private void BtnCancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private static string L(string key) => LocalizationHelper.Get(key);
}
