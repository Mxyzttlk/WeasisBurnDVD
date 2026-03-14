using System;
using System.Globalization;
using System.Windows.Data;
using DicomReceiver.Models;

namespace DicomReceiver.Helpers;

public class StudyStatusToBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is StudyStatus status)
            return status == StudyStatus.Complete || status == StudyStatus.Done;
        return false;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}

public class StudyStatusToMultiBoolConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        if (values.Length > 0 && values[0] is StudyStatus status)
            return status == StudyStatus.Complete || status == StudyStatus.Done;
        return false;
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}
