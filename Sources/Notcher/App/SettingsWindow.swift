import AppKit
import SwiftUI

/// The Settings window (spec §2.14). Tabs for features that don't exist yet (Connectivity,
/// Focus, Calendar, File Tray, Lock Screen, License) arrive with their breakpoints.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Notcher Settings"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(settings: .shared))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, display, nowPlaying, sound, battery, connectivity, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Display"
        case .nowPlaying: "Now Playing"
        case .sound: "Sound"
        case .battery: "Battery"
        case .connectivity: "Connectivity"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "display"
        case .nowPlaying: "play.fill"
        case .sound: "speaker.wave.2.fill"
        case .battery: "battery.100percent"
        case .connectivity: "airpods.gen4"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .display: .blue
        case .nowPlaying: .pink
        case .sound: .orange
        case .battery: .green
        case .connectivity: .blue
        case .about: .indigo
        }
    }
}

private struct SettingsView: View {
    @Bindable var settings: Settings
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch pane ?? .general {
                case .general: GeneralPane(settings: settings)
                case .display: DisplayPane(settings: settings)
                case .nowPlaying: NowPlayingPane(settings: settings)
                case .sound: SoundPane(settings: settings)
                case .battery: BatteryPane(settings: settings)
                case .connectivity: ConnectivityPane(settings: settings)
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .general).title)
        }
        .frame(width: 700, height: 500)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Bindable var settings: Settings

    var body: some View {
        Section {
            Toggle("Expand on hover", isOn: $settings.expandOnHover)
            if settings.expandOnHover {
                LabeledSlider(
                    title: "Hover duration",
                    value: $settings.hoverDuration,
                    range: 0...1,
                    format: { $0 == 0 ? "Instant" : String(format: "%.1f s", $0) }
                )
            }
            Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("Expand on hover opens the island as soon as the pointer reaches it. With it off, click the notch to open it.")
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Swipe to toggle open", isOn: $settings.swipeToToggle)
            Toggle("Swipe to skip media", isOn: $settings.swipeToSkip)
            Toggle("Swipe to dismiss activity", isOn: $settings.swipeToDismiss)
            Toggle("Natural movement", isOn: $settings.naturalMovement)
        } header: {
            Text("Gestures")
        } footer: {
            Text("Swipe on the island with two fingers. With natural movement off, swipes follow your scroll direction instead of your fingers.")
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Hide in fullscreen", isOn: $settings.hideInFullscreen)
            Toggle("Hide menu bar icon", isOn: $settings.hideMenuBarIcon)
        } header: {
            Text("Visibility")
        } footer: {
            if settings.hideMenuBarIcon {
                Text("Open Notcher again from Applications to get back to Settings.")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
        }
    }
}

private struct DisplayPane: View {
    @Bindable var settings: Settings

    var body: some View {
        Section {
            Picker("Show on", selection: $settings.displayChoice) {
                Text("Built-in display").tag(DisplayChoice.builtIn)
                Text("Main display").tag(DisplayChoice.main)
                Text("All displays").tag(DisplayChoice.all)
                if NSScreen.screens.count > 1 {
                    Divider()
                    ForEach(NSScreen.screens, id: \.displayUUID) { screen in
                        Text(screen.localizedName).tag(DisplayChoice.specific(screen.displayUUID))
                    }
                }
            }
            Toggle("Force simulated notch", isOn: $settings.forceSimulatedNotch)
        } header: {
            Text("Display on")
        } footer: {
            Text("On displays without a notch, Notcher draws a small pill. A simulated notch draws a 140 pt notch instead.")
                .foregroundStyle(.secondary)
        }
        Section("Tuning") {
            LabeledSlider(
                title: "Notch width",
                value: $settings.notchWidthOffset,
                range: -20...20,
                step: 1,
                format: { String(format: "%+.0f pt", $0) }
            )
            LabeledSlider(
                title: "Notch height",
                value: $settings.notchHeightOffset,
                range: -10...10,
                step: 1,
                format: { String(format: "%+.0f pt", $0) }
            )
            Button("Reset") {
                settings.notchWidthOffset = 0
                settings.notchHeightOffset = 0
            }
            .disabled(settings.notchWidthOffset == 0 && settings.notchHeightOffset == 0)
        }
    }
}

