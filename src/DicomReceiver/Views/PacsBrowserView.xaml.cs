using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DicomReceiver.Helpers;
using DicomReceiver.ViewModels;
using Microsoft.Web.WebView2.Core;

namespace DicomReceiver.Views;

public partial class PacsBrowserView : UserControl
{
    private bool _webViewInitialized;

    // Pre-created frozen brushes for known status colors (avoids allocation on every change)
    private static readonly Dictionary<string, SolidColorBrush> _brushCache = CreateBrushCache();
    private static Dictionary<string, SolidColorBrush> CreateBrushCache()
    {
        var cache = new Dictionary<string, SolidColorBrush>(StringComparer.OrdinalIgnoreCase);
        foreach (var hex in new[] { "#666666", "#FFA500", "#0F9B58", "#D32F2F" })
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            brush.Freeze();
            cache[hex] = brush;
        }
        return cache;
    }

    public PacsBrowserView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_webViewInitialized) return;
        _webViewInitialized = true;

        ApplyLocalization();

        // Set UserDataFolder BEFORE EnsureCoreWebView2Async
        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "WeasisBurn", "WebView2Data");
        Directory.CreateDirectory(userDataFolder);

        try
        {
            var env = await CoreWebView2Environment.CreateAsync(
                userDataFolder: userDataFolder);
            await WebView.EnsureCoreWebView2Async(env);

            // Inject popup wrapper — PACS site checks if window.open returns null
            await WebView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(PopupBlockerScript);

            // Pass WebView to ViewModel
            if (DataContext is PacsViewModel vm)
            {
                SetupStatusColorBinding();
                vm.SetWebView(WebView);
            }
        }
        catch (Exception ex)
        {
            TxtStatus.Text = $"WebView2 error: {ex.Message}";
            StatusDot.Fill = new SolidColorBrush(Color.FromRgb(0xD3, 0x2F, 0x2F));
        }
    }

    private void SetupStatusColorBinding()
    {
        if (DataContext is PacsViewModel vm)
        {
            vm.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName == nameof(PacsViewModel.StatusColor))
                {
                    Dispatcher.BeginInvoke(() =>
                    {
                        try
                        {
                            if (_brushCache.TryGetValue(vm.StatusColor, out var cached))
                            {
                                StatusDot.Fill = cached;
                            }
                            else
                            {
                                var color = (Color)ColorConverter.ConvertFromString(vm.StatusColor);
                                var brush = new SolidColorBrush(color);
                                brush.Freeze();
                                StatusDot.Fill = brush;
                            }
                        }
                        catch { }
                    });
                }
            };
        }
    }

    private void ApplyLocalization()
    {
        TxtNetworkLabel.Text = L("PacsNetwork");
        BtnConnect.Content = L("PacsConnect");
        BtnRefresh.ToolTip = L("PacsRefresh");
        BtnOpenDownloads.ToolTip = L("OpenDownloads");
    }

    private static string L(string key) => LocalizationHelper.Get(key);

    private const string PopupBlockerScript = @"
(function() {
    var _origOpen = window.open;
    window.open = function(url, target, features) {
        if (url && url !== '' && url !== 'about:blank') {
            try { _origOpen.call(window, url, target, features); } catch(e) {}
        }
        return window;
    };
})();
";
}
