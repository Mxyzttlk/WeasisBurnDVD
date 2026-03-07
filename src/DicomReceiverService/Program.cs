using DicomReceiverService;
using FellowOakDicom;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.EventLog;

// Disable fo-dicom VR CS validation — allows .DCM extension in DICOMDIR paths
// (PACS uses .DCM, Siemens imports fine, but fo-dicom rejects the dot character)
new DicomSetupBuilder()
    .SkipValidation()
    .Build();

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "DicomReceiverService";
});

builder.Logging.ClearProviders();
builder.Logging.AddEventLog(new EventLogSettings
{
    SourceName = "DicomReceiverService",
    LogName = "Application"
});
// Console logging for debug (visible when running as console app)
builder.Logging.AddConsole();

builder.Services.AddHostedService<DicomWorker>();

var host = builder.Build();
host.Run();
