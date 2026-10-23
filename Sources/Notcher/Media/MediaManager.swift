import AppKit
import Observation

/// Collects now-playing data from every source and resolves the one the island shows.
@MainActor
@Observable
final class MediaManager {
    static let shared = MediaManager()

    private static let preferenceKey = "mediaSource"

    var preference: MediaSourcePreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
            notifyIfChanged()
        }
    }

    private(set) var snapshots: [MediaSourceKind: NowPlaying] = [:]
    private(set) var statuses: [MediaSourceKind: String] = [:]

    private let system = SystemMediaSource()
    private let music = ScriptedPlayerSource.music()
    private let spotify = ScriptedPlayerSource.spotify()
    private var isStarted = false

    /// Called with (old, new) whenever the resolved track or its play state changes.
    private var observers: [UUID: (NowPlaying?, NowPlaying?) -> Void] = [:]
    private var lastNotified: NowPlaying?

    private init() {
        preference = UserDefaults.standard.string(forKey: Self.preferenceKey)
            .flatMap(MediaSourcePreference.init(rawValue:)) ?? .automatic
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        system.onChange = { [weak self] in self?.update(.system, $0) }
        system.onStatusChange = { [weak self] in self?.statuses[.system] = $0.title }
        for source in [music, spotify] {
            let kind = source.kind
            source.onChange = { [weak self] in self?.update(kind, $0) }
            source.onStatusChange = { [weak self] in self?.statuses[kind] = $0.title }
            statuses[kind] = source.status.title
        }
        system.start()
        music.start()
        spotify.start()
    }

    func stop() {
        system.stop()
    }

    /// The previous cover, shown while a new track's artwork is still on its way (sources send
    /// the title first). Keeps the placeholder from flashing up between two covers.
    private var heldArtwork: (image: NSImage, until: Date)?
    private var heldArtworkTask: Task<Void, Never>?

    /// Shuffle state just set from the island, shown until the player confirms it (or 2 s pass).
    private var pendingShuffle: (value: Bool, until: Date)?

    /// What the island shows.
    var nowPlaying: NowPlaying? {
        var info: NowPlaying? = switch preference {
        case .system: snapshots[.system]
        case .music: snapshots[.music]
        case .spotify: snapshots[.spotify]
        case .automatic: automatic
        }
        // A fallback app (see SystemMediaSource) that is Music or Spotify comes from its scripted
        // source instead: MediaRemote's per-app snapshot has no artwork and a stale position, and
        // can't be controlled, while AppleScript has both and can.
        if let fallback = info, fallback.isFallback,
           let scripted = [snapshots[.music], snapshots[.spotify]].compactMap({ $0 })
               .first(where: { $0.bundleIdentifier == fallback.bundleIdentifier }) {
            info = scripted
        }
        // MediaRemote doesn't report shuffle for Music or Spotify; their scripted sources do.
        if info?.isShuffled == nil, let bundleIdentifier = info?.bundleIdentifier {
            info?.isShuffled = [snapshots[.music], snapshots[.spotify]]
                .compactMap { $0 }
                .first { $0.bundleIdentifier == bundleIdentifier }?
                .isShuffled
        }
        if let pendingShuffle, pendingShuffle.until > .now {
            info?.isShuffled = pendingShuffle.value
        }
        #if DEBUG
        if debugDryRun, let debugTrack { info = debugTrack }
        #endif
        if info != nil, info?.artwork == nil, let heldArtwork, heldArtwork.until > .now {
            info?.artwork = heldArtwork.image
        }
        return info
    }

    /// Automatic: the system source covers every app (browsers included). The scripted players
    /// are a fallback for when the adapter is unavailable, preferring whichever is playing.
    private var automatic: NowPlaying? {
        if let system = snapshots[.system] { return system }
        let scripted = [snapshots[.music], snapshots[.spotify]].compactMap { $0 }
        return scripted.first(where: \.isPlaying) ?? scripted.first
    }

    /// Sends a playback command to the source of the track the island shows.
    func perform(_ command: MediaCommand) {
        let current = nowPlaying
        #if DEBUG
        if debugDryRun {
            debugFakeSkip(command, current: current)
            return
        }
        #endif
        if command == .toggleShuffle {
            pendingShuffle = (!(current?.isShuffled ?? false), .now.addingTimeInterval(2))
            // Players don't announce shuffle changes; re-read them once the command lands.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                self.music.refresh()
                self.spotify.refresh()
                self.pendingShuffle = nil
            }
        }
        switch current?.source {
        case .system: system.perform(command, current: current)
        case .music: music.perform(command, current: current)
        case .spotify: spotify.perform(command, current: current)
        case nil: break
        }
    }

    #if DEBUG
    /// Debug/testing: replace the system snapshot without real playback.
    func debugInject(_ info: NowPlaying?) {
        update(.system, info)
    }

    /// Debug: commands never reach a player; skips swap in a made-up track with its own artwork,
    /// so skip animations can be tested without touching what the user is listening to.
    var debugDryRun = false {
        didSet {
            if !debugDryRun { debugTrack = nil }
            notifyIfChanged()
        }
    }
    private var debugTrack: NowPlaying?
    private var debugTrackNumber = 0

    private func debugFakeSkip(_ command: MediaCommand, current: NowPlaying?) {
        guard command == .nextTrack || command == .previousTrack, var track = current else { return }
        debugTrackNumber += command == .nextTrack ? 1 : -1
        let hue = CGFloat((debugTrackNumber % 6 + 6) % 6) / 6
        track.title = "Debug Track \(debugTrackNumber)"
        track.artist = "Notcher dry run"
        track.album = "Dry run"
        track.elapsed = 0
        track.timestamp = .now
        let artwork = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            rect.fill()
            NSColor.white.setFill()
            NSRect(x: 40, y: 40, width: 90, height: 220).fill()
            return true
        }
        // Like real sources, the title arrives first and the artwork a moment later.
        let previousArtwork = nowPlaying?.artwork
        track.artwork = nil
        debugTrack = track
        holdArtworkIfMissing(previous: previousArtwork)
        notifyIfChanged()
        let number = debugTrackNumber
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, number == self.debugTrackNumber else { return }
            self.debugTrack?.artwork = artwork
            self.holdArtworkIfMissing(previous: nil)
            self.notifyIfChanged()
        }
    }
    #endif

    /// Returns a token for `removeObserver`.
    @discardableResult
    func addObserver(_ observer: @escaping (_ old: NowPlaying?, _ new: NowPlaying?) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(nil, nowPlaying)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func update(_ kind: MediaSourceKind, _ info: NowPlaying?) {
        let previousArtwork = nowPlaying?.artwork
        snapshots[kind] = info
        holdArtworkIfMissing(previous: previousArtwork)
        notifyIfChanged()
    }

    private func holdArtworkIfMissing(previous: NSImage?) {
        guard let current = nowPlaying else {
            heldArtwork = nil
            return
        }
        // A real cover arrived (or nothing to hold): stop holding.
        guard current.artwork == nil || current.artwork === heldArtwork?.image else {
            heldArtwork = nil
            heldArtworkTask?.cancel()
            return
        }
        guard heldArtwork == nil, let previous else { return }
        // Give the new cover 1.5 s to arrive; a track that has none then shows the placeholder.
        heldArtwork = (previous, .now.addingTimeInterval(1.5))
        heldArtworkTask?.cancel()
        heldArtworkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.heldArtwork = nil
            self.notifyIfChanged()
        }
    }

    private func notifyIfChanged() {
        let new = nowPlaying
        let old = lastNotified
        if old == nil, new == nil { return }
        if let old, let new, new.isSameTrack(as: old), new.isPlaying == old.isPlaying,
           new.source == old.source, (new.artwork == nil) == (old.artwork == nil) {
            lastNotified = new
            return
        }
        lastNotified = new
        for observer in observers.values { observer(old, new) }
    }
}
