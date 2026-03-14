using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Input;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using DicomReceiver.Helpers;
using DicomReceiver.Models;
using DicomReceiver.Services;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace DicomReceiver.ViewModels;

public class PacsViewModel : ObservableObject, IDisposable
{
    private readonly PacsDownloadService _downloadService;
    private readonly SettingsService _settingsService;
    private readonly AppSettings _settings;
    private readonly Dispatcher _dispatcher;

    // WebView2 reference — set from code-behind after init
    private WebView2? _webView;
    private bool _isWebViewReady;

    // Automation timers
    private DispatcherTimer? _autoTimer;       // 800ms delay after navigation for login/unlock
    private DispatcherTimer? _modalTimer;      // 1500ms delay after DOMContentLoaded for MutationObserver
    private DispatcherTimer? _downloadPollTimer; // Adaptive polling for PACS download modal

    // Download state — per-operation tracking (supports concurrent downloads)
    private readonly Dictionary<CoreWebView2DownloadOperation, (string path, string name)> _activeDownloads = new();
    private readonly EventHandler<string> _onLogMessage;

    // Observable properties
    private string _statusText = "";
    public string StatusText
    {
        get => _statusText;
        set => SetProperty(ref _statusText, value);
    }

    private string _statusColor = "#666666";
    public string StatusColor
    {
        get => _statusColor;
        set => SetProperty(ref _statusColor, value);
    }

    private string _downloadInfo = "";
    public string DownloadInfo
    {
        get => _downloadInfo;
        set => SetProperty(ref _downloadInfo, value);
    }

    private int _selectedNetworkIndex;
    public int SelectedNetworkIndex
    {
        get => _selectedNetworkIndex;
        set => SetProperty(ref _selectedNetworkIndex, value);
    }

    public ObservableCollection<string> NetworkLabels { get; } = new();

    private string _burnDvdLabel = L("BurnDvd");
    public string BurnDvdLabel
    {
        get => _burnDvdLabel;
        set => SetProperty(ref _burnDvdLabel, value);
    }

    private bool _canBurnDvd;
    public bool CanBurnDvd
    {
        get => _canBurnDvd;
        set => SetProperty(ref _canBurnDvd, value);
    }

    // Last downloaded study UID + ZIP path — for BURN DVD button + cleanup
    private string? _lastDownloadedStudyUid;
    private string? _lastDownloadedZipPath;

    // Commands
    public ICommand ConnectCommand { get; }
    public ICommand RefreshCommand { get; }
    public ICommand OpenDownloadsFolderCommand { get; }
    public ICommand BurnDvdCommand { get; }

    // Events
    public event EventHandler<string>? LogMessage;
    /// <summary>Fired when user clicks BURN DVD — passes StudyInstanceUid to MainViewModel.</summary>
    public event EventHandler<string>? BurnRequested;

    public PacsViewModel(PacsDownloadService downloadService, SettingsService settingsService, AppSettings settings)
    {
        _downloadService = downloadService;
        _settingsService = settingsService;
        _settings = settings;
        _dispatcher = Dispatcher.CurrentDispatcher;

        ConnectCommand = new RelayCommand(_ => ConnectToSelectedNetwork());
        RefreshCommand = new RelayCommand(_ => Refresh(), _ => _isWebViewReady);
        OpenDownloadsFolderCommand = new RelayCommand(_ => OpenDownloadsFolder());
        BurnDvdCommand = new RelayCommand(_ => RequestBurnDvd(), _ => _canBurnDvd);

        // Wire download events
        _downloadService.DownloadProgress += OnDownloadProgress;
        _downloadService.DownloadCompleted += OnDownloadCompleted;
        _onLogMessage = (_, msg) => Log(msg);
        _downloadService.LogMessage += _onLogMessage;

        StatusText = L("PacsDisconnected");

        RefreshNetworkLabels();
        SelectedNetworkIndex = Math.Min(_settings.LastPacsNetworkIndex, _settings.PacsNetworks.Count - 1);
        if (SelectedNetworkIndex < 0) SelectedNetworkIndex = 0;
    }

    // ========================================================================
    // WebView2 LIFECYCLE
    // ========================================================================

