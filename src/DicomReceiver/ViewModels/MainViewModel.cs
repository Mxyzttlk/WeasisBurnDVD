using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using DicomReceiver.Helpers;
using DicomReceiver.Models;
using DicomReceiver.Services;

namespace DicomReceiver.ViewModels;

public class MainViewModel : CommunityToolkit.Mvvm.ComponentModel.ObservableObject
{
    private readonly DicomScpService _scpService = new();
    private readonly StudyMonitorService _monitorService = new();
    private readonly BurnService _burnService = new();
    private readonly SettingsService _settingsService = new();
    private readonly Dispatcher _dispatcher;

    private AppSettings _settings;

    public ObservableCollection<ReceivedStudy> Studies { get; } = new();
    public ObservableCollection<string> LogEntries { get; } = new();

    private bool _isRunning;
    public bool IsRunning
    {
        get => _isRunning;
        set
        {
            if (SetProperty(ref _isRunning, value))
            {
                OnPropertyChanged(nameof(StatusText));
                OnPropertyChanged(nameof(StatusColor));
                OnPropertyChanged(nameof(ToggleButtonText));
            }
        }
    }

    public string StatusText => IsRunning
        ? $"{L("ScpRunning")} — AE: {_settings.AeTitle} | {L("Port")}: {_settings.Port}"
        : L("ScpStopped");

    public string StatusColor => IsRunning ? "#0F9B58" : "#E53935";
    public string ToggleButtonText => IsRunning ? L("Stop") : L("Start");
    public string Title => L("AppTitle");

    public ICommand ToggleScpCommand { get; }
    public ICommand OpenSettingsCommand { get; }
    public ICommand BurnStudyCommand { get; }
    public ICommand DeleteStudyCommand { get; }
    public ICommand DeleteAllCommand { get; }
    public ICommand ClearLogCommand { get; }

    public MainViewModel()
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
        _settings = _settingsService.Load();

        LocalizationHelper.SetLanguage(_settings.Language);

        ToggleScpCommand = new RelayCommand(ToggleScp);
        OpenSettingsCommand = new RelayCommand(OpenSettings);
        BurnStudyCommand = new RelayCommand(BurnStudy);
        DeleteStudyCommand = new RelayCommand(DeleteStudy);
        DeleteAllCommand = new RelayCommand(DeleteAll);
        ClearLogCommand = new RelayCommand(() => LogEntries.Clear());

        // Wire up events
        _scpService.FileReceived += (s, e) =>
        {
            _monitorService.OnFileReceived(e);
        };

        _scpService.LogMessage += (s, msg) =>
        {
            _dispatcher.Invoke(() => AddLog(msg));
        };

        _monitorService.StudyUpdated += (s, e) =>
        {
            _dispatcher.Invoke(() =>
            {
                if (!Studies.Contains(e.Study))
                    Studies.Insert(0, e.Study);
            });
        };

        _monitorService.StudyCompleted += (s, e) =>
        {
            _dispatcher.Invoke(() =>
            {
                AddLog($"Study complete: {e.Study.PatientName} — {e.Study.ImageCount} images, {e.Study.TotalSizeFormatted}");
            });
        };

        _burnService.LogMessage += (s, msg) =>
        {
            _dispatcher.Invoke(() => AddLog(msg));
        };

        // Auto-start SCP
        StartScp();
    }

    private void ToggleScp()
    {
        if (IsRunning)
            StopScp();
        else
            StartScp();
    }

    private void StartScp()
    {
        try
        {
            _scpService.Start(_settings.AeTitle, _settings.Port, _settings.IncomingFolder);
            _monitorService.Start(_settings.StudyTimeoutSeconds);
            IsRunning = true;
        }
        catch (Exception ex)
        {
            AddLog($"ERROR: {ex.Message}");
            MessageBox.Show(ex.Message, "SCP Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void StopScp()
    {
        _scpService.Stop();
        _monitorService.Stop();
        IsRunning = false;
    }

    private void OpenSettings()
    {
        var dialog = new Views.SettingsDialog(_settings);
        dialog.Owner = Application.Current.MainWindow;
        if (dialog.ShowDialog() == true)
        {
            _settings = dialog.Settings;
            _settingsService.Save(_settings);
            LocalizationHelper.SetLanguage(_settings.Language);

            // Refresh UI text
            OnPropertyChanged(nameof(StatusText));
            OnPropertyChanged(nameof(Title));
            OnPropertyChanged(nameof(ToggleButtonText));

            AddLog(L("RestartRequired"));
        }
    }

    private async void BurnStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;
        if (study.Status != StudyStatus.Complete) return;

        await _burnService.BurnStudyAsync(study, _settings);
    }

    private void DeleteStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;

        var result = MessageBox.Show(
            L("ConfirmDelete"),
            L("Delete"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (result != MessageBoxResult.Yes) return;

        // Delete files from disk
        try
        {
            if (Directory.Exists(study.StoragePath))
                Directory.Delete(study.StoragePath, true);
        }
        catch (Exception ex)
        {
            AddLog($"Delete error: {ex.Message}");
        }

        Studies.Remove(study);
        _monitorService.RemoveStudy(study.StudyInstanceUid);
        AddLog($"Deleted: {study.PatientName}");
    }

    private void DeleteAll()
    {
        if (Studies.Count == 0) return;

        var result = MessageBox.Show(
            L("ConfirmDeleteAll"),
            L("DeleteAll"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (result != MessageBoxResult.Yes) return;

        foreach (var study in Studies.ToList())
        {
            try
            {
                if (Directory.Exists(study.StoragePath))
                    Directory.Delete(study.StoragePath, true);
            }
            catch { }
            _monitorService.RemoveStudy(study.StudyInstanceUid);
        }

        Studies.Clear();
        AddLog("All studies deleted");
    }

    private void AddLog(string message)
    {
        var entry = $"[{DateTime.Now:HH:mm:ss}] {message}";
        LogEntries.Add(entry);

        // Keep max 500 entries
        while (LogEntries.Count > 500)
            LogEntries.RemoveAt(0);
    }

    public void Shutdown()
    {
        StopScp();
        _monitorService.Dispose();
    }

    private static string L(string key) => LocalizationHelper.Get(key);
}
