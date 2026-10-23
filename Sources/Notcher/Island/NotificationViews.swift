import SwiftUI

/// Notification content beside the notch. Each side holds a 68 pt block (spec §9.6), centred in
/// its half of the extra width (92 pt for HUDs, 84 pt for battery). Styling reuses the tokens
/// measured from Alcove's player: 6 pt bars, 20 % tracks, 47 % secondary text.
struct NotificationView: View {
    let controller: NotchController

    private let blockWidth: CGFloat = 68

    var body: some View {
        if case .connected(let device) = controller.notification {
            ConnectedDeviceView(device: device, controller: controller)
        } else if let notification = controller.notification {
            let side = notification.width(for: controller.displayMode) / 2
            let margin = max((side - blockWidth) / 2, 0)
            // The volume HUD's outer insets are measured from Alcove: glyphs start 11.5 pt in on the
            // left (9.5 pt to the symbol's frame), the bar ends 11 pt in on the right.
            let isVolume = notification == .volume
            let leadingInset = isVolume ? margin - 2.5 : margin
            let trailingInset = isVolume ? margin - 1 : margin

            HStack(spacing: 0) {
                leading(notification)
                    .frame(minWidth: blockWidth, alignment: .leading)
                    .fixedSize()
                    .padding(.leading, leadingInset)
                Spacer(minLength: 0)
                trailing(notification)
                    .frame(width: blockWidth, alignment: .trailing)
                    .padding(.trailing, trailingInset)
            }
            .frame(width: controller.currentWidth, height: controller.notchHeight)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func leading(_ notification: IslandNotification) -> some View {
        switch notification {
        case .volume:
            VolumeLabel()
        case .connected:
            EmptyView()
        case .battery(let event, _):
            Text(event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    @ViewBuilder
    private func trailing(_ notification: IslandNotification) -> some View {
        switch notification {
        case .volume:
            VolumeBar()
        case .battery(let event, let state):
            BatteryIndicator(event: event, state: state)
        case .connected:
            EmptyView()
        }
    }
}

// MARK: - Volume

/// Left side of the volume HUD, matched against Alcove: a 14 pt semibold symbol, then "Sound"
/// in 12 pt semibold white, 7.5 pt apart as drawn (5 pt between frames). "Show device" swaps the speaker for the output:
/// the AirPods render (or Alcove's symbol style) and other external outputs' symbols.
private struct VolumeLabel: View {
    private let output = AudioOutput.shared
    private let settings = Settings.shared

    var body: some View {
        let level = output.isMuted ? 0 : output.volume
        let device = output.device
        let showsDevice = settings.volumeOutputDevice == .device && level > 0.001 && device.map { !$0.isBuiltIn } == true

        HStack(spacing: 5) {
            if showsDevice, settings.airPodsRenders, let render = device?.product?.renderName {
                LoopingVideoView(resourceName: render, zoom: 1.6)
                    .frame(width: 28, height: 28)
                    .help(device?.name ?? "")
            } else if showsDevice, let device {
                Image(systemName: device.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: level > 0.001 ? "speaker.wave.2.fill" : "speaker.slash.fill", variableValue: Double(level))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text("Sound")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// 68 × 5 pt bar: white fill on a 22 % white track (measured from Alcove's "White" style).
private struct VolumeBar: View {
    private let output = AudioOutput.shared

    var body: some View {
        let level = CGFloat(output.isMuted ? 0 : output.volume)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white)
                    .frame(width: level > 0 ? max(5, proxy.size.width * level) : 0)
            }
        }
        .frame(height: 5)
        // "Smooth" animation speed.
        .animation(.spring(response: 0.25, dampingFraction: 1), value: level)
    }
}

// MARK: - Connected device

/// A Bluetooth audio device just connected (measured from Alcove): the device's looping render
/// (or symbol) on the left, centred 15.75 pt out from the notch, and a 17 pt battery ring with a
/// 3 pt round-capped stroke on the right, centred 20.25 pt out from the notch.
private struct ConnectedDeviceView: View {
    let device: BluetoothMonitor.Device
    let controller: NotchController
    private let settings = Settings.shared

    var body: some View {
        let side = (controller.currentWidth - controller.notchWidth) / 2
        HStack(spacing: 0) {
            ZStack {
                if settings.airPodsRenders, let render = device.product?.renderName {
                    // Smaller than in the volume HUD: the buds stand ~14 pt tall here.
                    LoopingVideoView(resourceName: render, zoom: 1.6)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: device.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 0)
            .padding(.leading, side - 15.75)
            Spacer(minLength: 0)
            ZStack {
                if let battery = device.battery {
                    BatteryRing(level: Double(battery) / 100, color: ringColor(battery))
                        .frame(width: 17, height: 17)
                }
            }
            .frame(width: 0)
            .padding(.trailing, side - 20.25)
        }
        .frame(width: controller.currentWidth, height: controller.notchHeight)
        .help(device.name)
        .environment(\.colorScheme, .dark)
    }

    private func ringColor(_ battery: Int) -> Color {
        // Alcove's ring reads (73, 221, 135) on screen, a Display P3 green outside sRGB.
        battery <= settings.lowConnectBatteryThreshold
            ? Color("LowBatteryColor")
            : Color(.displayP3, red: 65 / 255, green: 219 / 255, blue: 118 / 255)
    }
}

/// Clockwise from the top over a dim track of the same colour (a third as bright in Alcove).
private struct BatteryRing: View {
    let level: Double
    let color: Color

    var body: some View {
        let stroke = StrokeStyle(lineWidth: 3, lineCap: .round)
        ZStack {
            Circle().stroke(color.opacity(0.27), style: stroke)
            Circle()
                .trim(from: 0, to: max(level, 0.02))
                .stroke(color, style: stroke)
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}

// MARK: - Battery

private struct BatteryIndicator: View {
    let event: BatteryMonitor.Event
    let state: BatteryMonitor.State

    var body: some View {
        HStack(spacing: 5) {
            Text("\(state.percentage)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(event.color, .white.opacity(0.35))
        }
    }

    private var symbol: String {
        if state.isPluggedIn { return "battery.100percent.bolt" }
        switch state.percentage {
        case ..<5: return "battery.0percent"
        case ..<13: return "battery.25percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

extension BatteryMonitor.Event {
    var title: String {
        switch self {
        case .charging: "Charging"
        case .lowBattery: "Low Battery"
        case .lowPowerMode: "Low Power"
        }
    }

    /// Charging / low battery colours come from the shipped asset catalog.
    var color: Color {
        switch self {
        case .charging: Color("ChargingColor")
        case .lowBattery: Color("LowBatteryColor")
        case .lowPowerMode: .yellow
        }
    }
}