    /// <summary>
    /// Called from PacsBrowserView.xaml.cs after WebView2 initialization completes.
    /// Wires all CoreWebView2 events and auto-connects to last network.
    /// </summary>
    public void SetWebView(WebView2 webView)
    {
        _webView = webView;
        _isWebViewReady = true;

        var core = webView.CoreWebView2;

        core.NavigationCompleted += OnNavigationCompleted;
        core.DownloadStarting += OnDownloadStarting;
        core.DOMContentLoaded += OnDOMContentLoaded;
        core.NewWindowRequested += OnNewWindowRequested;

        Log("WebView2 initialized");
        CanBurnDvd = true; // BURN always enabled — dual mode (existing ZIP or trigger download)

        // Auto-connect to last used network
        if (_settings.PacsNetworks.Count > 0)
        {
            ConnectToNetwork(SelectedNetworkIndex);
        }
    }

    // ========================================================================
    // NAVIGATION
    // ========================================================================

    public void RefreshNetworkLabels()
    {
        NetworkLabels.Clear();
        foreach (var net in _settings.PacsNetworks)
        {
            NetworkLabels.Add($"{net.Name} — {net.Url}");
        }
    }

    private void ConnectToSelectedNetwork()
    {
        ConnectToNetwork(SelectedNetworkIndex);
    }

    public void ConnectToNetwork(int index)
    {
        if (!_isWebViewReady || _webView == null) return;
        if (index < 0 || index >= _settings.PacsNetworks.Count) return;

        var net = _settings.PacsNetworks[index];
        _settings.LastPacsNetworkIndex = index;

        // Persist lastNetwork to disk (like PS version)
        try { _settingsService.Save(_settings); } catch { }

        StatusText = string.Format(L("PacsConnecting"), net.Name);
        StatusColor = "#FFA500"; // orange

        try
        {
            _webView.CoreWebView2.Navigate(net.Url);
        }
        catch (Exception ex)
        {
            StatusText = string.Format(L("PacsNavError"), ex.Message);
            StatusColor = "#D32F2F"; // red
        }
    }

    private void Refresh()
    {
        if (!_isWebViewReady || _webView == null) return;
        _webView.CoreWebView2.Reload();
    }

    private void OpenDownloadsFolder()
    {
        var folder = Path.GetDirectoryName(_downloadService.GetDownloadPath("dummy")) ?? ".";
        if (Directory.Exists(folder))
            Process.Start("explorer.exe", folder);
    }

