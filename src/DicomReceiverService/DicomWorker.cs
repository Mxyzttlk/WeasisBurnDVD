using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using FellowOakDicom.Network;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DicomReceiverService;

public class DicomWorker : BackgroundService
{
    private readonly ILogger<DicomWorker> _logger;
    private IDicomServer? _server;

    public DicomWorker(ILogger<DicomWorker> logger)
    {
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var settingsService = new SettingsService();
        var settings = settingsService.Load();

        _logger.LogInformation(
            "Starting DICOM SCP — AE: {AeTitle}, Port: {Port}, Folder: {Folder}",
            settings.AeTitle, settings.Port, settings.IncomingFolder);

        Directory.CreateDirectory(settings.IncomingFolder);

        CStoreScp.IncomingFolder = settings.IncomingFolder;
        CStoreScp.ExpectedAeTitle = settings.AeTitle;
        CStoreScp.OnFileReceived = args =>
        {
            _logger.LogInformation(
                "Received: {Patient} — {Modality} [{Study}]",
                args.PatientName, args.Modality, args.StudyInstanceUid[..Math.Min(8, args.StudyInstanceUid.Length)]);
        };
        CStoreScp.OnLog = msg => _logger.LogInformation("{Message}", msg);

        _server = DicomServerFactory.Create<CStoreScp>(settings.Port);
        _logger.LogInformation("DICOM SCP started on port {Port}", settings.Port);

        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown
        }
    }

    public override Task StopAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Stopping DICOM SCP...");

        if (_server != null)
        {
            _server.Dispose();
            _server = null;
        }

        CStoreScp.OnFileReceived = null;
        CStoreScp.OnLog = null;

        _logger.LogInformation("DICOM SCP stopped");
        return base.StopAsync(cancellationToken);
    }
}
