using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.ServiceProcess;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using DicomReceiver.Helpers;
using DicomReceiver.Models;
using DicomReceiver.Services;
using FellowOakDicom;

namespace DicomReceiver.ViewModels;

public class MainViewModel : CommunityToolkit.Mvvm.ComponentModel.ObservableObject
{
    private readonly DicomScpService _scpService = new();
    private readonly StudyMonitorService _monitorService = new();
    private readonly BurnService _burnService = new();
    private readonly SettingsService _settingsService = new();
    private readonly Dispatcher _dispatcher;
    private readonly DispatcherTimer _uiTimer;

    private AppSettings _settings;
    private bool _serviceMode; // true when Windows Service handles SCP
    private readonly HashSet<string> _knownStudyDirs = new(); // for folder scan dedup

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
        ? (_serviceMode
            ? $"SCP Service — AE: {_settings.AeTitle} | {L("Port")}: {_settings.Port}"
            : $"{L("ScpRunning")} — AE: {_settings.AeTitle} | {L("Port")}: {_settings.Port}")
        : L("ScpStopped");

    public string StatusColor => IsRunning ? "#0F9B58" : "#E53935";
    public string ToggleButtonText => IsRunning ? L("Stop") : L("Start");
    public string Title => L("AppTitle");
    public string BurnLabel => L("Burn");

    public event EventHandler? LanguageChanged;

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
        // BeginInvoke (async) — does NOT block the fo-dicom network thread
        // Invoke (sync) would block DICOM reception waiting for UI, causing lag during bulk transfer
        _scpService.FileReceived += (s, e) =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                _monitorService.OnFileReceived(e);

