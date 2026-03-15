using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using DicomReceiver.Helpers;
using DicomReceiver.Models;
using FellowOakDicom;

namespace DicomReceiver.Views;

public partial class EditStudyDialog : Window
{
    private readonly ReceivedStudy _study;
    private readonly Dictionary<DicomTag, string> _originalValues = new();

    private static string L(string key) => LocalizationHelper.Get(key);

    public int SavedFileCount { get; private set; }

    public EditStudyDialog(ReceivedStudy study)
    {
        InitializeComponent();
        _study = study;

        ApplyLocalization();
        LoadDicomTags();
    }

    private void ApplyLocalization()
    {
        EditWindow.Title = L("EditStudyTitle");
        LblInfoSection.Text = L("EditInfoSection");
        LblStudyUid.Text = L("EditStudyUid") + ":";
        LblStudyStats.Text = L("EditStudyStats") + ":";
        LblPatientSection.Text = L("EditPatientSection");
        LblPatientName.Text = L("EditPatientName") + ":";
        LblPatientID.Text = L("EditPatientID") + ":";
        LblBirthDate.Text = L("EditBirthDate") + ":";
        LblSex.Text = L("EditSex") + ":";
        LblAge.Text = L("EditAge") + ":";
        LblStudySection.Text = L("EditStudySection");
        LblStudyDate.Text = L("EditStudyDate") + ":";
        LblStudyDesc.Text = L("EditStudyDesc") + ":";
        LblAccession.Text = L("EditAccession") + ":";
        LblStudyID.Text = L("EditStudyID") + ":";
        LblModality.Text = L("EditModality") + ":";
        LblPhysician.Text = L("EditPhysician") + ":";
        LblInstitution.Text = L("EditInstitution") + ":";
        BtnSave.Content = L("EditSave");
        BtnCancel.Content = L("EditCancel");
    }

    // ================================================================
    // Display format helpers: DICOM raw ↔ human-readable
    // _originalValues stores RAW DICOM format (for change detection)
    // TextBoxes show human-readable format (for user editing)
    // ================================================================

    /// <summary>YYYYMMDD → DD.MM.YYYY</summary>
    private static string FormatDateForDisplay(string dicomDate)
    {
        if (dicomDate.Length == 8 &&
            int.TryParse(dicomDate[0..4], out _) &&
            int.TryParse(dicomDate[4..6], out _) &&
            int.TryParse(dicomDate[6..8], out _))
            return $"{dicomDate[6..8]}.{dicomDate[4..6]}.{dicomDate[0..4]}";
        return dicomDate;
    }

    /// <summary>DD.MM.YYYY → YYYYMMDD</summary>
    private static string ParseDateForDicom(string displayDate)
    {
        if (displayDate.Length == 10 && displayDate[2] == '.' && displayDate[5] == '.')
            return $"{displayDate[6..10]}{displayDate[3..5]}{displayDate[0..2]}";
        return displayDate;
    }

    /// <summary>LASTNAME^FIRSTNAME → LASTNAME FIRSTNAME</summary>
    private static string FormatNameForDisplay(string dicomName)
    {
        return dicomName.Replace('^', ' ');
    }

    /// <summary>LASTNAME FIRSTNAME → LASTNAME^FIRSTNAME (first space only)</summary>
    private static string ParseNameForDicom(string displayName)
    {
        var idx = displayName.IndexOf(' ');
        if (idx > 0)
            return displayName[..idx] + "^" + displayName[(idx + 1)..];
        return displayName;
    }

    /// <summary>066Y → 66</summary>
    private static string FormatAgeForDisplay(string dicomAge)
    {
        if (dicomAge.Length >= 2 && char.IsLetter(dicomAge[^1]))
        {
            var numPart = dicomAge[..^1].TrimStart('0');
            return string.IsNullOrEmpty(numPart) ? "0" : numPart;
        }
        return dicomAge;
    }

