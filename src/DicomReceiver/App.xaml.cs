using System.Windows;
using FellowOakDicom;

namespace DicomReceiver;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Disable VR CS validation globally — fo-dicom rejects dots in DICOM filenames
        // (e.g., 00000000.DCM) but PACS uses .DCM extension and Siemens imports fine.
        // Must be called ONCE at startup, not per-burn (it's a global static config).
        new DicomSetupBuilder()
            .SkipValidation()
            .Build();
    }
}
