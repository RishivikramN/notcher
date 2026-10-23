import AppKit

/// Where now-playing data comes from.
enum MediaSourceKind: String, CaseIterable, Sendable {
    /// Any app reporting now-playing info (MediaRemote, through the adapter), including browsers.
    case system
    case music
    case spotify

    var title: String {
        switch self {
        case .system: "System"
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

/// The user's media source setting (spec §2.4).
enum MediaSourcePreference: String, CaseIterable, Sendable {
    case automatic, music, spotify, system

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .music: "Music"
        case .spotify: "Spotify"
        case .system: "System"
        }
    }
}

/// A playback command, routed to whichever source the island is showing.
enum MediaCommand: Equatable, Sendable {
    case togglePlayPause
    case toggleShuffle
    case nextTrack
    case previousTrack
    /// Absolute position in seconds.
    case seek(TimeInterval)
    /// Relative jump in seconds (±15 / 30 for podcasts).
    case skip(TimeInterval)
}

/// One snapshot of what is playing.
struct NowPlaying: Equatable {
    var source: MediaSourceKind
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    /// Elapsed time as of `timestamp`.
    var elapsed: TimeInterval?
    var timestamp: Date
    var playbackRate: Double
    var isPlaying: Bool
    var artwork: NSImage?
    var bundleIdentifier: String?
    var appName: String?
    /// Nil when the player doesn't report shuffle.
    var isShuffled: Bool?
    /// Shown because the now-playing app is paused while this app plays. MediaRemote can't
    /// send it commands, so controls are disabled.
    var isFallback = false

    var acceptsCommands: Bool { !isFallback }
    /// When this snapshot was received.
    var receivedAt = Date.now

    /// Elapsed time extrapolated to `date` while playing.
    func elapsed(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard isPlaying else { return elapsed }
        let rate = playbackRate > 0 ? playbackRate : 1
        let value = elapsed + date.timeIntervalSince(timestamp) * rate
        if let duration, duration > 0 { return min(max(value, 0), duration) }
        return max(value, 0)
    }

    /// Same track, ignoring playback position and state.
    func isSameTrack(as other: NowPlaying?) -> Bool {
        guard let other else { return false }
        return title == other.title && artist == other.artist && album == other.album
    }
}

extension NowPlaying {
    /// "1:05", or "1:02:05" past an hour.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
