using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using DicomReceiver.Helpers;
using DicomReceiver.Models;
using DicomReceiver.ViewModels;

namespace DicomReceiver;

public partial class MainWindow : Window
{
    private static string L(string key) => LocalizationHelper.Get(key);
    private PacsViewModel? _pacsViewModel;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += MainWindow_Loaded;
        ApplyLocalization();
    }

    private void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        // Auto-scroll log to bottom
        if (DataContext is MainViewModel vm)
        {
            ((INotifyCollectionChanged)vm.LogEntries).CollectionChanged += (s, ev) =>
            {
                if (LogListBox.Items.Count > 0)
                    LogListBox.ScrollIntoView(LogListBox.Items[LogListBox.Items.Count - 1]);
            };

            vm.LanguageChanged += (s, ev) => ApplyLocalization();

            // Clear DataGrid selection when ViewModel requests it (after burn completes)
            vm.RequestClearSelection += (s, ev) => StudyGrid.SelectedItems.Clear();
        }
    }

    private void StudyGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Sync DataGrid native selection → model IsSelected (delta-based, efficient)
        foreach (var item in e.RemovedItems)
        {
            if (item is ReceivedStudy study)
                study.IsSelected = false;
        }

        foreach (var item in e.AddedItems)
        {
            if (item is ReceivedStudy study)
                study.IsSelected = true;
        }

        // Update selection info immediately (not waiting for 1s timer)
        if (DataContext is MainViewModel vm)
            vm.UpdateSelectedStudiesInfo();
    }

    private void MainTabControl_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (e.Source != MainTabControl) return;

        // Lazy-init PacsViewModel when PACS tab first selected
        if (MainTabControl.SelectedItem == TabPacs && _pacsViewModel == null)
        {
            if (DataContext is MainViewModel mainVm)
            {
                _pacsViewModel = mainVm.CreatePacsViewModel();
                PacsBrowserView.DataContext = _pacsViewModel;

                // Route PACS log messages to shared log panel
                _pacsViewModel.LogMessage += (s, msg) =>
                {
                    mainVm.AddLogExternal(msg);
                };
            }
        }
    }

    private void ApplyLocalization()
    {
        // Tab headers
        TxtQueueTab.Text = L("TabQueue");
        TxtPacsTab.Text = L("TabPacs");

        // Toolbar
        TxtSettingsLabel.Text = L("Settings");
        BtnDeleteAll.Content = L("DeleteAll");

        // DataGrid column headers
        ColPatient.Header = L("PatientName");
        ColStudyDate.Header = L("StudyDate");
        ColModality.Header = L("Modality");
        ColSeries.Header = L("Series");
        ColImages.Header = L("Images");
        ColSize.Header = L("Size");
        ColStatus.Header = L("Status");

        // Log panel
        TxtLogLabel.Text = L("Log");
        BtnClearLog.Content = L("ClearLog");
    }

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        _pacsViewModel?.Dispose();

        if (DataContext is MainViewModel vm)
            vm.Shutdown();
    }
}
