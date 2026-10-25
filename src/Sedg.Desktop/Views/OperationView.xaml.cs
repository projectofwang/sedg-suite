using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Sedg.Desktop.ViewModels;

namespace Sedg.Desktop.Views;

/// <summary>Operation stage surfaces (Input → Review → Progress → Result, design §5.2).</summary>
public partial class OperationView : UserControl
{
    public OperationView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        Unloaded += (_, _) => Detach();
    }

    private OperationViewModel? ViewModel;

    private void OnDataContextChanged(object? sender, DependencyPropertyChangedEventArgs e)
    {
        Detach();
        ViewModel = DataContext as OperationViewModel;
        if (ViewModel is not null)
        {
            ViewModel.PropertyChanged += OnViewModelPropertyChanged;
        }
    }

    private void Detach()
    {
        if (ViewModel is not null)
        {
            ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
            ViewModel = null;
        }
    }

    /// <summary>Focus the non-destructive button when a review appears (criterion 5 default-focus rule).</summary>
    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OperationViewModel.IsReview) && ViewModel?.IsReview == true)
        {
            var target = ViewModel.ReviewDestructive ? ReviewCancelButton : ReviewConfirmButton;
            Dispatcher.BeginInvoke(() => target.Focus());
        }
    }
}
