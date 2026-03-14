using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
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
    public string BurnSelectedLabel => L("BurnSelected");

    // Multi-study burn selection info (recalculated by DispatcherTimer every 1s)
    private string _selectedStudiesInfo = "";
    public string SelectedStudiesInfo
    {
        get => _selectedStudiesInfo;
        set => SetProperty(ref _selectedStudiesInfo, value);
    }

    private bool _hasSelectedStudies;
    public bool HasSelectedStudies
    {
        get => _hasSelectedStudies;
        set => SetProperty(ref _hasSelectedStudies, value);
    }

    private bool _hasMultipleSelectedStudies;
    public bool HasMultipleSelectedStudies
    {
        get => _hasMultipleSelectedStudies;
        set => SetProperty(ref _hasMultipleSelectedStudies, value);
    }

    public event EventHandler? LanguageChanged;
    public event EventHandler? RequestClearSelection;

    public string AnonymizeTooltip => L("AnonymizeTooltip");
    public string HideAllTooltip => L("HideAllTooltip");

    // Toolbar privacy state for multi-selection — reflects ALL selected Complete studies
    // Active = all selected Complete studies have that mode; mixed = inactive
    private bool _selectedAnonymizeActive;
    public bool SelectedAnonymizeActive
    {
        get => _selectedAnonymizeActive;
        set => SetProperty(ref _selectedAnonymizeActive, value);
    }

    private bool _selectedHideAllActive;
    public bool SelectedHideAllActive
    {
        get => _selectedHideAllActive;
        set => SetProperty(ref _selectedHideAllActive, value);
    }

    public ICommand ToggleScpCommand { get; }
    public ICommand OpenSettingsCommand { get; }
    public ICommand BurnStudyCommand { get; }
    public ICommand BurnSelectedCommand { get; }
    public ICommand DeleteStudyCommand { get; }
    public ICommand DeleteAllCommand { get; }
    public ICommand ClearLogCommand { get; }
    public ICommand ToggleExpandCommand { get; }
    public ICommand DeleteSeriesCommand { get; }
    public ICommand ToggleAnonymizeStudyCommand { get; }
    public ICommand ToggleHideAllStudyCommand { get; }
    public ICommand ToggleAnonymizeSelectedCommand { get; }
    public ICommand ToggleHideAllSelectedCommand { get; }

    public MainViewModel()
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
        _settings = _settingsService.Load();

        LocalizationHelper.SetLanguage(_settings.Language);

        ToggleScpCommand = new RelayCommand(ToggleScp);
        OpenSettingsCommand = new RelayCommand(OpenSettings);
        BurnStudyCommand = new RelayCommand(BurnStudy);
        BurnSelectedCommand = new RelayCommand(BurnSelected);
        DeleteStudyCommand = new RelayCommand(DeleteStudy);
        DeleteAllCommand = new RelayCommand(DeleteAll);
        ClearLogCommand = new RelayCommand(() => LogEntries.Clear());
        ToggleExpandCommand = new RelayCommand(ToggleExpand);
        DeleteSeriesCommand = new RelayCommand(DeleteSeries);
        ToggleAnonymizeStudyCommand = new RelayCommand(ToggleAnonymizeStudy);
        ToggleHideAllStudyCommand = new RelayCommand(ToggleHideAllStudy);
        ToggleAnonymizeSelectedCommand = new RelayCommand(ToggleAnonymizeSelected);
        ToggleHideAllSelectedCommand = new RelayCommand(ToggleHideAllSelected);

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
                {
                    Studies.Insert(0, study);
                    // Mark folder as known so ScanIncomingFolder() won't re-process it
                    if (!string.IsNullOrEmpty(study.StoragePath))
                        _knownStudyDirs.Add(Path.GetFileName(study.StoragePath));
                }
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
            UpdateSelectedStudiesInfo();
            _monitorService.UpdateElapsedTimes();
            AutoPurgeOldStudies();
        };
        _uiTimer.Start();

        // Auto-start SCP
        StartScp();

        // Scan incoming folder for existing studies from previous session.
        // In service mode, ScanIncomingFolder() runs every tick — but the first scan
        // won't happen until the timer fires (1 sec). This call ensures immediate discovery.
        // In non-service mode, ScanIncomingFolder() is NOT called from the timer,
        // so this is the ONLY way to discover leftover studies from a previous run.
        ScanIncomingFolder();
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
            OnPropertyChanged(nameof(BurnSelectedLabel));
            OnPropertyChanged(nameof(AnonymizeTooltip));
            OnPropertyChanged(nameof(HideAllTooltip));

            LanguageChanged?.Invoke(this, EventArgs.Empty);
            AddLog(L("RestartRequired"));
        }
    }

    private async void BurnStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;
        if (study.Status != StudyStatus.Complete) return;

        // Set Burning IMMEDIATELY (before any await) to prevent double-click race
        study.Status = StudyStatus.Burning;

        try
        {
            // Pre-burn disc check — poll IMAPI2 for blank media (max 30 sec)
            if (!await WaitForDisc(study)) return;

            await _burnService.BurnStudyAsync(study, _settings);

            // Auto-delete from queue after successful burn
            if (_settings.AutoDeleteAfterBurn && study.Status == StudyStatus.Done)
            {
                Studies.Remove(study);
                _monitorService.RemoveStudy(study.StudyInstanceUid);
                _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath));
                AddLog($"Auto-deleted: {study.PatientName}");
            }
        }
        catch (Exception ex)
        {
            study.Status = StudyStatus.Complete; // retryable
            study.StatusText = $"Error: {ex.Message}";
            AddLog($"Burn error: {ex.Message}");
        }
    }

    private async void BurnSelected()
    {
        var selected = Studies
            .Where(s => s.IsSelected && s.Status == StudyStatus.Complete)
            .ToList();

        if (selected.Count == 0) return;

        try
        {
            // Confirm multi-burn
            var totalSizeMB = selected.Sum(s => s.TotalSizeBytes) / (1024.0 * 1024.0);
            var patients = selected.Select(s => s.PatientName).Distinct().ToList();
            var label = patients.Count == 1 ? patients[0] : L("MultiplePatientsLabel");

            var msg = string.Format(L("ConfirmBurnMultiple"), selected.Count, $"{totalSizeMB:F1} MB", label);
            var result = MessageBox.Show(msg, L("BurnSelected"),
                MessageBoxButton.YesNo, MessageBoxImage.Question);

            if (result != MessageBoxResult.Yes) return;

            // Pre-burn disc check — poll IMAPI2 for blank media (max 30 sec)
            // Pass ALL selected studies so they all get Burning status (prevents AutoPurge/deletion)
            if (!await WaitForDisc(selected)) return;

            // Clear DataGrid selection before burning (prevents re-click)
            RequestClearSelection?.Invoke(this, EventArgs.Empty);

            await _burnService.BurnMultipleStudiesAsync(selected, _settings);

            // Auto-delete burned studies from queue
            if (_settings.AutoDeleteAfterBurn)
            {
                foreach (var study in selected.Where(s => s.Status == StudyStatus.Done))
                {
                    Studies.Remove(study);
                    _monitorService.RemoveStudy(study.StudyInstanceUid);
                    _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath));
                    AddLog($"Auto-deleted: {study.PatientName}");
                }
            }
        }
        catch (Exception ex)
        {
            foreach (var study in selected.Where(s => s.Status == StudyStatus.Burning))
            {
                study.Status = StudyStatus.Complete; // retryable
                study.StatusText = L("Complete");
            }
            AddLog($"Burn error: {ex.Message}");
        }
    }

    /// <summary>
    /// Polls IMAPI2 for blank disc every 2 seconds (max 30 sec).
    /// Shows "Waiting for disc..." in study StatusText during polling.
    /// Returns true if disc detected, false if timeout (studies revert to Complete).
    /// Marks ALL passed studies as Burning to prevent AutoPurge/deletion during wait.
    /// </summary>
    private async Task<bool> WaitForDisc(ReceivedStudy study) => await WaitForDisc(new List<ReceivedStudy> { study });

    private async Task<bool> WaitForDisc(List<ReceivedStudy> studies)
    {
        // Mark ALL studies as Burning — prevents AutoPurge and user deletion during wait
        foreach (var s in studies)
        {
            s.Status = StudyStatus.Burning;
            s.StatusText = L("WaitingForDisc");
        }
        AddLog(L("WaitingForDisc"));

        bool discReady = false;
        string driveName = "";

        // Poll every 2 sec, max 15 attempts = 30 sec
        for (int i = 0; i < 15; i++)
        {
            (discReady, driveName) = _burnService.CheckDiscReady(_settings);
            if (discReady) break;

            // Update status with countdown
            var remaining = (15 - i) * 2;
            foreach (var s in studies)
                s.StatusText = $"{L("WaitingForDisc")} ({remaining}s)";

            await Task.Delay(2000);
        }

        if (discReady)
        {
            var msg = string.Format(L("DiscDetected"), driveName);
            AddLog(msg);
            // Status stays Burning — BurnStudyAsync/BurnMultipleStudiesAsync will continue
            return true;
        }

        // Timeout — revert ALL studies to Complete for retry
        foreach (var s in studies)
        {
            s.Status = StudyStatus.Complete;
            s.StatusText = string.Format(L("DiscNotFound"), driveName);
        }
        AddLog(string.Format(L("DiscNotFound"), driveName));
        return false;
    }

    /// <summary>
    /// Recalculates SelectedStudiesInfo and HasSelectedStudies from DataGrid selection.
    /// Called from two sources:
    ///   1. Immediately from SelectionChanged handler (via code-behind) — instant UI feedback
    ///   2. Every 1 second from DispatcherTimer — catches status changes (Complete→Burning)
    /// IsSelected is synced by DataGrid.SelectionChanged handler in code-behind.
    /// Only Complete studies count for burn — others are ignored (but remain visually selected).
    /// </summary>
    public void UpdateSelectedStudiesInfo()
    {
        int count = 0;
        long totalBytes = 0;
        int anonymizeCount = 0;
        int hideAllCount = 0;

        foreach (var study in Studies)
        {
            if (study.IsSelected && study.Status == StudyStatus.Complete)
            {
                count++;
                totalBytes += study.TotalSizeBytes;
                if (study.PrivacyMode == DicomPrivacyMode.Anonymize) anonymizeCount++;
                else if (study.PrivacyMode == DicomPrivacyMode.HideAll) hideAllCount++;
            }
        }

        HasSelectedStudies = count > 0;
        HasMultipleSelectedStudies = count > 1;

        // Toolbar privacy buttons: active only when ALL selected Complete studies have that mode
        SelectedAnonymizeActive = count > 0 && anonymizeCount == count;
        SelectedHideAllActive = count > 0 && hideAllCount == count;

        if (count == 0)
        {
            SelectedStudiesInfo = "";
        }
        else
        {
            var sizeStr = totalBytes < 1024 * 1024 * 1024
                ? $"{totalBytes / (1024.0 * 1024.0):F1} MB"
                : $"{totalBytes / (1024.0 * 1024.0 * 1024.0):F2} GB";
            SelectedStudiesInfo = string.Format(L("SelectedStudiesInfo"), count, sizeStr);
        }
    }

    private void ToggleAnonymizeStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;
        if (study.Status != StudyStatus.Complete) return; // Only toggle on Complete studies
        study.PrivacyMode = study.PrivacyMode == DicomPrivacyMode.Anonymize
            ? DicomPrivacyMode.None
            : DicomPrivacyMode.Anonymize;
    }

    private void ToggleHideAllStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;
        if (study.Status != StudyStatus.Complete) return; // Only toggle on Complete studies
        study.PrivacyMode = study.PrivacyMode == DicomPrivacyMode.HideAll
            ? DicomPrivacyMode.None
            : DicomPrivacyMode.HideAll;
    }

    /// <summary>
    /// Toolbar toggle: applies Anonymize to ALL selected Complete studies.
    /// If all selected already have Anonymize → removes it (toggles to None).
    /// </summary>
    private void ToggleAnonymizeSelected()
    {
        var selected = Studies
            .Where(s => s.IsSelected && s.Status == StudyStatus.Complete)
            .ToList();
        if (selected.Count == 0) return;

        // If all selected are already Anonymize → toggle OFF, else toggle ON
        var newMode = selected.All(s => s.PrivacyMode == DicomPrivacyMode.Anonymize)
            ? DicomPrivacyMode.None
            : DicomPrivacyMode.Anonymize;

        foreach (var study in selected)
            study.PrivacyMode = newMode;

        UpdateSelectedStudiesInfo(); // Refresh toolbar button state immediately
    }

    /// <summary>
    /// Toolbar toggle: applies HideAll to ALL selected Complete studies.
    /// If all selected already have HideAll → removes it (toggles to None).
    /// </summary>
    private void ToggleHideAllSelected()
    {
        var selected = Studies
            .Where(s => s.IsSelected && s.Status == StudyStatus.Complete)
            .ToList();
        if (selected.Count == 0) return;

        var newMode = selected.All(s => s.PrivacyMode == DicomPrivacyMode.HideAll)
            ? DicomPrivacyMode.None
            : DicomPrivacyMode.HideAll;

        foreach (var study in selected)
            study.PrivacyMode = newMode;

        UpdateSelectedStudiesInfo();
    }

    private void ToggleExpand(object? param)
    {
        if (param is ReceivedStudy study)
            study.IsExpanded = !study.IsExpanded;
    }

    private void DeleteSeries(object? param)
    {
        if (param is not ReceivedSeries series) return;

        // Find parent study
        var study = Studies.FirstOrDefault(s => s.Series.Contains(series));
        if (study == null) return;

        var result = MessageBox.Show(
            L("ConfirmDeleteSeries"),
            L("Delete"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (result != MessageBoxResult.Yes) return;

        // Delete series folder from disk
        try
        {
            if (Directory.Exists(series.StoragePath))
                Directory.Delete(series.StoragePath, true);
        }
        catch (Exception ex)
        {
            AddLog($"Delete series error: {ex.Message}");
        }

        // Remove from monitor + recalculate study totals
        _monitorService.RemoveSeries(study, series);

        AddLog($"{L("SeriesDeleted")}: {series.Modality} ({series.ImageCount} img)");

        // If no series remain, remove entire study
        if (study.Series.Count == 0)
        {
            try
            {
                if (Directory.Exists(study.StoragePath))
                    Directory.Delete(study.StoragePath, true);
            }
            catch { }

            Studies.Remove(study);
            _monitorService.RemoveStudy(study.StudyInstanceUid);
            _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath));
            AddLog($"Deleted empty study: {study.PatientName}");
        }
    }

    private void DeleteStudy(object? param)
    {
        if (param is not ReceivedStudy study) return;
        if (study.Status == StudyStatus.Burning || study.Status == StudyStatus.Receiving) return;

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
        _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath));
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
            if (study.Status == StudyStatus.Burning || study.Status == StudyStatus.Receiving) continue;
            try
            {
                if (Directory.Exists(study.StoragePath))
                    Directory.Delete(study.StoragePath, true);
            }
            catch { }
            Studies.Remove(study);
            _monitorService.RemoveStudy(study.StudyInstanceUid);
            _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath));
        }
        AddLog(L("DeleteAll"));
    }

    /// <summary>
    /// Auto-purge ONE oldest study per tick when count exceeds MaxStudiesKeep.
    /// Runs every 1 second from DispatcherTimer — lightweight: exits immediately if disabled or under limit.
    /// Priority: Done/Error first (already burned/failed), then Complete (not yet burned).
    /// NEVER purges Receiving or Burning studies.
    /// MAX 1 purge per tick — prevents UI freeze from multiple Directory.Delete calls.
    /// At 1 purge/sec, 10 excess studies clear in 10 seconds — perfectly adequate.
    /// </summary>
    private void AutoPurgeOldStudies()
    {
        // AutoDelete ON → studies removed immediately after burn, purge not needed
        if (_settings.AutoDeleteAfterBurn) return;
        if (_settings.MaxStudiesKeep <= 0) return;
        if (Studies.Count <= _settings.MaxStudiesKeep) return;

        // Priority 1: Find oldest Done/Error study (already burned or failed — safest to delete)
        ReceivedStudy? oldest = null;
        foreach (var s in Studies)
        {
            if (s.Status != StudyStatus.Done && s.Status != StudyStatus.Error) continue;
            if (oldest == null || s.LastFileReceivedTime < oldest.LastFileReceivedTime)
                oldest = s;
        }

        // Priority 2: If no Done/Error available, purge oldest Complete study
        // (not yet burned, but disk space limit takes priority)
        if (oldest == null)
        {
            foreach (var s in Studies)
            {
                if (s.Status != StudyStatus.Complete) continue;
                if (oldest == null || s.LastFileReceivedTime < oldest.LastFileReceivedTime)
                    oldest = s;
            }
        }

        if (oldest == null) return; // Only Receiving/Burning remain — can't purge

        // Delete files from disk (may already be deleted by BurnService for Done studies)
        try
        {
            if (Directory.Exists(oldest.StoragePath))
                Directory.Delete(oldest.StoragePath, true);
        }
        catch { }

        Studies.Remove(oldest);
        _monitorService.RemoveStudy(oldest.StudyInstanceUid);
        _knownStudyDirs.Remove(Path.GetFileName(oldest.StoragePath));
        AddLog($"Auto-purged: {oldest.PatientName}");
    }

    /// <summary>
    /// Scans the incoming folder for study directories on startup and in service mode.
    /// Handles TWO directory layouts:
    ///   1. Original: incoming/{StudyUID}/{SeriesUID}/{SOP}.dcm (from DicomScpService)
    ///   2. DIR000:   incoming/{StudyUID}/DIR000/00000000/00000000.DCM (after RestructureInPlace)
    ///
    /// Metadata priority:
    ///   1. study-info.json (saved by BurnService before privacy mode — survives HideAll)
    ///   2. DICOM file headers (may have PatientName removed by HideAll)
    ///
    /// OPTIMIZATION: reads only ONE DICOM header per series (not per file).
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

                // Find any .dcm file to confirm this is a study folder
                var firstDcmFile = studyDir.EnumerateFiles("*.dcm", SearchOption.AllDirectories).FirstOrDefault();
                if (firstDcmFile == null) continue; // Empty directory, skip for now

                _knownStudyDirs.Add(studyDir.Name);

                // Check if study already exists in monitor (e.g., from PACS download import).
                // Skip re-processing to avoid resetting Complete→Receiving.
                var existingStudy = _monitorService.Studies
                    .FirstOrDefault(st => st.StudyInstanceUid == studyDir.Name);
                if (existingStudy != null &&
                    (existingStudy.Status == StudyStatus.Complete ||
                     existingStudy.Status == StudyStatus.Burning ||
                     existingStudy.Status == StudyStatus.Done))
                {
                    existingStudy.StoragePath = studyDir.FullName;
                    if (!Studies.Contains(existingStudy))
                        Studies.Insert(0, existingStudy);
                    AddLog($"Study detected: {existingStudy.PatientName} — {existingStudy.ImageCount} images (already complete)");
                    continue;
                }

                try
                {
                    // ============================================================
                    // Step 1: Get study-level metadata
                    // Priority: study-info.json > DICOM header
                    // study-info.json is saved by BurnService BEFORE privacy mode
                    // so it preserves PatientName even after HideAll removes tags.
                    // ============================================================
                    string studyUid = studyDir.Name;
                    string patientName = "Unknown";
                    string patientId = "";
                    string studyDate = "";
                    string defaultModality = "OT";

                    var studyInfoPath = Path.Combine(studyDir.FullName, "study-info.json");
                    if (File.Exists(studyInfoPath))
                    {
                        try
                        {
                            var json = File.ReadAllText(studyInfoPath);
                            var info = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(json);
                            if (info != null)
                            {
                                if (info.TryGetValue("PatientName", out var pn) && !string.IsNullOrEmpty(pn))
                                    patientName = pn;
                                if (info.TryGetValue("PatientId", out var pid))
                                    patientId = pid;
                                if (info.TryGetValue("StudyDate", out var sd))
                                    studyDate = sd;
                                if (info.TryGetValue("Modality", out var mod) && !string.IsNullOrEmpty(mod))
                                    defaultModality = mod;
                                if (info.TryGetValue("StudyInstanceUid", out var uid) && !string.IsNullOrEmpty(uid))
                                    studyUid = uid;
                            }
                        }
                        catch { /* Fall through to DICOM header */ }
                    }

                    // Fallback: read from DICOM header (may be missing after HideAll)
                    if (patientName == "Unknown")
                    {
                        try
                        {
                            var dicom = DicomFile.Open(firstDcmFile.FullName, FileReadOption.SkipLargeTags);
                            var ds = dicom.Dataset;
                            studyUid = ds.GetSingleValueOrDefault(DicomTag.StudyInstanceUID, studyDir.Name);
                            var dcmPatient = ds.GetSingleValueOrDefault(DicomTag.PatientName, "");
                            if (!string.IsNullOrEmpty(dcmPatient))
                                patientName = dcmPatient;
                            patientId = ds.GetSingleValueOrDefault(DicomTag.PatientID, patientId);
                            studyDate = ds.GetSingleValueOrDefault(DicomTag.StudyDate, studyDate);
                            var dcmModality = ds.GetSingleValueOrDefault(DicomTag.Modality, "");
                            if (!string.IsNullOrEmpty(dcmModality))
                                defaultModality = dcmModality;
                        }
                        catch { /* Use whatever metadata we have */ }
                    }

                    int totalFiles = 0;

                    // ============================================================
                    // Step 2: Detect directory layout and process series
                    // DIR000 layout: study/DIR000/00000000/00000000.DCM
                    // Original layout: study/{SeriesUID}/{SOP}.dcm
                    // ============================================================
                    var dir000 = new DirectoryInfo(Path.Combine(studyDir.FullName, "DIR000"));
                    bool isDir000Layout = dir000.Exists;

                    if (isDir000Layout)
                    {
                        // DIR000 layout — each subdirectory of DIR000 is a series
                        foreach (var seriesDir in dir000.GetDirectories())
                        {
                            var seriesFiles = seriesDir.GetFiles("*.dcm", SearchOption.AllDirectories);
                            if (seriesFiles.Length == 0) continue;

                            var seriesUid = seriesDir.Name;
                            var modality = defaultModality;
                            var seriesDesc = "";
                            try
                            {
                                var seriesDicom = DicomFile.Open(seriesFiles[0].FullName, FileReadOption.SkipLargeTags);
                                seriesUid = seriesDicom.Dataset.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, seriesUid);
                                modality = seriesDicom.Dataset.GetSingleValueOrDefault(DicomTag.Modality, modality);
                                seriesDesc = seriesDicom.Dataset.GetSingleValueOrDefault(DicomTag.SeriesDescription, "");
                            }
                            catch { /* use folder name as series UID */ }

                            foreach (var f in seriesFiles)
                            {
                                _monitorService.OnFileReceived(new FileReceivedEventArgs
                                {
                                    StudyInstanceUid = studyUid,
                                    PatientName = patientName,
                                    PatientId = patientId,
                                    StudyDate = studyDate,
                                    Modality = modality,
                                    SeriesInstanceUid = seriesUid,
                                    SeriesDescription = seriesDesc,
                                    FilePath = f.FullName,
                                    FileSize = f.Length
                                });
                                totalFiles++;
                            }
                        }
                    }
                    else
                    {
                        // Original layout — each subdirectory is a series
                        foreach (var seriesDir in studyDir.GetDirectories())
                        {
                            var seriesFiles = seriesDir.GetFiles("*.dcm", SearchOption.AllDirectories);
                            if (seriesFiles.Length == 0) continue;

                            var seriesUid = seriesDir.Name;
                            var modality = defaultModality;
                            var seriesDesc = "";
                            try
                            {
                                var seriesDicom = DicomFile.Open(seriesFiles[0].FullName, FileReadOption.SkipLargeTags);
                                seriesUid = seriesDicom.Dataset.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, seriesUid);
                                modality = seriesDicom.Dataset.GetSingleValueOrDefault(DicomTag.Modality, modality);
                                seriesDesc = seriesDicom.Dataset.GetSingleValueOrDefault(DicomTag.SeriesDescription, "");
                            }
                            catch { /* use folder name as series UID */ }

                            foreach (var f in seriesFiles)
                            {
                                _monitorService.OnFileReceived(new FileReceivedEventArgs
                                {
                                    StudyInstanceUid = studyUid,
                                    PatientName = patientName,
                                    PatientId = patientId,
                                    StudyDate = studyDate,
                                    Modality = modality,
                                    SeriesInstanceUid = seriesUid,
                                    SeriesDescription = seriesDesc,
                                    FilePath = f.FullName,
                                    FileSize = f.Length
                                });
                                totalFiles++;
                            }
                        }

                        // Handle .dcm files directly in study root (no series subdirectory)
                        var rootFiles = studyDir.GetFiles("*.dcm", SearchOption.TopDirectoryOnly);
                        if (rootFiles.Length > 0)
                        {
                            string rootSeriesUid = "ROOT";
                            var rootModality = defaultModality;
                            var rootSeriesDesc = "";
                            try
                            {
                                var rootDicom = DicomFile.Open(rootFiles[0].FullName, FileReadOption.SkipLargeTags);
                                rootSeriesUid = rootDicom.Dataset.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, rootSeriesUid);
                                rootModality = rootDicom.Dataset.GetSingleValueOrDefault(DicomTag.Modality, rootModality);
                                rootSeriesDesc = rootDicom.Dataset.GetSingleValueOrDefault(DicomTag.SeriesDescription, "");
                            }
                            catch { }

                            foreach (var f in rootFiles)
                            {
                                _monitorService.OnFileReceived(new FileReceivedEventArgs
                                {
                                    StudyInstanceUid = studyUid,
                                    PatientName = patientName,
                                    PatientId = patientId,
                                    StudyDate = studyDate,
                                    Modality = rootModality,
                                    SeriesInstanceUid = rootSeriesUid,
                                    SeriesDescription = rootSeriesDesc,
                                    FilePath = f.FullName,
                                    FileSize = f.Length
                                });
                                totalFiles++;
                            }
                        }
                    }

                    // ============================================================
                    // Step 3: Fix StoragePath — must point to study root, not DIR000
                    // StudyMonitorService.OnFileReceived() computes StoragePath by
                    // going up 2 levels from FilePath. For DIR000 layout, this
                    // results in study/DIR000 instead of study/. Fix it here.
                    // ============================================================
                    var study = _monitorService.Studies
                        .FirstOrDefault(st => st.StudyInstanceUid == studyUid);
                    if (study != null)
                    {
                        // Always set StoragePath to the study root directory
                        study.StoragePath = studyDir.FullName;

                        if (!Studies.Contains(study))
                            Studies.Insert(0, study);
                    }

                    AddLog($"Study detected: {patientName} — {totalFiles} images");
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

    /// <summary>Public wrapper for external log access (e.g. PacsViewModel).</summary>
    public void AddLogExternal(string message)
    {
        _dispatcher.BeginInvoke(() => AddLog(message));
    }

    /// <summary>
    /// Factory: creates PacsViewModel sharing the same services.
    /// Called from MainWindow.xaml.cs on first PACS tab selection (lazy init).
    /// </summary>
    public PacsViewModel CreatePacsViewModel()
    {
        var projectRoot = FindProjectRoot();
        var downloadFolder = Path.Combine(projectRoot, "downloads");
        Directory.CreateDirectory(downloadFolder);

        var incomingFolder = string.IsNullOrEmpty(_settings.IncomingFolder)
            ? Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "incoming")
            : _settings.IncomingFolder;

        var downloadService = new PacsDownloadService(_monitorService, downloadFolder, incomingFolder);

        // Note: PacsDownloadService.LogMessage is subscribed by PacsViewModel._onLogMessage
        // → PacsViewModel.LogMessage → MainWindow.xaml.cs → AddLogExternal(). No direct sub here.

        downloadService.DownloadCompleted += (_, e) =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                if (e.Success)
                {
                    AddLog($"PACS download processed: {e.FileName} ({e.SizeBytes / (1024.0 * 1024.0):F1} MB) — {e.ImageCount} images");
                    ScanIncomingFolder();
                }
                else
                {
                    AddLog($"PACS download error: {e.Error}");
                }
            });
        };

        var pacsVm = new PacsViewModel(downloadService, _settingsService, _settings);

        // Wire BURN DVD button — find study by UID and trigger burn
        pacsVm.BurnRequested += async (_, studyUid) =>
        {
            await _dispatcher.InvokeAsync(async () =>
            {
                var study = Studies.FirstOrDefault(s => s.StudyInstanceUid == studyUid);
                if (study != null && study.Status == StudyStatus.Complete)
                {
                    // Call BurnStudy directly (not via command) so we can await + notify PACS
                    // Skip WaitForDisc — burn-gui.ps1 has its own disc check UI with retry button
                    study.Status = StudyStatus.Burning;
                    try
                    {
                        await _burnService.BurnStudyAsync(study, _settings);

                        bool burnSuccess = study.Status == StudyStatus.Done;

                        // PACS flow: always clean up after burn completes or is cancelled
                        // Once burn-gui.ps1 closes (success OR Close/X), download is consumed
                        // BurnService may have already deleted incoming on success (AutoDelete)
                        try
                        {
                            if (!string.IsNullOrEmpty(study.StoragePath) && Directory.Exists(study.StoragePath))
                                Directory.Delete(study.StoragePath, true);
                        }
                        catch { }

                        Studies.Remove(study);
                        _monitorService.RemoveStudy(study.StudyInstanceUid);
                        _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath ?? ""));
                        AddLog(burnSuccess
                            ? $"Burned: {study.PatientName}"
                            : $"Burn cancelled: {study.PatientName}");

                        pacsVm.OnBurnCompleted(burnSuccess);

                        if (burnSuccess)
                            ForceForeground();
                    }
                    catch (Exception ex)
                    {
                        // Exception (not exit code 1) — also clean up
                        try
                        {
                            if (!string.IsNullOrEmpty(study.StoragePath) && Directory.Exists(study.StoragePath))
                                Directory.Delete(study.StoragePath, true);
                        }
                        catch { }

                        Studies.Remove(study);
                        _monitorService.RemoveStudy(study.StudyInstanceUid);
                        _knownStudyDirs.Remove(Path.GetFileName(study.StoragePath ?? ""));
                        AddLog($"Burn error: {ex.Message}");
                        pacsVm.OnBurnCompleted(false);
                    }
                }
                else if (study != null)
                {
                    AddLog($"Study not ready for burn: {study.PatientName} ({study.Status})");
                    pacsVm.OnBurnCompleted(false);
                }
                else
                {
                    AddLog("Study not found in queue — try switching to DICOM Queue tab");
                    pacsVm.OnBurnCompleted(false);
                }
            });
        };

        return pacsVm;
    }

    private static string FindProjectRoot()
    {
        // Walk up from exe directory to find project root (where scripts/ exists)
        var dir = AppDomain.CurrentDomain.BaseDirectory;
        for (int i = 0; i < 6; i++)
        {
            if (Directory.Exists(Path.Combine(dir, "scripts")))
                return dir;
            var parent = Directory.GetParent(dir);
            if (parent == null) break;
            dir = parent.FullName;
        }
        // Fallback
        return @"E:\Weasis Burn";
    }

    public void Shutdown()
    {
        _uiTimer.Stop();
        StopScp();
        _scpService.Dispose();
        _monitorService.Dispose();
    }

    private static string L(string key) => LocalizationHelper.Get(key);

    // ========================================================================
    // WIN32 FOCUS — bypass Windows foreground lock after burn process exits
    // Mirrors PS pacs-burner.ps1 Win32Focus (AttachThreadInput + SetForegroundWindow)
    // ========================================================================

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

    private static void ForceForeground()
    {
        var mainWindow = Application.Current?.MainWindow;
        if (mainWindow == null) return;

        var hwnd = new WindowInteropHelper(mainWindow).Handle;
        if (hwnd == IntPtr.Zero) return;

        var fgHwnd = GetForegroundWindow();
        if (fgHwnd == hwnd) { mainWindow.Activate(); return; }

        var fgThread = GetWindowThreadProcessId(fgHwnd, out _);
        var myThread = GetCurrentThreadId();

        if (fgThread != myThread)
        {
            AttachThreadInput(fgThread, myThread, true);
            ShowWindow(hwnd, 9); // SW_RESTORE
            SetForegroundWindow(hwnd);
            AttachThreadInput(fgThread, myThread, false);
        }
        else
        {
            SetForegroundWindow(hwnd);
        }

        mainWindow.Activate();
    }
}
