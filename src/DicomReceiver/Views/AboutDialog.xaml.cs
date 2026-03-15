using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using DicomReceiver.Helpers;

namespace DicomReceiver.Views;

public partial class AboutDialog : Window
{
    private static string L(string key) => LocalizationHelper.Get(key);

    public AboutDialog()
    {
        InitializeComponent();

        var version = Assembly.GetExecutingAssembly().GetName().Version;
        TxtVersion.Text = $"v{version?.Major}.{version?.Minor}.{version?.Build}";

        // Load app icon from high-res PNG (512px source, WPF scales smoothly to 48px display)
        var pngPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "app-preview.png");
        if (!File.Exists(pngPath))
            pngPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "app.ico");
        if (File.Exists(pngPath))
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.UriSource = new Uri(pngPath, UriKind.Absolute);
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.EndInit();
            bitmap.Freeze();
            AppIcon.Source = bitmap;
        }

        ApplyLocalization();
    }

    private void ApplyLocalization()
    {
        Title = L("AboutTitle");
        TxtAppName.Text = L("AppTitle");
        TxtCopyright.Text = L("AboutCopyright");
        TxtLicense.Text = L("AboutLicense");
        TxtComponentsHeader.Text = L("AboutComponents");
        BtnClose.Content = L("OK");
    }

    private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        // Only drag when clicking on the window background, not on interactive controls
        if (e.OriginalSource is System.Windows.Controls.Button or
            System.Windows.Documents.Hyperlink or
            System.Windows.Documents.Run)
            return;

        DragMove();
    }

    private void Hyperlink_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
