import AppKit

/// How the island is rendered on a given screen.
enum DisplayMode: String, CaseIterable, Sendable {
    /// Sized to the real camera housing.
    case hardwareNotch
    /// A 140 pt black notch drawn under the menu bar on Macs without one.
    case simulatedNotch
    /// A 74 pt pill for displays without a notch.
    case pill

    var title: String {
        switch self {
        case .hardwareNotch: "Hardware Notch"
        case .simulatedNotch: "Simulated Notch"
        case .pill: "Pill"
        }
    }
}

/// Base sizes of the island for one screen, in points (spec §2.4).
struct NotchMetrics: Equatable, Sendable {
    var mode: DisplayMode
    /// Horizontal centre of the island in global screen coordinates.
    var midX: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var expandedWidth: CGFloat
    var expandedHeight: CGFloat
}

enum ScreenGeometry {
    static func hasHardwareNotch(_ screen: NSScreen) -> Bool {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, !left.isEmpty,
              let right = screen.auxiliaryTopRightArea, !right.isEmpty
        else { return false }
        return true
    }

    /// Menu bar height, or nil when the menu bar is hidden.
    static func menuBarHeight(_ screen: NSScreen) -> CGFloat? {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : nil
    }

    /// - Parameter modeOverride: forces a mode regardless of the hardware (debug only).
    /// - Parameter widthOffset/heightOffset: the user's notch size tuning, in points.
    static func metrics(
        for screen: NSScreen,
        forceSimulatedNotch: Bool,
        modeOverride: DisplayMode? = nil,
        widthOffset: CGFloat = 0,
        heightOffset: CGFloat = 0
    ) -> NotchMetrics {
        var metrics = baseMetrics(for: screen, forceSimulatedNotch: forceSimulatedNotch, modeOverride: modeOverride)
        metrics.notchWidth = max(metrics.notchWidth + widthOffset, 20)
        metrics.notchHeight = max(metrics.notchHeight + heightOffset, 10)
        return metrics
    }

    private static func baseMetrics(
        for screen: NSScreen,
        forceSimulatedNotch: Bool,
        modeOverride: DisplayMode?
    ) -> NotchMetrics {
        let mode = modeOverride ?? resolvedMode(for: screen, forceSimulatedNotch: forceSimulatedNotch)

        switch mode {
        case .hardwareNotch where hasHardwareNotch(screen):
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = screen.frame.width - left - right
            let height = screen.safeAreaInsets.top
            return NotchMetrics(
                mode: .hardwareNotch,
                midX: screen.frame.minX + left + width / 2,
                notchWidth: width,
                notchHeight: height,
                expandedWidth: min(width + 160, 345),
                expandedHeight: max(height + 142, 175)
            )

        case .hardwareNotch, .simulatedNotch:
            return NotchMetrics(
                mode: .simulatedNotch,
                midX: screen.frame.midX,
                notchWidth: 140,
                notchHeight: menuBarHeight(screen).map { $0 - 1 } ?? 24,
                expandedWidth: 345,
                expandedHeight: 175
            )

        case .pill:
            return NotchMetrics(
                mode: .pill,
                midX: screen.frame.midX,
                notchWidth: 74,
                notchHeight: menuBarHeight(screen).map { $0 - 5.5 } ?? 19.5,
                expandedWidth: 321,
                expandedHeight: 175
            )
        }
    }

    static func resolvedMode(for screen: NSScreen, forceSimulatedNotch: Bool) -> DisplayMode {
        if hasHardwareNotch(screen) { return .hardwareNotch }
        return forceSimulatedNotch ? .simulatedNotch : .pill
    }

    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
    }

    /// The display holding the menu bar (not `NSScreen.main`, which follows the key window).
    static var mainDisplayScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == CGMainDisplayID() } ?? NSScreen.screens.first
    }

    /// Displays that get an island for `choice`; a missing built-in or specific display falls
    /// back to the main display.
    static func screens(for choice: DisplayChoice) -> [NSScreen] {
        let fallback = mainDisplayScreen.map { [$0] } ?? []
        switch choice {
        case .builtIn: return builtInScreen.map { [$0] } ?? fallback
        case .main: return fallback
        case .all: return NSScreen.screens
        case .specific(let uuid): return NSScreen.screens.first { $0.displayUUID == uuid }.map { [$0] } ?? fallback
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
