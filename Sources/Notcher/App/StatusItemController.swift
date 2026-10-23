import AppKit
import Observation

/// Menu bar item (spec §2.14): Settings, About, Accessibility nudge, Quit, plus a Debug
/// submenu in debug builds.
/// Hidden when "Hide menu bar icon" is on; reopening the app shows Settings instead.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let appState: AppState
    private let menu = NSMenu()
    private let settingsWindow = SettingsWindowController()
    #if DEBUG
    private let tuningWindow = TuningWindowController()
    private let nowPlayingWindow = NowPlayingDebugWindowController()
    #endif

    init(appState: AppState) {
        self.appState = appState
        super.init()

        if let button = statusItem.button {
            // Notcher's own mark (Support/Icon/make-icon.swift), not the asset catalog's TrayIcon.
            if let image = NSImage(named: "NotcherTray") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Notcher"
            }
        }
        menu.delegate = self
        statusItem.menu = menu
        observeVisibility()
    }

    private func observeVisibility() {
        statusItem.isVisible = !Settings.shared.hideMenuBarIcon
        withObservationTracking {
            _ = Settings.shared.hideMenuBarIcon
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeVisibility() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        add("Settings…", #selector(showSettings), key: ",")
        add("About Notcher", #selector(showAbout))

        if !appState.mediaKeys.isRunning {
            menu.addItem(.separator())
            add("Allow Accessibility for the Volume HUD…", #selector(openAccessibilitySettings))
        }

        #if DEBUG
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu()
        menu.addItem(debugItem)
        #endif

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    #if DEBUG
    private func debugMenu() -> NSMenu {
        let debug = NSMenu()
        for controller in appState.controllers {
            let metrics = controller.metrics
            let info = String(format: "%@ · %.1f × %.1f pt", metrics.mode.title, metrics.notchWidth, metrics.notchHeight)
            debug.addItem(withTitle: info, action: nil, keyEquivalent: "").isEnabled = false
        }
        debug.addItem(.separator())

        let modeItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let automatic = NSMenuItem(title: "Automatic", action: #selector(selectMode(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = appState.modeOverride == nil ? .on : .off
        modeMenu.addItem(automatic)
        modeMenu.addItem(.separator())
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = appState.modeOverride == mode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        debug.addItem(modeItem)

        add("Tuning…", #selector(showTuning), to: debug)
        add("Now Playing…", #selector(showNowPlaying), to: debug)
        return debug
    }

    #endif

    private func add(_ title: String, _ action: Selector, key: String = "", to target: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        (target ?? menu).addItem(item)
    }

    #if DEBUG
    @objc private func selectMode(_ sender: NSMenuItem) {
        appState.modeOverride = (sender.representedObject as? String).flatMap(DisplayMode.init(rawValue:))
    }
    #endif

    /// `--debug-window tuning|now-playing|settings` opens a window at launch (development aid).
    func openDebugWindowFromLaunchArguments() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-window"), index + 1 < arguments.count else { return }
        switch arguments[index + 1] {
        case "tuning": showTuning()
        case "now-playing": showNowPlaying()
        case "settings": showSettings()
        default: break
        }
        #endif
    }

    @objc func showSettings() {
        settingsWindow.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        // An empty build version keeps the panel to "Version 1.0.0" without "(1)".
        NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.openSettings()
    }

    #if DEBUG
    @objc private func showTuning() {
        tuningWindow.show()
    }

    @objc private func showNowPlaying() {
        nowPlayingWindow.show()
    }
    #endif
}
