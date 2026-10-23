import AppKit
import SwiftUI

/// Debug readout of every media source, opened from the menu bar item (BP4).
@MainActor
final class NowPlayingDebugWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Now Playing (Debug)"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: NowPlayingDebugView(media: .shared)
            )
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct NowPlayingDebugView: View {
    @Bindable var media: MediaManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Form {
                Section("Shown on the island") {
                    Picker("Media source", selection: $media.preference) {
                        ForEach(MediaSourcePreference.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if let info = media.nowPlaying {
                        NowPlayingRow(info: info, now: context.date)
                    } else {
                        Text("Nothing playing").foregroundStyle(.secondary)
                    }
                }
                ForEach(MediaSourceKind.allCases, id: \.self) { kind in
                    Section(kind.title) {
                        LabeledContent("Status", value: media.statuses[kind] ?? "—")
                        if let info = media.snapshots[kind] {
                            NowPlayingRow(info: info, now: context.date)
                        } else {
                            Text("No data").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        // A grouped Form has no ideal height; see TuningView.
        .frame(width: 440, height: 640)
    }
}

private struct NowPlayingRow: View {
    let info: NowPlaying
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let artwork = info.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.headline).lineLimit(1)
                Text(info.artist.isEmpty ? "—" : info.artist).lineLimit(1)
                Text(info.album.isEmpty ? "—" : info.album).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: info.isPlaying ? "play.fill" : "pause.fill")
                    Text(position)
                        .monospacedDigit()
                }
                .font(.caption)
                Text("\(info.appName ?? "?") · \(info.bundleIdentifier ?? "?")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("updated \(info.receivedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var position: String {
        let elapsed = info.elapsed(at: now).map(Self.format) ?? "—"
        let duration = info.duration.map(Self.format) ?? "—"
        return "\(elapsed) / \(duration)"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
