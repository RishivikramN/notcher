import AppKit

/// Which displays are showing a fullscreen Space (spec §9.4).
///
/// Uses the private `CGSCopyManagedDisplaySpaces`, reading each display's "Current Space" type
/// (bit 2 = fullscreen), as the shipped app does. Window geometry can't tell fullscreen from a
/// filled window on a notched display, where they differ by a point. If the symbols go away,
/// no display is reported as fullscreen.
@MainActor
final class FullscreenMonitor {
    /// Display UUIDs (see `NSScreen.displayUUID`) currently in a fullscreen Space.
    private(set) var fullscreenDisplays: Set<String> = []
    var onChange: ((Set<String>) -> Void)?

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let mainConnection: MainConnection?
    private let copySpaces: CopyManagedDisplaySpaces?
    private var recheckTask: Task<Void, Never>?

    init() {
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        mainConnection = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
        copySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(spaceMayHaveChanged),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceMayHaveChanged),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        check()
    }

    @objc private func spaceMayHaveChanged() {
        check()
        // The Space switch animates; read again once it has landed.
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    func check() {
        let displays = Self.read(mainConnection: mainConnection, copySpaces: copySpaces)
        guard displays != fullscreenDisplays else { return }
        fullscreenDisplays = displays
        onChange?(displays)
    }

    private static func read(mainConnection: MainConnection?, copySpaces: CopyManagedDisplaySpaces?) -> Set<String> {
        guard let mainConnection, let copySpaces,
              let spaces = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        var result: Set<String> = []
        for display in spaces {
            guard let current = display["Current Space"] as? [String: Any],
                  let type = current["type"] as? Int, type & 0b100 != 0,
                  let identifier = display["Display Identifier"] as? String
            else { continue }
            // "Main" appears when displays don't have separate Spaces.
            if identifier == "Main" {
                if let main = NSScreen.main?.displayUUID { result.insert(main) }
            } else {
                result.insert(identifier.uppercased())
            }
        }
        return result
    }
}

extension NSScreen {
    /// Stable identifier across reconnects and resolution changes.
    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return String(displayID)
        }
        return (CFUUIDCreateString(nil, uuid) as String).uppercased()
    }
}
