import SwiftUI

/// Now playing beside the notch: artwork on the left, waveform on the right, and the quick-peek
/// row below the notch when the track changes (spec §2.4).
struct CompactNowPlayingView: View {
    let controller: NotchController
    private let media = MediaManager.shared
    private let tuning = Tuning.shared

    var body: some View {
        let info = media.nowPlaying
        let isPlaying = info?.isPlaying == true
        let artworkSize = min(20, controller.notchHeight - 8)

        VStack(spacing: 0) {
            // Edge insets measured from Alcove: artwork 7.5 pt in from the outer edge, waveform
            // 5.5 pt in from the other side.
            HStack(spacing: 0) {
                CompactArtwork(image: info?.artwork, size: artworkSize, isPlaying: isPlaying)
                    .padding(.leading, 7.5)
                Spacer(minLength: 0)
                CompactWaveform(
                    isPlaying: isPlaying,
                    seed: info?.waveformSeed ?? 0,
                    color: ArtworkTint.color(for: info?.artwork),
                    maxHeight: min(12, controller.notchHeight - 12)
                )
                .padding(.trailing, 5.5)
            }
            .frame(height: controller.notchHeight)

            if controller.isQuickPeeking, let info {
                QuickPeekRow(info: info)
                    .frame(height: controller.quickPeekHeight)
                    .transition(
                        .opacity
                            .combined(with: .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0)))
                    )
            }
        }
        .frame(width: controller.currentWidth, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// 20 pt artwork beside the notch: the player artwork scaled down (measured from Alcove).
private struct CompactArtwork: View {
    let image: NSImage?
    let size: CGFloat
    let isPlaying: Bool

    var body: some View {
        ArtworkView(image: image, box: size)
            // Paused art dims and shrinks (spec §9.6).
            .scaleEffect(isPlaying ? 1 : 0.85)
            .opacity(isPlaying ? 1 : 0.6)
            .animation(.spring(duration: 0.6, bounce: 0.4), value: isPlaying)
    }
}

private struct QuickPeekRow: View {
    let info: NowPlaying

    var body: some View {
        // One Text so title and artist truncate together instead of the artist vanishing.
        let title = Text(info.title.isEmpty ? "No Title" : info.title).foregroundStyle(.white)
        let artist = Text(info.artist.isEmpty ? "" : "  \(info.artist)").foregroundStyle(.white.opacity(0.55))
        (title + artist)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }
}
