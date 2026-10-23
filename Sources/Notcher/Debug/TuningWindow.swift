import AppKit
import SwiftUI

/// Small window with sliders for `Tuning`, opened from the menu bar item.
@MainActor
final class TuningWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Notcher Tuning"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: TuningView(tuning: .shared))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TuningView: View {
    @Bindable var tuning: Tuning
    @State private var copied = false

    var body: some View {
        Form {
            Section("Expansion") {
                slider("Morph", value: $tuning.values.morphDuration, in: 0.2...1.0)
                slider("Bounce", value: $tuning.values.morphBounce, in: -0.3...0.8)
                slider("Content", value: $tuning.values.contentResponse, in: 0.1...1.0)
                slider("Content delay", value: $tuning.values.contentDelay, in: 0...0.3)
                slider("Corner delay", value: $tuning.values.cornerRadiusDelay, in: 0...0.2)
                Toggle("Slow motion (5×)", isOn: $tuning.values.slowMotion)
            }
            Section("Simulate") {
                Button("Simulate Song Change") {
                    NotificationCenter.default.post(name: .debugSimulateSongChange, object: nil)
                }
            }
            Section {
                HStack {
                    ForEach(DebugNotification.allCases, id: \.self) { kind in
                        Button(kind.title) {
                            NotificationCenter.default.post(name: .debugSimulateNotification, object: kind.rawValue)
                        }
                    }
                }
            }
            Section("Hover scale") {
                slider("Width", value: $tuning.values.hoverScaleX, in: 1.0...1.3)
                slider("Height", value: $tuning.values.hoverScaleY, in: 1.0...1.5)
            }
            Section("Press scale") {
                slider("Width", value: $tuning.values.pressScaleX, in: 0.8...1.0)
                slider("Height", value: $tuning.values.pressScaleY, in: 0.7...1.0)
                slider("Hold (s)", value: $tuning.values.minimumPressDuration, in: 0...0.5)
            }
            Section("Spring") {
                slider("Response", value: $tuning.values.scaleResponse, in: 0.1...1.0)
                slider("Damping", value: $tuning.values.scaleDampingFraction, in: 0.3...1.0)
            }
            Section("Haptics") {
                HStack {
                    Picker("Strength", selection: $tuning.values.hapticStrength) {
                        ForEach(HapticFeedback.Strength.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Test") { HapticFeedback.perform() }
                }
                LabeledContent("Engine", value: HapticFeedback.engineDescription)
            }
            HStack {
                Button("Reset to Spec") { tuning.reset() }
                Spacer()
                Button(copied ? "Copied" : "Copy Values") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tuning.summary, forType: .string)
                    copied = true
                }
            }
        }
        .formStyle(.grouped)
        // A grouped Form is a scroll view with no ideal height; without a fixed height the
        // hosting controller sizes the window down to just its title bar.
        .frame(width: 380, height: 760)
        .onChange(of: tuning.values) { copied = false }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.3f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// Debug: notifications the Tuning window can simulate.
enum DebugNotification: String, CaseIterable {
    case volume, charging, lowBattery, lowPower, connected

    var title: String {
        switch self {
        case .volume: "Volume"
        case .charging: "Charging"
        case .lowBattery: "Low"
        case .lowPower: "Low Power"
        case .connected: "Connect"
        }
    }
}

extension Notification.Name {
    /// Debug: show a notification; the object is a `DebugNotification` raw value.
    static let debugSimulateNotification = Notification.Name("notcher.debug.simulateNotification")

    /// Debug: replay the quick peek as if the track had just changed.
    static let debugSimulateSongChange = Notification.Name("notcher.debug.simulateSongChange")
}