    // ========================================================================
    // WEBVIEW2 EVENT HANDLERS
    // ========================================================================

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        _dispatcher.BeginInvoke(() =>
        {
            if (e.IsSuccess)
            {
                var url = _webView?.CoreWebView2?.Source ?? "";
                StatusText = string.Format(L("PacsConnected"), url);
                StatusColor = "#0F9B58"; // green

                // Start 800ms timer for page automation (login/unlock)
                _autoTimer?.Stop();
                _autoTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
                _autoTimer.Tick += (_, _) =>
                {
                    _autoTimer.Stop();
                    RunPageAutomation();
                };
                _autoTimer.Start();
            }
            else
            {
                // Suppress ConnectionAborted (normal during downloads)
                if (e.WebErrorStatus != CoreWebView2WebErrorStatus.ConnectionAborted)
                {
                    StatusText = string.Format(L("PacsNavError"), e.WebErrorStatus);
                    StatusColor = "#D32F2F";
                }
            }
        });
    }

    private void OnDownloadStarting(object? sender, CoreWebView2DownloadStartingEventArgs e)
    {
        // Use ResultFilePath (browser's suggested path, e.g. C:\Users\X\Downloads\file.zip)
        // NOT DownloadOperation.Uri (HTTP URL like /api/download?id=xxx — no filename)
        var originalName = Path.GetFileName(e.ResultFilePath);

        // Only intercept ZIP files (non-ZIP: default WebView2 behavior, like PS version)
        if (!originalName.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            return;

        // Stop download poll timer (download was triggered by BURN button polling)
        _downloadPollTimer?.Stop();

        // Redirect to downloads/ folder
        var downloadPath = _downloadService.GetDownloadPath(originalName);
        e.ResultFilePath = downloadPath;
        e.Handled = true;

        // Track per download operation (supports concurrent downloads)
        _activeDownloads[e.DownloadOperation] = (downloadPath, originalName);

        Log($"Download intercepted: {originalName}");

        _dispatcher.BeginInvoke(() =>
        {
            DownloadInfo = $"{originalName} — 0%";
        });

        // Wire progress — update UI directly (like PS version), throttled 500ms
        var dlName = originalName;
        DateTime lastProgress = DateTime.MinValue;
        e.DownloadOperation.BytesReceivedChanged += (op, _) =>
        {
            var now = DateTime.UtcNow;
            if ((now - lastProgress).TotalMilliseconds < 500) return;
            lastProgress = now;

            var dlOp = (CoreWebView2DownloadOperation)op!;
            var received = dlOp.BytesReceived;
            var total = (long)(dlOp.TotalBytesToReceive ?? 0);
            var receivedMb = received / (1024.0 * 1024.0);

            _dispatcher.BeginInvoke(() =>
            {
                if (total > 0)
                {
                    var pct = (int)(received * 100 / total);
                    var totalMb = total / (1024.0 * 1024.0);
                    DownloadInfo = $"{dlName} — {receivedMb:F1} / {totalMb:F1} MB ({pct}%)";
                }
                else
                {
                    DownloadInfo = $"{dlName} — {receivedMb:F1} MB";
                }
            });
        };

        // Wire completion (primary path — StateChanged with Completed)
        e.DownloadOperation.StateChanged += OnDownloadStateChanged;

        // Fallback: poll file every 3s — WebView2 StateChanged sometimes never fires Completed
        var dlPath = downloadPath;
        bool dlProcessed = false;
        var fallbackTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        fallbackTimer.Tick += (_, _) =>
        {
            if (dlProcessed) { fallbackTimer.Stop(); return; }
            if (!File.Exists(dlPath)) return;

            // Try to open file exclusively — if it succeeds, WebView2 released the handle
            try
            {
                using var fs = new FileStream(dlPath, FileMode.Open, FileAccess.Read, FileShare.None);
                fs.Close();
            }
            catch (IOException)
            {
                return; // Still locked by WebView2 — retry next tick
            }

            // File is ready — stop everything and process
            dlProcessed = true;
            fallbackTimer.Stop();
            e.DownloadOperation.StateChanged -= OnDownloadStateChanged;
            _activeDownloads.Remove(e.DownloadOperation);
            Log($"Download complete (file-ready fallback): {dlName}");
            ProcessDownloadedZip(dlPath, dlName);
        };
        fallbackTimer.Start();
    }

    private void OnDownloadStateChanged(object? sender, object e)
    {
        try
        {
            var op = (CoreWebView2DownloadOperation)sender!;

            // Only process terminal states — InProgress fires mid-download
            if (op.State != CoreWebView2DownloadState.Completed &&
                op.State != CoreWebView2DownloadState.Interrupted)
                return;

            op.StateChanged -= OnDownloadStateChanged;

            if (!_activeDownloads.TryGetValue(op, out var dl))
            {
                Log($"StateChanged {op.State} but download not tracked");
                return;
            }
            _activeDownloads.Remove(op);

            if (op.State == CoreWebView2DownloadState.Completed)
            {
                ProcessDownloadedZip(dl.path, dl.name);
            }
            else
            {
                _dispatcher.BeginInvoke(() =>
                {
                    DownloadInfo = L("PacsDownloadInterrupted");
                    StatusColor = "#D32F2F";
                });
                Log($"Download interrupted: {dl.name}");
            }
        }
        catch (Exception ex)
        {
            Log($"StateChanged error: {ex.Message}");
        }
    }

    /// <summary>
    /// Process a completed ZIP file — runs on background thread, updates UI synchronously.
    /// Separated from event handler to also be callable from fallback timer.
    /// </summary>
    private void ProcessDownloadedZip(string path, string name)
    {
        Log($"Download complete: {name}");

        _dispatcher.BeginInvoke(() =>
        {
            DownloadInfo = L("PacsDownloadProcessing");
            StatusColor = "#0F9B58";
        });

        // Fire-and-forget on background — ProcessCompletedDownloadAsync has its own try-catch
        _ = Task.Run(async () =>
        {
            try
            {
                await _downloadService.ProcessCompletedDownloadAsync(path);
            }
            catch (Exception ex)
            {
                Log($"ZIP processing failed: {ex.Message}");
            }
        });
    }

    private void OnDOMContentLoaded(object? sender, CoreWebView2DOMContentLoadedEventArgs e)
    {
        _dispatcher.BeginInvoke(() =>
        {
            // Re-inject MutationObserver after each page load
            _modalTimer?.Stop();
            _modalTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1500) };
            _modalTimer.Tick += (_, _) =>
            {
                _modalTimer.Stop();
                InjectModalObserver();
            };
            _modalTimer.Start();
        });
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        // Prevent popups — navigate in same view
        e.Handled = true;
        _webView?.CoreWebView2?.Navigate(e.Uri);
    }

    // ========================================================================
    // JAVASCRIPT AUTOMATION
    // ========================================================================

    /// <summary>
    /// Auto-login + auto-unlock. Runs 800ms after NavigationCompleted.
    /// Uses React-compatible native HTMLInputElement setter pattern.
    /// </summary>
    private async void RunPageAutomation()
    {
        if (!_isWebViewReady || _webView == null) return;
        var core = _webView.CoreWebView2;

        var idx = SelectedNetworkIndex;
        if (idx < 0 || idx >= _settings.PacsNetworks.Count) return;
        var net = _settings.PacsNetworks[idx];

        // Auto-login
        if (_settings.AutoLogin && string.IsNullOrEmpty(net.Username))
        {
            _ = _dispatcher.BeginInvoke(() =>
            {
                StatusText = L("PacsAutoLoginHint");
                StatusColor = "#FFA500";
            });
        }
        else if (_settings.AutoLogin && !string.IsNullOrEmpty(net.Username))
        {
            var user = EscapeJs(net.Username);
            var pass = EscapeJs(net.DecryptedPassword);

            var loginJs = $@"
(function() {{
    var loginForm = document.getElementById('login');
    var userField = document.getElementById('username');
    var passField = document.getElementById('password');
    if (loginForm && userField && userField.offsetParent !== null) {{
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(userField, '{user}');
        userField.dispatchEvent(new Event('input', {{bubbles: true}}));
        userField.dispatchEvent(new Event('change', {{bubbles: true}}));
        setter.call(passField, '{pass}');
        passField.dispatchEvent(new Event('input', {{bubbles: true}}));
        passField.dispatchEvent(new Event('change', {{bubbles: true}}));
        setTimeout(function() {{
            var submitBtn = loginForm.querySelector('button[type=""submit""]');
            if (!submitBtn) submitBtn = loginForm.querySelector('button.login-button');
            if (submitBtn) submitBtn.click();
        }}, 300);
        return 'login-submitted';
    }}
    return 'no-login-form';
}})();";

            try
            {
                var result = await core.ExecuteScriptAsync(loginJs);
                if (result.Contains("login-submitted"))
                {
                    Log("Auto-login submitted");
                    _ = _dispatcher.BeginInvoke(() => StatusText = L("PacsAutoLogin"));
                }
            }
            catch { }
        }

        // Auto-unlock ("Blocat" lock panel)
        if (_settings.AutoUnlock && !string.IsNullOrEmpty(net.DecryptedPassword))
        {
            var pass = EscapeJs(net.DecryptedPassword);

            var unlockJs = $@"
(function() {{
    var lockPanel = document.querySelector('.panel.panel-danger');
    if (lockPanel) {{
        var title = lockPanel.querySelector('.panel-title');
        if (title && title.textContent.indexOf('Blocat') >= 0) {{
            var passField = document.getElementById('password');
            if (passField) {{
                var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                setter.call(passField, '{pass}');
                passField.dispatchEvent(new Event('input', {{bubbles: true}}));
                passField.dispatchEvent(new Event('change', {{bubbles: true}}));
                setTimeout(function() {{
                    var btn = lockPanel.querySelector('button[type=""submit""]');
                    if (!btn) btn = lockPanel.querySelector('button.login-button');
                    if (btn) btn.click();
                }}, 300);
                return 'unlock-submitted';
            }}
        }}
    }}
    return 'no-lock-screen';
}})();";

            try
            {
                var result = await core.ExecuteScriptAsync(unlockJs);
                if (result.Contains("unlock-submitted"))
                {
                    Log("Auto-unlock submitted");
                    _ = _dispatcher.BeginInvoke(() => StatusText = L("PacsAutoUnlock"));
                }
            }
            catch { }
        }
    }

    /// <summary>
    /// Inject MutationObserver to auto-check "Exclude Viewer" checkbox
    /// when download modal appears. Debounced 500ms.
    /// </summary>
    private async void InjectModalObserver()
    {
        if (!_isWebViewReady || _webView == null || !_settings.AutoExcludeViewer) return;

        const string observerJs = @"
(function() {
    if (window._pacsBurnerObserver) {
        window._pacsBurnerObserver.disconnect();
        window._pacsBurnerObserver = null;
    }
    if (window._pacsBurnerDebounce) {
        clearTimeout(window._pacsBurnerDebounce);
        window._pacsBurnerDebounce = null;
    }

    function checkModal() {
        var modal = document.querySelector('.modal-dialog');
        if (!modal) return;
        var labels = modal.querySelectorAll('label');
        for (var i = 0; i < labels.length; i++) {
            if (labels[i].textContent.indexOf('Exclude Viewer') >= 0) {
                var cb = labels[i].querySelector('input[type=checkbox]');
                if (cb && !cb.checked) cb.click();
                break;
            }
        }
    }

    window._pacsBurnerObserver = new MutationObserver(function(mutations) {
        if (window._pacsBurnerDebounce) return;
        window._pacsBurnerDebounce = setTimeout(function() {
            window._pacsBurnerDebounce = null;
            checkModal();
        }, 500);
    });

    window._pacsBurnerObserver.observe(document.body, {
        childList: true,
        subtree: true
    });

    return 'observer-injected';
})();";

        try
        {
            await _webView.CoreWebView2.ExecuteScriptAsync(observerJs);
        }
        catch { }
    }

    // ========================================================================
    // DOWNLOAD EVENTS
    // ========================================================================

    private void OnDownloadProgress(object? sender, DownloadProgressEventArgs e)
    {
        _dispatcher.BeginInvoke(() =>
        {
            DownloadInfo = string.Format(L("PacsDownloading"),
                e.FileName,
                e.BytesReceived / (1024.0 * 1024.0),
                e.TotalBytes / (1024.0 * 1024.0),
                e.PercentComplete);
        });
    }

    private void OnDownloadCompleted(object? sender, DownloadCompleteEventArgs e)
    {
        _dispatcher.BeginInvoke(() =>
        {
            if (e.Success)
            {
                DownloadInfo = string.Format(L("PacsDownloadProcessed"), e.PatientName, e.ImageCount);
                _lastDownloadedStudyUid = e.StudyInstanceUid;
                _lastDownloadedZipPath = e.ZipPath;
                CanBurnDvd = true;
                BurnDvdLabel = $"{L("BurnDvd")} — {e.PatientName}";

                // Auto-burn: fire burn immediately after download (like PS version)
                RequestBurnDvd();
            }
            else
            {
                DownloadInfo = string.Format(L("PacsDownloadError"), e.Error ?? "Unknown");
                StatusColor = "#D32F2F";
            }
        });
    }

    private void RequestBurnDvd()
    {
        if (!string.IsNullOrEmpty(_lastDownloadedStudyUid))
        {
            // ZIP already downloaded — burn immediately
            CanBurnDvd = false;
            BurnRequested?.Invoke(this, _lastDownloadedStudyUid);
        }
        else
        {
            // No ZIP — initiate PACS download, auto-burn when done
            StatusText = L("PacsDownloading").Split('{')[0].TrimEnd() + "...";
            StatusColor = "#FFA500";
            DownloadInfo = L("PacsDownloadProcessing");
            StartPacsDownload();
        }
    }

    /// <summary>
    /// Clicks the PACS download button (.glyphicon-download), then polls for
    /// the download modal to appear, checks "Exclude Viewer", and clicks "Descarcare".
    /// Mirrors PS Start-PacsDownload with adaptive polling (500ms→3000ms).
    /// </summary>
    private async void StartPacsDownload()
    {
        if (!_isWebViewReady || _webView == null) return;

        // Step 1: Click the download toolbar button
        const string clickDownloadJs = @"
(function() {
    var icon = document.querySelector('.glyphicon-download');
    if (icon) {
        var btn = icon.closest('button') || icon.parentElement;
        if (btn) { btn.click(); return 'clicked'; }
    }
    return 'no-download-btn';
})();";

        try
        {
            var result = await _webView.CoreWebView2.ExecuteScriptAsync(clickDownloadJs);
            if (result.Contains("no-download-btn"))
            {
                Log("No download button found on page");
                return;
            }
        }
        catch { return; }

        // Step 2: Poll for download modal (adaptive: 500ms first 20 ticks, then 3000ms)
        // Mirrors PS Start-PacsDownload: no title check, broad selectors, stateless per tick
        _downloadPollTimer?.Stop();
        int ticks = 0;
        _downloadPollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _downloadPollTimer.Tick += async (_, _) =>
        {
            ticks++;

            // Adaptive interval: slow down after 10 seconds
            if (ticks == 20)
                _downloadPollTimer!.Interval = TimeSpan.FromMilliseconds(3000);

            // Timeout after ~160 ticks (~8 min with adaptive intervals)
            if (ticks > 160)
            {
                _downloadPollTimer!.Stop();
                Log("Download modal polling timed out");
                return;
            }

            // Stateless JS — each tick tries full sequence (matches PS exactly):
            // 1. Find modal → if not found, keep polling
            // 2. Find "Exclude Viewer" checkbox → if unchecked, click it and return (next tick continues)
            // 3. If checkbox already checked → click btn-primary (Descărcare)
            const string pollModalJs = @"
(function() {
    var modal = document.querySelector('.modal-dialog');
    if (!modal) return 'no-modal';

    var labels = modal.querySelectorAll('label');
    for (var i = 0; i < labels.length; i++) {
        if (labels[i].textContent.indexOf('Exclude Viewer') >= 0) {
            var cb = labels[i].querySelector('input[type=checkbox]');
            if (cb && !cb.checked) {
                cb.click();
                return 'checkbox-clicked';
            }
            break;
        }
    }

    var btns = modal.querySelectorAll('button');
    for (var j = 0; j < btns.length; j++) {
        if (btns[j].className.indexOf('btn-primary') >= 0) {
            btns[j].click();
            return 'download-clicked';
        }
    }
    return 'no-btn';
})();";

            try
            {
                var result = await _webView!.CoreWebView2.ExecuteScriptAsync(pollModalJs);
                if (result.Contains("download-clicked"))
                {
                    _downloadPollTimer!.Stop();
                    Log("PACS download initiated from modal");
                }
            }
            catch { }
        };
        _downloadPollTimer.Start();
    }

    /// <summary>
    /// Called by MainViewModel after burn completes (success or failure).
    /// On success: resets state and reloads PACS page for next download.
    /// On failure: resets state, shows error in status bar, does NOT reload page.
    /// </summary>
    public void OnBurnCompleted(bool success)
    {
        _dispatcher.BeginInvoke(() =>
        {
            // Delete downloaded ZIP after burn (success or cancel — download is consumed)
            if (!string.IsNullOrEmpty(_lastDownloadedZipPath))
            {
                try
                {
                    if (File.Exists(_lastDownloadedZipPath))
                    {
                        File.Delete(_lastDownloadedZipPath);
                        Log($"Deleted ZIP: {Path.GetFileName(_lastDownloadedZipPath)}");
                    }
                }
                catch { }
            }

            _lastDownloadedStudyUid = null;
            _lastDownloadedZipPath = null;
            CanBurnDvd = true; // Re-enable for next download or manual trigger
            BurnDvdLabel = L("BurnDvd");
            DownloadInfo = "";

            // Always reload PACS page (reset React SPA state for next download)
            if (_isWebViewReady && _webView?.CoreWebView2 != null)
            {
                try { _webView.CoreWebView2.Reload(); } catch { }
            }
        });
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// <summary>Escape string for JS single-quoted string literal.</summary>
    private static string EscapeJs(string value)
    {
        return value
            .Replace("\\", "\\\\")
            .Replace("'", "\\'")
            .Replace("\n", "\\n")
            .Replace("\r", "\\r");
    }

    private static string L(string key) => LocalizationHelper.Get(key);

    private void Log(string message)
    {
        LogMessage?.Invoke(this, message);
    }

    // ========================================================================
    // CLEANUP
    // ========================================================================

    public void Dispose()
    {
        _autoTimer?.Stop();
        _modalTimer?.Stop();
        _downloadPollTimer?.Stop();

        // Unsubscribe download service events (prevent leaks if recreated)
        _downloadService.DownloadProgress -= OnDownloadProgress;
        _downloadService.DownloadCompleted -= OnDownloadCompleted;
        _downloadService.LogMessage -= _onLogMessage;

        if (_webView != null)
        {
            try
            {
                var core = _webView.CoreWebView2;
                if (core != null)
                {
                    core.NavigationCompleted -= OnNavigationCompleted;
                    core.DownloadStarting -= OnDownloadStarting;
                    core.DOMContentLoaded -= OnDOMContentLoaded;
                    core.NewWindowRequested -= OnNewWindowRequested;
                }
            }
            catch { }

            try { _webView.Dispose(); } catch { }
            _webView = null;
        }

        _isWebViewReady = false;
    }
}

// Simple RelayCommand for PACS ViewModel — avoids dependency on Helpers.RelayCommand
// Uses same pattern as existing project RelayCommand
file class RelayCommand : ICommand
{
    private readonly Action<object?> _execute;
    private readonly Func<object?, bool>? _canExecute;

    public RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => _execute(parameter);
}
