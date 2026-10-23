import SwiftUI

/// Elapsed / remaining labels around a scrubbable progress track (spec §9.6: 12 pt track).
/// Measured from Alcove on screen: 6 pt bar, white 15 % track with a 47 % fill, 10 pt medium monospaced
/// labels at 46 %, 10 pt between labels and track.
/// Live streams without a duration show a "Live" badge instead.
struct MediaProgressBar: View {
    let info: NowPlaying?
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    /// The released scrub position, held until the player reports the new position.
    @State private var pendingSeek: (fraction: Double, at: Date)?
    @State private var isHovering = false

    private var duration: TimeInterval? {
        guard let duration = info?.duration, duration > 0 else { return nil }
        return duration
    }

    var body: some View {
        if info != nil, duration == nil {
            liveBadge
        } else {
            TimelineView(.animation(minimumInterval: 0.25, paused: info?.isPlaying != true && dragFraction == nil)) { context in
                let shown = shownFraction(at: context.date)
                HStack(spacing: 10) {
                    timeLabel(NowPlaying.format(shown * (duration ?? 0)))
                    track(fraction: shown)
                    timeLabel("-" + NowPlaying.format((1 - shown) * (duration ?? 0)))
                }
            }
        }
    }

    private func track(fraction: Double) -> some View {
        let isActive = dragFraction != nil || isHovering
        let height: CGFloat = isActive ? 8 : 6
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.white.opacity(isActive ? 1 : 0.47))
                    .frame(width: max(height, proxy.size.width * fraction))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration != nil else { return }
                        dragFraction = Self.clamp(value.location.x / proxy.size.width)
                    }
                    .onEnded { value in
                        guard let duration else { return }
                        let fraction = Self.clamp(value.location.x / proxy.size.width)
                        pendingSeek = (fraction, .now)
                        dragFraction = nil
                        onSeek(fraction * duration)
                    }
            )
            .onHover { isHovering = $0 }
            // The shipped app's progress layer uses exactly spring(response: 0.15, dampingFraction: 1).
            .animation(.spring(response: 0.15, dampingFraction: 1), value: isActive)
        }
        .frame(height: 12)
    }

    private func shownFraction(at date: Date) -> Double {
        if let dragFraction { return dragFraction }
        let live = liveFraction(at: date)
        if let pendingSeek, date.timeIntervalSince(pendingSeek.at) < 1.5,
           abs(live - pendingSeek.fraction) * (duration ?? 0) > 2 {
            return pendingSeek.fraction
        }
        return live
    }

    private func liveFraction(at date: Date) -> Double {
        guard let info, let duration, let elapsed = info.elapsed(at: date) else { return 0 }
        return Self.clamp(elapsed / duration)
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.46))
            .fixedSize()
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 12)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