                // Ensure study is in the collection
                var study = _monitorService.Studies
                    .FirstOrDefault(st => st.StudyInstanceUid == e.StudyInstanceUid);
                if (study != null && !Studies.Contains(study))
                    Studies.Insert(0, study);
            });
        };

        _scpService.LogMessage += (s, msg) =>
        {
            _dispatcher.BeginInvoke(() => AddLog(msg));
        };

        _monitorService.StudyCompleted += (s, e) =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                AddLog($"Study complete: {e.Study.PatientName} — {e.Study.ImageCount} images, {e.Study.TotalSizeFormatted}");
            });
        };

        _burnService.LogMessage += (s, msg) =>
        {
            _dispatcher.BeginInvoke(() => AddLog(msg));
        };

        // UI timer — runs on UI thread every 1 second
        // Handles BOTH elapsed time display AND study completion detection
        // (no separate System.Threading.Timer needed — eliminates cross-thread race conditions)
        _uiTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _uiTimer.Tick += (s, e) =>
        {
            if (_serviceMode)
                ScanIncomingFolder();
            _monitorService.CheckAndCompleteStudies();
            _monitorService.UpdateElapsedTimes();
            AutoPurgeOldStudies();
        };
        _uiTimer.Start();

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
            // Check if Windows Service is already handling SCP
            if (IsServiceRunning("DicomReceiverService"))
            {
                _serviceMode = true;
                _monitorService.Start(_settings.StudyTimeoutSeconds);
                IsRunning = true;
                AddLog("SCP Service detected — using Windows Service for DICOM reception");
                return;
            }

            _serviceMode = false;
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

    private static bool IsServiceRunning(string serviceName)
    {
        try
        {
            using var sc = new ServiceController(serviceName);
            return sc.Status == ServiceControllerStatus.Running;
        }
        catch
        {
            // Service not installed or access denied
            return false;
        }
    }

    private void StopScp()
    {
        if (!_serviceMode)
            _scpService.Stop();
        _monitorService.Stop();
        _serviceMode = false;
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
            OnPropertyChanged(nameof(BurnLabel));

            LanguageChanged?.Invoke(this, EventArgs.Empty);
            AddLog(L("RestartRequired"));
        }
    }

    private async void BurnStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;
        if (study.Status != StudyStatus.Complete) return;

        await _burnService.BurnStudyAsync(study, _settings);

        // Auto-delete from queue after successful burn
        if (_settings.AutoDeleteAfterBurn && study.Status == StudyStatus.Done)
        {
            Studies.Remove(study);
            _monitorService.RemoveStudy(study.StudyInstanceUid);
            AddLog($"Auto-deleted: {study.PatientName}");
        }
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
        AddLog(L("DeleteAll"));
    }

    /// <summary>
    /// Auto-purge ONE oldest Done/Error study per tick when count exceeds MaxStudiesKeep.
    /// Runs every 1 second from DispatcherTimer — lightweight: exits immediately if disabled or under limit.
    /// Only removes finished studies (Done/Error), never active ones (Receiving/Complete/Burning).
    /// MAX 1 purge per tick — prevents UI freeze from multiple Directory.Delete calls.
    /// At 1 purge/sec, 10 excess studies clear in 10 seconds — perfectly adequate.
    /// </summary>
    private void AutoPurgeOldStudies()
    {
        // AutoDelete ON → studies removed immediately after burn, purge not needed
        if (_settings.AutoDeleteAfterBurn) return;
        if (_settings.MaxStudiesKeep <= 0) return;
        if (Studies.Count <= _settings.MaxStudiesKeep) return;

        // Find ONE oldest removable study (Done/Error) — no ToList(), stops at first match
        ReceivedStudy? oldest = null;
        foreach (var s in Studies)
        {
            if (s.Status != StudyStatus.Done && s.Status != StudyStatus.Error) continue;
            if (oldest == null || s.LastFileReceivedTime < oldest.LastFileReceivedTime)
                oldest = s;
        }

        if (oldest == null) return; // All studies are active — can't purge

        // Delete files from disk (may already be deleted by BurnService for Done studies)
        try
        {
            if (Directory.Exists(oldest.StoragePath))
                Directory.Delete(oldest.StoragePath, true);
        }
        catch { }

        Studies.Remove(oldest);
        _monitorService.RemoveStudy(oldest.StudyInstanceUid);
        AddLog($"Auto-purged: {oldest.PatientName}");
    }

    /// <summary>
    /// Scans the incoming folder for new study directories when in service mode.
    /// The Windows Service saves files to incoming/{StudyUID}/{SeriesUID}/{SOP}.dcm.
    /// Each new subdirectory = a new study. Parses one .dcm file per study for metadata.
    /// Runs every 1 second from DispatcherTimer — exits fast if no new directories found.
    /// </summary>
    private void ScanIncomingFolder()
    {
        if (!Directory.Exists(_settings.IncomingFolder)) return;

        try
        {
            var incomingDir = new DirectoryInfo(_settings.IncomingFolder);
            foreach (var studyDir in incomingDir.GetDirectories())
            {
                // Skip already-known studies
                if (_knownStudyDirs.Contains(studyDir.Name)) continue;

                // Find any .dcm file to extract metadata
                var dcmFile = studyDir.EnumerateFiles("*.dcm", SearchOption.AllDirectories).FirstOrDefault();
                if (dcmFile == null) continue; // Empty directory, skip for now

                _knownStudyDirs.Add(studyDir.Name);

                try
                {
                    var dicom = DicomFile.Open(dcmFile.FullName, FileReadOption.SkipLargeTags);
                    var ds = dicom.Dataset;

                    var args = new FileReceivedEventArgs
                    {
                        StudyInstanceUid = ds.GetSingleValueOrDefault(DicomTag.StudyInstanceUID, studyDir.Name),
                        PatientName = ds.GetSingleValueOrDefault(DicomTag.PatientName, "Unknown"),
                        PatientId = ds.GetSingleValueOrDefault(DicomTag.PatientID, ""),
                        StudyDate = ds.GetSingleValueOrDefault(DicomTag.StudyDate, ""),
                        Modality = ds.GetSingleValueOrDefault(DicomTag.Modality, "OT"),
                        SeriesInstanceUid = ds.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, ""),
                        FilePath = dcmFile.FullName,
                        FileSize = dcmFile.Length
                    };

                    _monitorService.OnFileReceived(args);

                    // Count all files for accurate image count
                    var allFiles = studyDir.EnumerateFiles("*.dcm", SearchOption.AllDirectories).ToList();
                    foreach (var f in allFiles.Skip(1)) // Skip first, already processed
                    {
                        _monitorService.OnFileReceived(new FileReceivedEventArgs
                        {
                            StudyInstanceUid = args.StudyInstanceUid,
                            PatientName = args.PatientName,
                            PatientId = args.PatientId,
                            StudyDate = args.StudyDate,
                            Modality = args.Modality,
                            SeriesInstanceUid = args.SeriesInstanceUid,
                            FilePath = f.FullName,
                            FileSize = f.Length
                        });
                    }

                    // Add study to UI collection
                    var study = _monitorService.Studies
                        .FirstOrDefault(st => st.StudyInstanceUid == args.StudyInstanceUid);
                    if (study != null && !Studies.Contains(study))
                        Studies.Insert(0, study);

                    AddLog($"Service study detected: {args.PatientName} — {allFiles.Count} images");
                }
                catch (Exception ex)
                {
                    AddLog($"Scan error ({studyDir.Name}): {ex.Message}");
                }
            }
        }
        catch
        {
            // Folder access error — skip this tick
        }
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
        _uiTimer.Stop();
        StopScp();
        _scpService.Dispose();
        _monitorService.Dispose();
    }

    private static string L(string key) => LocalizationHelper.Get(key);
}
