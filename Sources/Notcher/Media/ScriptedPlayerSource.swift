import AppKit

/// Music or Spotify through AppleScript (Automation permission).
///
/// Both players post a distributed notification on every play/pause/track change, so the source
/// only runs its script then (and when the app launches or quits) instead of polling. Scripts run
/// only while the app is running, so they never launch it, and only once Automation is granted:
/// the consent prompt blocks the asking thread, so it is requested off the main thread.
@MainActor
final class ScriptedPlayerSource {
    enum Status: Equatable {
        case notRunning, ok, awaitingPermission, notAuthorized, error(String)

        var title: String {
            switch self {
            case .notRunning: "App not running"
            case .ok: "OK"
            case .awaitingPermission: "Waiting for Automation permission"
            case .notAuthorized: "Automation permission denied"
            case .error(let message): "Error: \(message)"
            }
        }
    }

    let kind: MediaSourceKind
    let bundleIdentifier: String
    private let notificationName: String
    private let infoScript: NSAppleScript?
    private let artworkScript: NSAppleScript?

    private(set) var status: Status = .notRunning {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    var onChange: ((NowPlaying?) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private var current: NowPlaying?
    private var artworkTrack: NowPlaying?
    private var artworkURL: String?
    private var refreshTask: Task<Void, Never>?
    private var isRequestingPermission = false

    static func music() -> ScriptedPlayerSource {
        ScriptedPlayerSource(
            kind: .music,
            bundleIdentifier: "com.apple.Music",
            notificationName: "com.apple.Music.playerInfo",
            infoSource: """
            tell application id "com.apple.Music"
                set ps to player state as string
                if ps is "stopped" then return {ps}
                set t to current track
                return {ps, name of t, artist of t, album of t, duration of t, player position, shuffle enabled}
            end tell
            """,
            artworkSource: """
            tell application id "com.apple.Music" to get raw data of artwork 1 of current track
            """
        )
    }

    static func spotify() -> ScriptedPlayerSource {
        ScriptedPlayerSource(
            kind: .spotify,
            bundleIdentifier: "com.spotify.client",
            notificationName: "com.spotify.client.PlaybackStateChanged",
            infoSource: """
            tell application id "com.spotify.client"
                set ps to player state as string
                if ps is "stopped" then return {ps}
                set t to current track
                return {ps, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t, shuffling}
            end tell
            """,
            artworkSource: nil
        )
    }

    private init(
        kind: MediaSourceKind,
        bundleIdentifier: String,
        notificationName: String,
        infoSource: String,
        artworkSource: String?
    ) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.notificationName = notificationName
        infoScript = NSAppleScript(source: infoSource)
        artworkScript = artworkSource.flatMap(NSAppleScript.init(source:))
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoDidChange),
            name: Notification.Name(notificationName),
            object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appsDidChange(_:)),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appsDidChange(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refresh()
    }

    var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    @objc private func playerInfoDidChange() {
        scheduleRefresh()
    }

    @objc private func appsDidChange(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == bundleIdentifier else { return }
        // Give a launching app a moment before scripting it.
        scheduleRefresh(after: .seconds(1))
    }

    private func scheduleRefresh(after delay: Duration = .milliseconds(50)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard isAppRunning else {
            status = .notRunning
            publish(nil)
            return
        }
        guard let infoScript else { return }

        switch Self.automationPermission(for: bundleIdentifier, askIfNeeded: false) {
        case -1743: // errAEEventNotPermitted
            status = .notAuthorized
            publish(nil)
            return
        case -1744: // errAEEventWouldRequireUserConsent
            status = .awaitingPermission
            publish(nil)
            requestPermission()
            return
        default:
            break
        }

        var error: NSDictionary?
        let result = infoScript.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user denied Automation; -600: the app quit mid-call.
            status = switch number {
            case -1743: .notAuthorized
            case -600: .notRunning
            default: .error(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number)")
            }
            publish(nil)
            return
        }
        status = .ok

        let items = (1...max(result.numberOfItems, 1)).compactMap { result.atIndex($0) }
        guard let state = items.first?.stringValue, state != "stopped", items.count >= 6 else {
            publish(nil)
            return
        }

        var info = NowPlaying(
            source: kind,
            title: items[1].stringValue ?? "",
            artist: items[2].stringValue ?? "",
            album: items[3].stringValue ?? "",
            duration: Self.number(items[4]),
            elapsed: Self.number(items[5]),
            timestamp: .now,
            playbackRate: state == "playing" ? 1 : 0,
            isPlaying: state == "playing",
            artwork: nil,
            bundleIdentifier: bundleIdentifier,
            appName: kind.title,
            isShuffled: items.last.flatMap { $0.descriptorType == typeTrue || $0.descriptorType == typeFalse || $0.descriptorType == typeBoolean ? $0.booleanValue : nil }
        )

        if info.isSameTrack(as: artworkTrack) {
            info.artwork = artworkTrack?.artwork
        } else {
            artworkTrack = info
            artworkTrack?.artwork = nil
            if let artworkScript {
                info.artwork = fetchArtwork(with: artworkScript)
                artworkTrack?.artwork = info.artwork
            } else if items.count >= 7, let url = items[6].stringValue {
                loadArtwork(from: url, for: info)
            }
        }
        publish(info)
    }

    private func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        let bundleIdentifier = bundleIdentifier
        Task { [weak self] in
            _ = await Task.detached {
                Self.automationPermission(for: bundleIdentifier, askIfNeeded: true)
            }.value
            guard let self else { return }
            self.isRequestingPermission = false
            self.refresh()
        }
    }

    private nonisolated static func automationPermission(for bundleIdentifier: String, askIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let desc = target.aeDesc else { return OSStatus(-1) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askIfNeeded)
    }

    func perform(_ command: MediaCommand, current: NowPlaying?) {
        guard isAppRunning, status == .ok else { return }
        let body: String
        switch command {
        case .togglePlayPause: body = "playpause"
        case .toggleShuffle:
            body = kind == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"
        case .nextTrack: body = "next track"
        case .previousTrack: body = "previous track"
        case .seek(let seconds): body = "set player position to \(max(seconds, 0))"
        case .skip(let delta):
            guard let elapsed = current?.elapsed(at: .now) else { return }
            body = "set player position to \(max(elapsed + delta, 0))"
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"\(bundleIdentifier)\" to \(body)")?
            .executeAndReturnError(&error)
        // The player's notification refreshes most changes; a seek may not post one.
        scheduleRefresh(after: .milliseconds(150))
    }

    private func publish(_ info: NowPlaying?) {
        current = info
        onChange?(info)
    }

    private func fetchArtwork(with script: NSAppleScript) -> NSImage? {
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return NSImage(data: descriptor.data)
    }

    /// Spotify only exposes an artwork URL.
    private func loadArtwork(from urlString: String, for track: NowPlaying) {
        guard let url = URL(string: urlString), urlString != artworkURL else { return }
        artworkURL = urlString
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  let self, track.isSameTrack(as: self.current)
            else { return }
            self.artworkTrack?.artwork = image
            self.current?.artwork = image
            self.onChange?(self.current)
        }
    }

    private static func number(_ descriptor: NSAppleEventDescriptor) -> Double? {
        if let string = descriptor.stringValue, let value = Double(string) { return value }
        let value = descriptor.doubleValue
        return value.isFinite && value != 0 ? value : nil
    }
}
