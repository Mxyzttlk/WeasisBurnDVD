using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using FellowOakDicom;
using FellowOakDicom.Network;

namespace DicomReceiver.Services;

public class FileReceivedEventArgs : EventArgs
{
    public required string StudyInstanceUid { get; init; }
    public required string PatientName { get; init; }
    public required string PatientId { get; init; }
    public required string StudyDate { get; init; }
    public required string Modality { get; init; }
    public required string SeriesInstanceUid { get; init; }
    public string SeriesDescription { get; init; } = "";
    public required string FilePath { get; init; }
    public required long FileSize { get; init; }
}

public class DicomScpService : IDisposable
{
    private IDicomServer? _server;

    public event EventHandler<FileReceivedEventArgs>? FileReceived;
    public event EventHandler<string>? LogMessage;
    public bool IsRunning => _server != null;

    public void Start(string aeTitle, int port, string incomingFolder)
    {
        if (_server != null) return;

        Directory.CreateDirectory(incomingFolder);

        // Store references for the SCP handler to access
        CStoreScp.IncomingFolder = incomingFolder;
        CStoreScp.ExpectedAeTitle = aeTitle;
        CStoreScp.OnFileReceived = OnFileReceived;
        CStoreScp.OnLog = msg => LogMessage?.Invoke(this, msg);

        _server = DicomServerFactory.Create<CStoreScp>(port);

        LogMessage?.Invoke(this, $"SCP started — AE: {aeTitle}, Port: {port}");
    }

    public void Stop()
    {
        if (_server == null) return;

        _server.Dispose();
        _server = null;

        // Clear static references to prevent memory leaks
        CStoreScp.OnFileReceived = null;
        CStoreScp.OnLog = null;

        LogMessage?.Invoke(this, "SCP stopped");
    }

    private void OnFileReceived(FileReceivedEventArgs args)
    {
        FileReceived?.Invoke(this, args);
    }

    public void Dispose()
    {
        Stop();
    }
}

public class CStoreScp : DicomService, IDicomServiceProvider, IDicomCStoreProvider, IDicomCEchoProvider
{
    // Static fields set by DicomScpService before server starts
    public static string IncomingFolder { get; set; } = "";
    public static string ExpectedAeTitle { get; set; } = "";
    public static Action<FileReceivedEventArgs>? OnFileReceived { get; set; }
    public static Action<string>? OnLog { get; set; }

    public CStoreScp(INetworkStream stream, Encoding fallbackEncoding, Microsoft.Extensions.Logging.ILogger log,
        DicomServiceDependencies dependencies)
        : base(stream, fallbackEncoding, log, dependencies)
    {
    }

    public Task OnReceiveAssociationRequestAsync(DicomAssociation association)
    {
        OnLog?.Invoke($"Association request from {association.CallingAE} @ {association.RemoteHost}:{association.RemotePort}");

        // Accept all presentation contexts (all SOP classes + transfer syntaxes)
        foreach (var pc in association.PresentationContexts)
        {
            pc.AcceptTransferSyntaxes(
                DicomTransferSyntax.ExplicitVRLittleEndian,
                DicomTransferSyntax.ImplicitVRLittleEndian,
                DicomTransferSyntax.ExplicitVRBigEndian,
                DicomTransferSyntax.JPEGProcess14SV1,
                DicomTransferSyntax.JPEGProcess1,
                DicomTransferSyntax.JPEG2000Lossless,
                DicomTransferSyntax.JPEG2000Lossy,
                DicomTransferSyntax.RLELossless
            );
        }

        return SendAssociationAcceptAsync(association);
    }

    public Task OnReceiveAssociationReleaseRequestAsync()
    {
        OnLog?.Invoke("Association released");
        return SendAssociationReleaseResponseAsync();
    }

    public void OnReceiveAbort(DicomAbortSource source, DicomAbortReason reason)
    {
        OnLog?.Invoke($"Association aborted: {source} — {reason}");
    }

    public void OnConnectionClosed(Exception? exception)
    {
        if (exception != null)
            OnLog?.Invoke($"Connection closed: {exception.Message}");
    }

    public Task<DicomCStoreResponse> OnCStoreRequestAsync(DicomCStoreRequest request)
    {
        try
        {
            var dataset = request.Dataset;

            var studyUid = dataset.GetSingleValueOrDefault(DicomTag.StudyInstanceUID, "UNKNOWN_STUDY");
            var seriesUid = dataset.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, "UNKNOWN_SERIES");
            var sopUid = dataset.GetSingleValueOrDefault(DicomTag.SOPInstanceUID, Guid.NewGuid().ToString());
            var patientName = dataset.GetSingleValueOrDefault(DicomTag.PatientName, "Unknown");
            var patientId = dataset.GetSingleValueOrDefault(DicomTag.PatientID, "");
            var studyDate = dataset.GetSingleValueOrDefault(DicomTag.StudyDate, "");
            var modality = dataset.GetSingleValueOrDefault(DicomTag.Modality, "OT");
            var seriesDescription = dataset.GetSingleValueOrDefault(DicomTag.SeriesDescription, "");

            // Save to: incoming/{StudyUID}/{SeriesUID}/{SOPUID}.dcm
            var studyDir = Path.Combine(IncomingFolder, studyUid);
            var seriesDir = Path.Combine(studyDir, seriesUid);
            Directory.CreateDirectory(seriesDir);

            var filePath = Path.Combine(seriesDir, sopUid + ".dcm");
            request.File.Save(filePath);

            var fileSize = new FileInfo(filePath).Length;

            OnFileReceived?.Invoke(new FileReceivedEventArgs
            {
                StudyInstanceUid = studyUid,
                PatientName = patientName,
                PatientId = patientId,
                StudyDate = studyDate,
                Modality = modality,
                SeriesInstanceUid = seriesUid,
                SeriesDescription = seriesDescription,
                FilePath = filePath,
                FileSize = fileSize
            });

            return Task.FromResult(new DicomCStoreResponse(request, DicomStatus.Success));
        }
        catch (Exception ex)
        {
            OnLog?.Invoke($"C-STORE error: {ex.Message}");
            return Task.FromResult(new DicomCStoreResponse(request, DicomStatus.ProcessingFailure));
        }
    }

    public Task OnCStoreRequestExceptionAsync(string tempFileName, Exception e)
    {
        OnLog?.Invoke($"C-STORE exception: {e.Message}");
        return Task.CompletedTask;
    }

    public Task<DicomCEchoResponse> OnCEchoRequestAsync(DicomCEchoRequest request)
    {
        OnLog?.Invoke("C-ECHO received (connectivity test)");
        return Task.FromResult(new DicomCEchoResponse(request, DicomStatus.Success));
    }
}
