using System.Collections.Specialized;
using System.Windows;
using DicomReceiver.ViewModels;

namespace DicomReceiver;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Loaded += MainWindow_Loaded;
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
        }
    }

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (DataContext is MainViewModel vm)
            vm.Shutdown();
    }
}
