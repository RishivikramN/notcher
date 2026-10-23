import Foundation
import Observation
import ServiceManagement

/// Which displays get an island (spec §2.1 "Display on").
enum DisplayChoice: Hashable {
    case builtIn
    case main
    case all
    /// A specific display, by `CGDisplayCreateUUIDFromDisplayID` string.
    case specific(String)

    var storageValue: String {
        switch self {
        case .builtIn: "builtIn"
        case .main: "main"
        case .all: "all"
        case .specific(let uuid): "uuid:" + uuid
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "main": self = .main
        case "all": self = .all
        case let value where value.hasPrefix("uuid:"): self = .specific(String(value.dropFirst(5)))
        default: self = .builtIn
        }
    }
}

/// How the volume HUD shows the output device (spec §2.5).
enum OutputDeviceStyle: String, CaseIterable {
    /// The device: AirPods render or the device's symbol.
    case device
    /// Always a speaker symbol.
    case symbol
}

/// User settings, persisted in UserDefaults. Key names follow the shipped app where known.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: General

    var expandOnHover: Bool { didSet { set(expandOnHover, "expandNotchOnHover") } }
    /// Seconds between hover and expansion (spec default 0).
    var hoverDuration: Double { didSet { set(hoverDuration, "hoverDuration") } }
    var hapticFeedback: Bool { didSet { set(hapticFeedback, "enableHaptics") } }
    var hideMenuBarIcon: Bool { didSet { set(hideMenuBarIcon, "hideMenuBarIcon") } }
    var hideInFullscreen: Bool { didSet { set(hideInFullscreen, "hideInFullscreen") } }

    // MARK: Gestures (spec §2.3, §5.2)

    var swipeToToggle: Bool { didSet { set(swipeToToggle, "swipeToToggle") } }
    var swipeToSkip: Bool { didSet { set(swipeToSkip, "swipeToSkip") } }
    var swipeToDismiss: Bool { didSet { set(swipeToDismiss, "swipeToDismiss") } }
    /// The island follows the fingers. Off, it follows the system scroll direction instead.
    var naturalMovement: Bool { didSet { set(naturalMovement, "naturalMovement") } }

    // MARK: Display

    var displayChoice: DisplayChoice { didSet { set(displayChoice.storageValue, "showOnDisplay") } }
    var forceSimulatedNotch: Bool { didSet { set(forceSimulatedNotch, "forceSimulatedNotch") } }
    /// Points added to the detected notch size (spec §2.1 "Tuning").
    var notchWidthOffset: Double { didSet { set(notchWidthOffset, "notchAdjustedWidth") } }
    var notchHeightOffset: Double { didSet { set(notchHeightOffset, "notchAdjustedHeight") } }

    // MARK: Now Playing

    var quickPeek: Bool { didSet { set(quickPeek, "enableQuickPeek") } }
    var peekDuration: Double { didSet { set(peekDuration, "peekDuration") } }
    /// How long a paused track stays beside the notch.
    var idleDuration: Double { didSet { set(idleDuration, "idleDuration") } }

    // MARK: Sound

    var enableVolumeHUD: Bool { didSet { set(enableVolumeHUD, "enableVolume") } }
    var volumeOutputDevice: OutputDeviceStyle { didSet { set(volumeOutputDevice.rawValue, "volumeOutputDevice") } }
    /// AirPods as their looping 3D render; off uses the AirPods symbol.
    var airPodsRenders: Bool { didSet { set(airPodsRenders, "airPodsRenders") } }
    var hudDuration: Double { didSet { set(hudDuration, "volumeDuration") } }

    // MARK: Battery

    var notifyCharging: Bool { didSet { set(notifyCharging, "notifyCharging") } }
    var warnOnLowBattery: Bool { didSet { set(warnOnLowBattery, "warnOnLowBattery") } }
    var lowBatteryThreshold: Int { didSet { set(lowBatteryThreshold, "lowBatteryThreshold") } }
    var notifyLowPowerMode: Bool { didSet { set(notifyLowPowerMode, "notifyOnLowPowerMode") } }
    var batteryDuration: Double { didSet { set(batteryDuration, "batteryDuration") } }

    // MARK: Connectivity (spec §2.7)

    var enableConnectivity: Bool { didSet { set(enableConnectivity, "enableConnectivity") } }
    var connectivityDuration: Double { didSet { set(connectivityDuration, "connectivityDuration") } }
    /// The battery ring turns red at or below this level.
    var lowConnectBatteryThreshold: Int { didSet { set(lowConnectBatteryThreshold, "lowConnectBatteryThreshold") } }

    // MARK: Launch at login

    /// Backed by SMAppService rather than UserDefaults, so it reflects System Settings.
    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Notcher: launch at login change failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        // Values first set in the BP2–BP7 Tuning window carry over.
        let tuning = (d.data(forKey: "debug.tuning"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        func bool(_ key: String, _ fallback: Bool, tuning tuningKey: String? = nil) -> Bool {
            d.object(forKey: key) as? Bool ?? tuningKey.flatMap { tuning[$0] as? Bool } ?? fallback
        }
        func double(_ key: String, _ fallback: Double, tuning tuningKey: String? = nil) -> Double {
            d.object(forKey: key) as? Double ?? tuningKey.flatMap { tuning[$0] as? Double } ?? fallback
        }

        expandOnHover = bool("expandNotchOnHover", true, tuning: "expandOnHover")
        hoverDuration = double("hoverDuration", 0, tuning: "hoverDuration")
        hapticFeedback = bool("enableHaptics", true, tuning: "hapticsOnHover")
        hideMenuBarIcon = bool("hideMenuBarIcon", false)
        hideInFullscreen = bool("hideInFullscreen", true)

        swipeToToggle = bool("swipeToToggle", true)
        swipeToSkip = bool("swipeToSkip", true)
        swipeToDismiss = bool("swipeToDismiss", true)
        naturalMovement = bool("naturalMovement", true)

        displayChoice = DisplayChoice(storageValue: d.string(forKey: "showOnDisplay") ?? "builtIn")
        forceSimulatedNotch = bool("forceSimulatedNotch", false)
        notchWidthOffset = double("notchAdjustedWidth", 0)
        notchHeightOffset = double("notchAdjustedHeight", 0)

        quickPeek = bool("enableQuickPeek", true)
        peekDuration = double("peekDuration", 2, tuning: "peekDuration")
        idleDuration = double("idleDuration", 5, tuning: "idleDuration")

        enableVolumeHUD = bool("enableVolume", true)
        volumeOutputDevice = d.string(forKey: "volumeOutputDevice").flatMap(OutputDeviceStyle.init(rawValue:))
            ?? ((tuning["hudShowsDevice"] as? Bool) == false ? .symbol : .device)
        airPodsRenders = bool("airPodsRenders", true, tuning: "hudUsesRenders")
        hudDuration = double("volumeDuration", 1.5, tuning: "hudDuration")

        notifyCharging = bool("notifyCharging", true)
        warnOnLowBattery = bool("warnOnLowBattery", true)
        lowBatteryThreshold = d.object(forKey: "lowBatteryThreshold") as? Int ?? 20
        notifyLowPowerMode = bool("notifyOnLowPowerMode", true)
        batteryDuration = double("batteryDuration", 3, tuning: "batteryDuration")

        enableConnectivity = bool("enableConnectivity", true)
        // Measured from Alcove: the popup stays ~5 s.
        connectivityDuration = double("connectivityDuration", 5)
        lowConnectBatteryThreshold = d.object(forKey: "lowConnectBatteryThreshold") as? Int ?? 20

        persistAll()
    }

    /// Writes every value once, so ones carried over from the Tuning window stick even after
    /// Tuning rewrites its own storage.
    private func persistAll() {
        set(expandOnHover, "expandNotchOnHover")
        set(hoverDuration, "hoverDuration")
        set(hapticFeedback, "enableHaptics")
        set(hideMenuBarIcon, "hideMenuBarIcon")
        set(hideInFullscreen, "hideInFullscreen")
        set(swipeToToggle, "swipeToToggle")
        set(swipeToSkip, "swipeToSkip")
        set(swipeToDismiss, "swipeToDismiss")
        set(naturalMovement, "naturalMovement")
        set(displayChoice.storageValue, "showOnDisplay")
        set(forceSimulatedNotch, "forceSimulatedNotch")
        set(notchWidthOffset, "notchAdjustedWidth")
        set(notchHeightOffset, "notchAdjustedHeight")
        set(quickPeek, "enableQuickPeek")
        set(peekDuration, "peekDuration")
        set(idleDuration, "idleDuration")
        set(enableVolumeHUD, "enableVolume")
        set(volumeOutputDevice.rawValue, "volumeOutputDevice")
        set(airPodsRenders, "airPodsRenders")
        set(hudDuration, "volumeDuration")
        set(notifyCharging, "notifyCharging")
        set(warnOnLowBattery, "warnOnLowBattery")
        set(lowBatteryThreshold, "lowBatteryThreshold")
        set(notifyLowPowerMode, "notifyOnLowPowerMode")
        set(batteryDuration, "batteryDuration")
        set(enableConnectivity, "enableConnectivity")
        set(connectivityDuration, "connectivityDuration")
        set(lowConnectBatteryThreshold, "lowConnectBatteryThreshold")
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
