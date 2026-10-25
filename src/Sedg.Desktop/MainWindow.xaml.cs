using System.Windows;
using System.Windows.Controls;
using Sedg.Desktop.ViewModels;

namespace Sedg.Desktop;

/// <summary>
/// Shell window: hosts the three views; blocks closing while an engine child still runs (§5.3) and
/// offers the first-run language prompt once, only when settings.language is unset (criterion 10).
/// </summary>
public partial class MainWindow : Window
{
    private readonly MainViewModel _main;
    private bool _firstRunHandled;

    public MainWindow(MainViewModel mainViewModel)
    {
        InitializeComponent();
        _main = mainViewModel;
        DataContext = mainViewModel;
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_main.FirstRunRequested && !_firstRunHandled)
        {
            _firstRunHandled = true;
            ShowFirstRunLanguageDialog();
        }
    }

    private void ShowFirstRunLanguageDialog()
    {
        var localization = _main.Localization;

        var dialog = new Window
        {
            Title = localization.GetString("FirstRun_Title"),
            Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            SizeToContent = SizeToContent.Height,
            Width = 420,
            ResizeMode = ResizeMode.NoResize,
        };
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock
        {
            Text = localization.GetString("FirstRun_Text"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var englishButton = new Button { Content = localization.GetString("FirstRun_English"), Padding = new Thickness(12, 4, 12, 4) };
        englishButton.Click += (_, _) =>
        {
            localization.SetLanguage("en");
            dialog.Close();
        };
        var vietnameseButton = new Button { Content = localization.GetString("FirstRun_Vietnamese"), Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
        vietnameseButton.Click += (_, _) =>
        {
            localization.SetLanguage("vi");
            dialog.Close();
        };
        var skipButton = new Button { Content = localization.GetString("FirstRun_Skip"), Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
        skipButton.Click += (_, _) => dialog.Close();
        buttons.Children.Add(englishButton);
        buttons.Children.Add(vietnameseButton);
        buttons.Children.Add(skipButton);
        panel.Children.Add(buttons);
        dialog.Content = panel;
        dialog.ShowDialog();
    }

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_main.ClosingBlocked)
        {
            return;
        }

        e.Cancel = true;
        MessageBox.Show(
            this,
            _main.RetryBlockedReason,
            _main.Title,
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }
}
