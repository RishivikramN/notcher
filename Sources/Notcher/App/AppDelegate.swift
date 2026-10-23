import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.start()
        MediaManager.shared.start()
        AudioOutput.shared.start()
        statusItemController = StatusItemController(appState: appState)
        statusItemController?.openDebugWindowFromLaunchArguments()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Opening the app again (e.g. with the menu bar icon hidden) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaManager.shared.stop()
    }

    @objc private func screenParametersDidChange() {
        appState.refresh()
    }
}
