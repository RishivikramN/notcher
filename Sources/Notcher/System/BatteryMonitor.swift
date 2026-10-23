import Foundation
import IOKit.ps

/// Battery state from IOKit power sources, plus Low Power Mode (spec §2.6).
/// Reports transitions only: plugging in, crossing the low-battery threshold on battery, and
/// turning Low Power Mode on.
@MainActor
final class BatteryMonitor {
    struct State: Equatable {
        /// 0…100.
        var percentage: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        var isLowPowerMode: Bool
    }

    enum Event: Equatable {
        case charging, lowBattery, lowPowerMode
    }

    private(set) var state: State?
    var onEvent: ((Event, State) -> Void)?

    /// Warn when the battery falls to this percentage (spec: configurable threshold).
    var lowBatteryThreshold = 20

    private var source: CFRunLoopSource?
    private var hasWarnedLow = false

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateDidChange),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        state = Self.read()
        hasWarnedLow = (state?.percentage ?? 100) <= lowBatteryThreshold
    }

    @objc private nonisolated func powerStateDidChange() {
        // Posted on an arbitrary thread.
        Task { @MainActor in self.refresh() }
    }

    fileprivate func refresh() {
        guard let new = Self.read() else { return }
        let old = state
        state = new
        guard let old else { return }

        if new.isPluggedIn, !old.isPluggedIn {
            onEvent?(.charging, new)
        }
        if new.isLowPowerMode, !old.isLowPowerMode {
            onEvent?(.lowPowerMode, new)
        }
        if new.isPluggedIn || new.percentage > lowBatteryThreshold {
            hasWarnedLow = false
        } else if !hasWarnedLow {
            hasWarnedLow = true
            onEvent?(.lowBattery, new)
        }
    }

    /// Nil on Macs without a battery.
    nonisolated static func read() -> State? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            return State(
                percentage: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return nil
    }
}

/// Called on the main run loop.
private func powerSourceCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.refresh() }
}