private struct NowPlayingPane: View {
    @Bindable var settings: Settings
    @Bindable var media = MediaManager.shared

    var body: some View {
        Section {
            Picker("Media source", selection: $media.preference) {
                ForEach(MediaSourcePreference.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Source")
        } footer: {
            Text("Automatic and System follow any app that reports what's playing, including browsers.")
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Quick peek on song change", isOn: $settings.quickPeek)
            if settings.quickPeek {
                LabeledSlider(
                    title: "Peek duration",
                    value: $settings.peekDuration,
                    range: 0.5...5,
                    format: { String(format: "%.1f s", $0) }
                )
            }
            LabeledSlider(
                title: "Idle duration",
                value: $settings.idleDuration,
                range: 0...30,
                step: 1,
                format: { String(format: "%.0f s", $0) }
            )
        } header: {
            Text("Activity")
        } footer: {
            Text("Idle duration is how long a paused track stays beside the notch.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct SoundPane: View {
    @Bindable var settings: Settings

    var body: some View {
        Section {
            Toggle("Volume HUD", isOn: $settings.enableVolumeHUD)
        } footer: {
            Text("Replaces the macOS volume overlay. Needs Accessibility permission.")
                .foregroundStyle(.secondary)
        }
        if settings.enableVolumeHUD {
            Section("Appearance") {
                Picker("Output device", selection: $settings.volumeOutputDevice) {
                    Text("Show device").tag(OutputDeviceStyle.device)
                    Text("Show symbol").tag(OutputDeviceStyle.symbol)
                }
                if settings.volumeOutputDevice == .device {
                    Toggle("Show AirPods as 3D models", isOn: $settings.airPodsRenders)
                }
                LabeledSlider(
                    title: "Duration",
                    value: $settings.hudDuration,
                    range: 0.5...5,
                    format: { String(format: "%.1f s", $0) }
                )
            }
        }
    }
}

private struct BatteryPane: View {
    @Bindable var settings: Settings

    var body: some View {
        Section("Notifications") {
            Toggle("Charging", isOn: $settings.notifyCharging)
            Toggle("Warn on low battery", isOn: $settings.warnOnLowBattery)
            if settings.warnOnLowBattery {
                Picker("Low battery threshold", selection: $settings.lowBatteryThreshold) {
                    ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
            Toggle("Notify on Low Power Mode", isOn: $settings.notifyLowPowerMode)
        }
        Section {
            LabeledSlider(
                title: "Duration",
                value: $settings.batteryDuration,
                range: 1...8,
                format: { String(format: "%.1f s", $0) }
            )
        }
    }
}

private struct ConnectivityPane: View {
    @Bindable var settings: Settings

    var body: some View {
        Section {
            Toggle("Show connected devices", isOn: $settings.enableConnectivity)
        } footer: {
            Text("When AirPods or other Bluetooth audio devices connect, the island shows the device and its battery.")
                .foregroundStyle(.secondary)
        }
        if settings.enableConnectivity {
            Section {
                Toggle("Show AirPods as 3D models", isOn: $settings.airPodsRenders)
                Picker("Low battery below", selection: $settings.lowConnectBatteryThreshold) {
                    ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                LabeledSlider(
                    title: "Duration",
                    value: $settings.connectivityDuration,
                    range: 1...10,
                    format: { String(format: "%.1f s", $0) }
                )
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notcher").font(.title2.weight(.semibold))
                    Text("Version \(Self.version)").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// The marketing version only; the build number stays internal.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - Controls

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .frame(width: 260)
        }
    }
}
