using System.Collections.Generic;
using System.Globalization;

namespace DicomReceiver.Helpers;

public static class LocalizationHelper
{
    private static string _currentLanguage = "auto";

    private static readonly Dictionary<string, Dictionary<string, string>> Strings = new()
    {
        ["ro"] = new()
        {
            ["AppTitle"] = "DICOM Receiver — Weasis Burn",
            ["Start"] = "Pornire",
            ["Stop"] = "Oprire",
            ["Settings"] = "Setari",
            ["Burn"] = "Ardere",
            ["Delete"] = "Sterge",
            ["DeleteAll"] = "Sterge tot",
            ["Status"] = "Status",
            ["PatientName"] = "Pacient",
            ["StudyDate"] = "Data studiu",
            ["Modality"] = "Modalitate",
            ["Series"] = "Serii",
            ["Images"] = "Imagini",
            ["Size"] = "Marime",
            ["Actions"] = "Actiuni",
            ["ScpRunning"] = "SCP Activ",
            ["ScpStopped"] = "SCP Oprit",
            ["Port"] = "Port",
            ["AeTitle"] = "AE Title",
            ["Receiving"] = "Se primeste...",
            ["Complete"] = "Complet",
            ["Burning"] = "Ardere...",
            ["Done"] = "Ars",
            ["Error"] = "Eroare",
            ["NoStudies"] = "Nicio investigatie primita",
            ["ConfirmDelete"] = "Sigur doriti sa stergeti aceasta investigatie?",
            ["ConfirmDeleteAll"] = "Sigur doriti sa stergeti toate investigatiile?",
            ["Yes"] = "Da",
            ["No"] = "Nu",
            ["IncomingFolder"] = "Folder primire",
            ["Timeout"] = "Timeout studiu (sec)",
            ["BurnSpeed"] = "Viteza ardere",
            ["Language"] = "Limba",
            ["Save"] = "Salveaza",
            ["Cancel"] = "Anuleaza",
            ["Browse"] = "Alege...",
            ["SettingsTitle"] = "Setari",
            ["RestartRequired"] = "Reporniti SCP-ul pentru a aplica modificarile",
            ["Log"] = "Jurnal",
            ["ClearLog"] = "Curata jurnal",
            ["DriveWriter"] = "Unitate optica",
            ["NoDrives"] = "Nicio unitate gasita",
            ["RefreshDrives"] = "Reimprospatare",
            ["AutoDeleteAfterBurn"] = "Auto-stergere",
            ["AutoDeleteCheckbox"] = "Dupa ardere",
            ["MaxStudiesKeep"] = "Max investigatii",
            ["MaxStudiesHint"] = "(0 = nelimitat)",
            ["RestartService"] = "Restart serviciu",
            ["ServiceRestarted"] = "Serviciul DICOM a fost repornit",
            ["ServiceRestartFailed"] = "Eroare la repornirea serviciului",
            ["ServiceNotInstalled"] = "Serviciul DICOM nu este instalat",
        },
        ["ru"] = new()
        {
            ["AppTitle"] = "DICOM Receiver — Weasis Burn",
            ["Start"] = "\u0417\u0430\u043f\u0443\u0441\u043a",
            ["Stop"] = "\u0421\u0442\u043e\u043f",
            ["Settings"] = "\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438",
            ["Burn"] = "\u0417\u0430\u043f\u0438\u0441\u044c",
            ["Delete"] = "\u0423\u0434\u0430\u043b\u0438\u0442\u044c",
            ["DeleteAll"] = "\u0423\u0434\u0430\u043b\u0438\u0442\u044c \u0432\u0441\u0435",
            ["Status"] = "\u0421\u0442\u0430\u0442\u0443\u0441",
            ["PatientName"] = "\u041f\u0430\u0446\u0438\u0435\u043d\u0442",
            ["StudyDate"] = "\u0414\u0430\u0442\u0430 \u0438\u0441\u0441\u043b\u0435\u0434\u043e\u0432\u0430\u043d\u0438\u044f",
            ["Modality"] = "\u041c\u043e\u0434\u0430\u043b\u044c\u043d\u043e\u0441\u0442\u044c",
            ["Series"] = "\u0421\u0435\u0440\u0438\u0438",
            ["Images"] = "\u0421\u043d\u0438\u043c\u043a\u0438",
            ["Size"] = "\u0420\u0430\u0437\u043c\u0435\u0440",
            ["Actions"] = "\u0414\u0435\u0439\u0441\u0442\u0432\u0438\u044f",
            ["ScpRunning"] = "SCP \u0410\u043a\u0442\u0438\u0432\u0435\u043d",
            ["ScpStopped"] = "SCP \u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d",
            ["Port"] = "\u041f\u043e\u0440\u0442",
            ["AeTitle"] = "AE Title",
            ["Receiving"] = "\u041f\u0440\u0438\u0435\u043c...",
            ["Complete"] = "\u0413\u043e\u0442\u043e\u0432\u043e",
            ["Burning"] = "\u0417\u0430\u043f\u0438\u0441\u044c...",
            ["Done"] = "\u0417\u0430\u043f\u0438\u0441\u0430\u043d\u043e",
            ["Error"] = "\u041e\u0448\u0438\u0431\u043a\u0430",
            ["NoStudies"] = "\u041d\u0435\u0442 \u043f\u0440\u0438\u043d\u044f\u0442\u044b\u0445 \u0438\u0441\u0441\u043b\u0435\u0434\u043e\u0432\u0430\u043d\u0438\u0439",
            ["ConfirmDelete"] = "\u0412\u044b \u0443\u0432\u0435\u0440\u0435\u043d\u044b, \u0447\u0442\u043e \u0445\u043e\u0442\u0438\u0442\u0435 \u0443\u0434\u0430\u043b\u0438\u0442\u044c \u044d\u0442\u043e \u0438\u0441\u0441\u043b\u0435\u0434\u043e\u0432\u0430\u043d\u0438\u0435?",
            ["ConfirmDeleteAll"] = "\u0412\u044b \u0443\u0432\u0435\u0440\u0435\u043d\u044b, \u0447\u0442\u043e \u0445\u043e\u0442\u0438\u0442\u0435 \u0443\u0434\u0430\u043b\u0438\u0442\u044c \u0432\u0441\u0435 \u0438\u0441\u0441\u043b\u0435\u0434\u043e\u0432\u0430\u043d\u0438\u044f?",
            ["Yes"] = "\u0414\u0430",
            ["No"] = "\u041d\u0435\u0442",
            ["IncomingFolder"] = "\u041f\u0430\u043f\u043a\u0430 \u043f\u0440\u0438\u0435\u043c\u0430",
            ["Timeout"] = "\u0422\u0430\u0439\u043c\u0430\u0443\u0442 \u0438\u0441\u0441\u043b\u0435\u0434\u043e\u0432\u0430\u043d\u0438\u044f (\u0441\u0435\u043a)",
            ["BurnSpeed"] = "\u0421\u043a\u043e\u0440\u043e\u0441\u0442\u044c \u0437\u0430\u043f\u0438\u0441\u0438",
            ["Language"] = "\u042f\u0437\u044b\u043a",
            ["Save"] = "\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c",
            ["Cancel"] = "\u041e\u0442\u043c\u0435\u043d\u0430",
            ["Browse"] = "\u0412\u044b\u0431\u0440\u0430\u0442\u044c...",
            ["SettingsTitle"] = "\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438",
            ["RestartRequired"] = "\u041f\u0435\u0440\u0435\u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 SCP \u0434\u043b\u044f \u043f\u0440\u0438\u043c\u0435\u043d\u0435\u043d\u0438\u044f \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0439",
            ["Log"] = "\u0416\u0443\u0440\u043d\u0430\u043b",
            ["ClearLog"] = "\u041e\u0447\u0438\u0441\u0442\u0438\u0442\u044c \u0436\u0443\u0440\u043d\u0430\u043b",
            ["DriveWriter"] = "\u041e\u043f\u0442\u0438\u0447\u0435\u0441\u043a\u0438\u0439 \u043f\u0440\u0438\u0432\u043e\u0434",
            ["NoDrives"] = "\u041d\u0435\u0442 \u043f\u0440\u0438\u0432\u043e\u0434\u043e\u0432",
            ["RefreshDrives"] = "\u041e\u0431\u043d\u043e\u0432\u0438\u0442\u044c",
            ["AutoDeleteAfterBurn"] = "\u0410\u0432\u0442\u043e\u0443\u0434\u0430\u043b\u0435\u043d\u0438\u0435",
            ["AutoDeleteCheckbox"] = "\u041f\u043e\u0441\u043b\u0435 \u0437\u0430\u043f\u0438\u0441\u0438",
            ["MaxStudiesKeep"] = "\u041c\u0430\u043a\u0441 \u0438\u0441\u0441\u043b\u0435\u0434.",
            ["MaxStudiesHint"] = "(0 = \u0431\u0435\u0437 \u043e\u0433\u0440\u0430\u043d\u0438\u0447\u0435\u043d\u0438\u0439)",
            ["RestartService"] = "\u041f\u0435\u0440\u0435\u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u044c \u0441\u0435\u0440\u0432\u0438\u0441",
            ["ServiceRestarted"] = "\u0421\u0435\u0440\u0432\u0438\u0441 DICOM \u043f\u0435\u0440\u0435\u0437\u0430\u043f\u0443\u0449\u0435\u043d",
            ["ServiceRestartFailed"] = "\u041e\u0448\u0438\u0431\u043a\u0430 \u043f\u0435\u0440\u0435\u0437\u0430\u043f\u0443\u0441\u043a\u0430 \u0441\u0435\u0440\u0432\u0438\u0441\u0430",
            ["ServiceNotInstalled"] = "\u0421\u0435\u0440\u0432\u0438\u0441 DICOM \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d",
        },
        ["en"] = new()
        {
            ["AppTitle"] = "DICOM Receiver — Weasis Burn",
            ["Start"] = "Start",
            ["Stop"] = "Stop",
            ["Settings"] = "Settings",
            ["Burn"] = "Burn",
            ["Delete"] = "Delete",
            ["DeleteAll"] = "Delete All",
            ["Status"] = "Status",
            ["PatientName"] = "Patient",
            ["StudyDate"] = "Study Date",
            ["Modality"] = "Modality",
            ["Series"] = "Series",
            ["Images"] = "Images",
            ["Size"] = "Size",
            ["Actions"] = "Actions",
            ["ScpRunning"] = "SCP Running",
            ["ScpStopped"] = "SCP Stopped",
            ["Port"] = "Port",
            ["AeTitle"] = "AE Title",
            ["Receiving"] = "Receiving...",
            ["Complete"] = "Complete",
            ["Burning"] = "Burning...",
            ["Done"] = "Burned",
            ["Error"] = "Error",
            ["NoStudies"] = "No studies received",
            ["ConfirmDelete"] = "Are you sure you want to delete this study?",
            ["ConfirmDeleteAll"] = "Are you sure you want to delete all studies?",
            ["Yes"] = "Yes",
            ["No"] = "No",
            ["IncomingFolder"] = "Incoming folder",
            ["Timeout"] = "Study timeout (sec)",
            ["BurnSpeed"] = "Burn speed",
            ["Language"] = "Language",
            ["Save"] = "Save",
            ["Cancel"] = "Cancel",
            ["Browse"] = "Browse...",
            ["SettingsTitle"] = "Settings",
            ["RestartRequired"] = "Restart SCP to apply changes",
            ["Log"] = "Log",
            ["ClearLog"] = "Clear log",
            ["DriveWriter"] = "DVD Writer",
            ["NoDrives"] = "No drives found",
            ["RefreshDrives"] = "Refresh",
            ["AutoDeleteAfterBurn"] = "Auto-delete",
            ["AutoDeleteCheckbox"] = "After burn",
            ["MaxStudiesKeep"] = "Max studies",
            ["MaxStudiesHint"] = "(0 = unlimited)",
            ["RestartService"] = "Restart service",
            ["ServiceRestarted"] = "DICOM service restarted",
            ["ServiceRestartFailed"] = "Service restart failed",
            ["ServiceNotInstalled"] = "DICOM service not installed",
        }
    };

    public static void SetLanguage(string language)
    {
        _currentLanguage = language;
    }

    public static string Get(string key)
    {
        var lang = _currentLanguage;
        if (lang == "auto")
        {
            lang = CultureInfo.CurrentCulture.TwoLetterISOLanguageName;
        }

        if (Strings.TryGetValue(lang, out var langStrings) && langStrings.TryGetValue(key, out var value))
            return value;

        // Fallback to English
        if (Strings["en"].TryGetValue(key, out var enValue))
            return enValue;

        return key;
    }

    public static string GetLanguageCode()
    {
        if (_currentLanguage == "auto")
            return CultureInfo.CurrentCulture.TwoLetterISOLanguageName;
        return _currentLanguage;
    }
}
