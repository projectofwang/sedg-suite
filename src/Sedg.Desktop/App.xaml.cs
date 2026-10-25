using System.Windows;
using Sedg.Desktop.Services;
using Sedg.Desktop.ViewModels;

namespace Sedg.Desktop;

/// <summary>
/// Composition root (design §8.1): services created once, passed into the main view model;
/// no StartupUri — the window is constructed here so all seams stay parameterized.
/// Unhandled UI exceptions are logged, never crash-loop a session.
/// </summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var appLog = new AppLog();
        var localization = new LocalizationManager();
        var locator = new EngineLocator();
        var engine = new EngineProcessClient(locator, appLog, localization);
        var broker = new BrokerCoordinator(appLog, localization);
        var preflight = new Preflight(locator, localization);
        var validator = new Validator();
        var main = new MainViewModel(appLog, engine, broker, preflight, validator, localization);

        DispatcherUnhandledException += (_, args) =>
        {
            appLog.Write("error", "Unhandled UI exception: " + args.Exception.Message);
            args.Handled = true;
        };

        new MainWindow(main).Show();
    }
}