    /// <summary>66 → 066Y</summary>
    private static string ParseAgeForDicom(string displayAge)
    {
        if (int.TryParse(displayAge, out var age))
            return $"{age:D3}Y";
        return displayAge;
    }

    private void LoadDicomTags()
    {
        // Info section from model
        TxtStudyUid.Text = _study.StudyInstanceUid;
        TxtStudyStats.Text = $"{_study.ImageCount} images, {_study.Series.Count} series, {_study.TotalSizeFormatted}";

        // Find first DICOM file
        if (string.IsNullOrEmpty(_study.StoragePath) || !Directory.Exists(_study.StoragePath))
            return;

        var dirInfo = new DirectoryInfo(_study.StoragePath);
        FileInfo? firstFile = null;
        foreach (var f in dirInfo.EnumerateFiles("*.*", SearchOption.AllDirectories))
        {
            if (f.Extension.Equals(".dcm", StringComparison.OrdinalIgnoreCase))
            {
                firstFile = f;
                break;
            }
        }
        if (firstFile == null)
            return;

        try
        {
            var dcmFile = DicomFile.Open(firstFile.FullName, FileReadOption.SkipLargeTags);
            var ds = dcmFile.Dataset;

            // Read raw DICOM values, store as originals, display formatted
            string raw;

            raw = ds.GetSingleValueOrDefault(DicomTag.PatientName, "");
            _originalValues[DicomTag.PatientName] = raw;
            TxtPatientName.Text = FormatNameForDisplay(raw);

            raw = ds.GetSingleValueOrDefault(DicomTag.PatientID, "");
            _originalValues[DicomTag.PatientID] = raw;
            TxtPatientID.Text = raw;

            raw = ds.GetSingleValueOrDefault(DicomTag.PatientBirthDate, "");
            _originalValues[DicomTag.PatientBirthDate] = raw;
            TxtBirthDate.Text = FormatDateForDisplay(raw);

            raw = ds.GetSingleValueOrDefault(DicomTag.PatientSex, "");
            _originalValues[DicomTag.PatientSex] = raw;
            TxtSex.Text = raw;

            raw = ds.GetSingleValueOrDefault(DicomTag.PatientAge, "");
            _originalValues[DicomTag.PatientAge] = raw;
            TxtAge.Text = FormatAgeForDisplay(raw);

            raw = ds.GetSingleValueOrDefault(DicomTag.StudyDate, "");
            _originalValues[DicomTag.StudyDate] = raw;
            TxtStudyDate.Text = FormatDateForDisplay(raw);

            raw = ds.GetSingleValueOrDefault(DicomTag.StudyDescription, "");
            _originalValues[DicomTag.StudyDescription] = raw;
            TxtStudyDesc.Text = raw;

            raw = ds.GetSingleValueOrDefault(DicomTag.AccessionNumber, "");
            _originalValues[DicomTag.AccessionNumber] = raw;
            TxtAccession.Text = raw;

            raw = ds.GetSingleValueOrDefault(DicomTag.StudyID, "");
            _originalValues[DicomTag.StudyID] = raw;
            TxtStudyID.Text = raw;

            TxtModality.Text = ds.GetSingleValueOrDefault(DicomTag.Modality, "");

            raw = ds.GetSingleValueOrDefault(DicomTag.ReferringPhysicianName, "");
            _originalValues[DicomTag.ReferringPhysicianName] = raw;
            TxtPhysician.Text = FormatNameForDisplay(raw);

            raw = ds.GetSingleValueOrDefault(DicomTag.InstitutionName, "");
            _originalValues[DicomTag.InstitutionName] = raw;
            TxtInstitution.Text = raw;
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Error reading DICOM: {ex.Message}", "Error",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    /// <summary>
    /// Builds a dictionary of only the tags that were changed by the user.
    /// Converts display format back to DICOM format for storage.
    /// _originalValues stores RAW DICOM format; display values are converted back before comparison.
    /// </summary>
    private Dictionary<DicomTag, string> GetChangedTags()
    {
        var changed = new Dictionary<DicomTag, string>();

        void Check(DicomTag tag, string displayValue, Func<string, string>? toDicom = null)
        {
            var dicomValue = toDicom != null ? toDicom(displayValue) : displayValue;
            if (_originalValues.TryGetValue(tag, out var original) && original != dicomValue)
                changed[tag] = dicomValue;
        }

        Check(DicomTag.PatientName, TxtPatientName.Text, ParseNameForDicom);
        Check(DicomTag.PatientID, TxtPatientID.Text);
        Check(DicomTag.PatientBirthDate, TxtBirthDate.Text, ParseDateForDicom);
        Check(DicomTag.PatientSex, TxtSex.Text);
        Check(DicomTag.PatientAge, TxtAge.Text, ParseAgeForDicom);
        Check(DicomTag.StudyDate, TxtStudyDate.Text, ParseDateForDicom);
        Check(DicomTag.StudyDescription, TxtStudyDesc.Text);
        Check(DicomTag.AccessionNumber, TxtAccession.Text);
        Check(DicomTag.StudyID, TxtStudyID.Text);
        Check(DicomTag.ReferringPhysicianName, TxtPhysician.Text, ParseNameForDicom);
        Check(DicomTag.InstitutionName, TxtInstitution.Text);

        return changed;
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        var changedTags = GetChangedTags();

        if (changedTags.Count == 0)
        {
            DialogResult = false;
            Close();
            return;
        }

        BtnSave.IsEnabled = false;
        BtnCancel.IsEnabled = false;
        BtnSave.Content = L("EditSaving");

        try
        {
            var result = await Task.Run(() => ApplyTagChanges(_study.StoragePath, changedTags));
            SavedFileCount = result.ProcessedCount;

            // Show warnings if any files failed
            if (result.FailedCount > 0)
            {
                var errMsg = $"Modified {result.ProcessedCount} files, but {result.FailedCount} failed:\n\n"
                    + string.Join("\n", result.Errors.Count > 10
                        ? [..result.Errors.GetRange(0, 10), $"... and {result.Errors.Count - 10} more"]
                        : result.Errors);
                MessageBox.Show(errMsg, "Warning", MessageBoxButton.OK, MessageBoxImage.Warning);
            }

            // Update the ReceivedStudy model to reflect changes in UI
            if (changedTags.ContainsKey(DicomTag.PatientName))
                _study.PatientName = FormatNameForDisplay(changedTags[DicomTag.PatientName]);
            if (result.NewStudyInstanceUid != null)
                _study.StudyInstanceUid = result.NewStudyInstanceUid;
            if (changedTags.ContainsKey(DicomTag.StudyDate))
            {
                var raw = changedTags[DicomTag.StudyDate];
                // Format YYYYMMDD → DD.MM.YYYY for display
                if (raw.Length == 8)
                    _study.StudyDate = $"{raw[6..8]}.{raw[4..6]}.{raw[0..4]}";
                else
                    _study.StudyDate = raw;
            }
            DialogResult = true;
            Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Error saving: {ex.Message}", "Error",
                MessageBoxButton.OK, MessageBoxImage.Error);
            BtnSave.IsEnabled = true;
            BtnCancel.IsEnabled = true;
            BtnSave.Content = L("EditSave");
        }
    }

    private record ApplyResult(int ProcessedCount, int FailedCount, string? NewStudyInstanceUid, List<string> Errors);

    /// <summary>
    /// Computes date delta (days) between original and new StudyDate.
    /// Returns 0 if dates are identical or cannot be parsed.
    /// </summary>
    private static int ComputeDateDeltaDays(string originalDicomDate, string newDicomDate)
    {
        if (originalDicomDate == newDicomDate) return 0;
        if (originalDicomDate.Length != 8 || newDicomDate.Length != 8) return 0;
        if (!DateTime.TryParseExact(originalDicomDate, "yyyyMMdd", null, System.Globalization.DateTimeStyles.None, out var orig)) return 0;
        if (!DateTime.TryParseExact(newDicomDate, "yyyyMMdd", null, System.Globalization.DateTimeStyles.None, out var nw)) return 0;
        return (int)(nw - orig).TotalDays;
    }

    /// <summary>
    /// Shifts a DICOM date (YYYYMMDD) by deltaDays. Returns original if parsing fails.
    /// </summary>
    private static string ShiftDicomDate(string dicomDate, int deltaDays)
    {
        if (dicomDate.Length != 8) return dicomDate;
        if (!DateTime.TryParseExact(dicomDate, "yyyyMMdd", null, System.Globalization.DateTimeStyles.None, out var dt)) return dicomDate;
        return dt.AddDays(deltaDays).ToString("yyyyMMdd");
    }

    /// <summary>
    /// Shifts a DICOM datetime (YYYYMMDDHHMMSS.FFFFFF or shorter) by deltaDays.
    /// Preserves the time portion. Returns original if parsing fails.
    /// </summary>
    private static string ShiftDicomDateTime(string dicomDt, int deltaDays)
    {
        if (dicomDt.Length < 8) return dicomDt;
        var datePart = dicomDt[..8];
        var timePart = dicomDt.Length > 8 ? dicomDt[8..] : "";
        var shifted = ShiftDicomDate(datePart, deltaDays);
        return shifted + timePart;
    }

    // Date tags that must be shifted when StudyDate changes
    private static readonly DicomTag[] CascadeDateTags =
    {
        DicomTag.SeriesDate,
        DicomTag.AcquisitionDate,
        DicomTag.ContentDate,
    };

    /// <summary>
    /// Applies tag changes to ALL DICOM files in the study folder.
    /// When StudyDate changes, cascades date shift to SeriesDate, AcquisitionDate,
    /// ContentDate, AcquisitionDateTime (preserving time components).
    /// Pattern identical to BurnService.ApplyPrivacyMode: ReadAll → modify → Save in-place.
    /// </summary>
    private static ApplyResult ApplyTagChanges(string studyPath, Dictionary<DicomTag, string> changedTags)
    {
        var dir = new DirectoryInfo(studyPath);
        if (!dir.Exists) return new ApplyResult(0, 0, null, []);

        // Check if patient identity changed — requires new UIDs for Siemens compatibility
        bool regenerateUids = changedTags.ContainsKey(DicomTag.PatientName) ||
                              changedTags.ContainsKey(DicomTag.PatientID);
        string? newStudyUid = regenerateUids ? DicomUIDGenerator.GenerateDerivedFromUUID().UID : null;
        // Per-series UID map (old → new) for consistency across files in same series
        var seriesUidMap = new Dictionary<string, string>();

        // Pre-compute date delta if StudyDate changed
        int dateDelta = 0;
        bool cascadeDates = false;
        if (changedTags.TryGetValue(DicomTag.StudyDate, out var newStudyDate))
        {
            // Find original StudyDate from first DICOM file
            foreach (var probe in dir.EnumerateFiles("*.*", SearchOption.AllDirectories))
            {
                if (!probe.Extension.Equals(".dcm", StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    var probeDcm = DicomFile.Open(probe.FullName, FileReadOption.SkipLargeTags);
                    var origDate = probeDcm.Dataset.GetSingleValueOrDefault(DicomTag.StudyDate, "");
                    dateDelta = ComputeDateDeltaDays(origDate, newStudyDate);
                    cascadeDates = dateDelta != 0;
                }
                catch { /* skip */ }
                break;
            }
        }

        int processed = 0;
        int failed = 0;
        var errors = new List<string>();

        // Single pass: enumerate all files, filter .dcm case-insensitive
        // Avoids NTFS double-processing bug (*.DCM and *.dcm match same files)
        foreach (var file in dir.EnumerateFiles("*.*", SearchOption.AllDirectories))
        {
            if (!file.Extension.Equals(".dcm", StringComparison.OrdinalIgnoreCase))
                continue;

            try
            {
                // ReadAll: reads entire file into memory and CLOSES the file handle.
                // Required for in-place Save() — otherwise file is still locked.
                var dcmFile = DicomFile.Open(file.FullName, FileReadOption.ReadAll);
                var ds = dcmFile.Dataset;

                // Remember original file size for validation
                var originalSize = file.Length;

                // Cascade date shift BEFORE applying explicit changes (read originals first)
                if (cascadeDates)
                {
                    foreach (var dateTag in CascadeDateTags)
                    {
                        var orig = ds.GetSingleValueOrDefault(dateTag, "");
                        if (orig.Length == 8)
                            ds.AddOrUpdate(dateTag, ShiftDicomDate(orig, dateDelta));
                    }

                    // AcquisitionDateTime (combined date+time, variable length)
                    var origDt = ds.GetSingleValueOrDefault(DicomTag.AcquisitionDateTime, "");
                    if (origDt.Length >= 8)
                        ds.AddOrUpdate(DicomTag.AcquisitionDateTime, ShiftDicomDateTime(origDt, dateDelta));
                }

                // Apply explicitly changed tags (StudyDate, PatientName, etc.)
                foreach (var (tag, value) in changedTags)
                    ds.AddOrUpdate(tag, value);

                // Regenerate UIDs when patient identity changes
                // Without this, Siemens stations reject import if old study with same UID exists
                if (regenerateUids && newStudyUid != null)
                {
                    ds.AddOrUpdate(DicomTag.StudyInstanceUID, newStudyUid);

                    // Map old SeriesInstanceUID → new (consistent per series)
                    var oldSeriesUid = ds.GetSingleValueOrDefault(DicomTag.SeriesInstanceUID, "");
                    if (!string.IsNullOrEmpty(oldSeriesUid))
                    {
                        if (!seriesUidMap.TryGetValue(oldSeriesUid, out var mappedSeriesUid))
                        {
                            mappedSeriesUid = DicomUIDGenerator.GenerateDerivedFromUUID().UID;
                            seriesUidMap[oldSeriesUid] = mappedSeriesUid;
                        }
                        ds.AddOrUpdate(DicomTag.SeriesInstanceUID, mappedSeriesUid);
                    }

                    // New SOPInstanceUID per file + update MediaStorageSOP in file meta
                    var newSopUid = DicomUIDGenerator.GenerateDerivedFromUUID().UID;
                    ds.AddOrUpdate(DicomTag.SOPInstanceUID, newSopUid);
                    if (dcmFile.FileMetaInfo != null)
                        dcmFile.FileMetaInfo.MediaStorageSOPInstanceUID = new DicomUID(newSopUid, "SOP Instance UID", DicomUidType.SOPInstance);
                }

                dcmFile.Save(file.FullName);

                // Post-save validation: verify file is still valid DICOM
                var savedSize = new FileInfo(file.FullName).Length;
                if (savedSize < 132)
                {
                    // File truncated — Save() produced empty/corrupt file
                    failed++;
                    errors.Add($"TRUNCATED after save: {file.Name} ({savedSize} bytes, was {originalSize})");
                    continue;
                }

                // Verify DICM preamble still present
                using (var fs = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    var header = new byte[132];
                    if (fs.Read(header, 0, 132) == 132)
                    {
                        var magic = System.Text.Encoding.ASCII.GetString(header, 128, 4);
                        if (magic != "DICM")
                        {
                            failed++;
                            errors.Add($"INVALID DICM header after save: {file.Name}");
                            continue;
                        }
                    }
                }

                processed++;
            }
            catch (Exception ex)
            {
                failed++;
                errors.Add($"{file.Name}: {ex.Message}");
            }
        }

        return new ApplyResult(processed, failed, newStudyUid, errors);
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
