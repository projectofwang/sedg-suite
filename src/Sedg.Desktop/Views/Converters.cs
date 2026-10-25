using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Sedg.Desktop.Views;

/// <summary>Radio-group helper: OneWay inverse of IsChecked-style booleans; no value is ever pushed back.</summary>
public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is bool boolean ? !boolean : value ?? DependencyProperty.UnsetValue;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException("Inverse binding is one-way only; a check lands on the paired property.");
}
