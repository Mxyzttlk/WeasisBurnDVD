using System.Collections.Specialized;
using System.Windows;
using DicomReceiver.Helpers;
using DicomReceiver.ViewModels;

namespace DicomReceiver;

public partial class MainWindow : Window
{
    private static string L(string key) => LocalizationHelper.Get(key);

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
        }
    }

    private void ApplyLocalization()
    {
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
        if (DataContext is MainViewModel vm)
            vm.Shutdown();
    }
}
