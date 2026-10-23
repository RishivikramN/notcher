import SwiftUI

/// Simulated waveform (spec §3.9): deterministic pseudo-random bar heights seeded per track,
/// redrawn at a low 24 fps and paused entirely when nothing is playing.
///
/// Geometry measured from Alcove: 6 bars, 2 pt wide, up to 12 pt tall; 1.5 pt gaps beside the
/// notch, 2 pt gaps in the expanded player.
struct CompactWaveform: View {
    let isPlaying: Bool
    let seed: UInt64
    let color: Color
    var maxHeight: CGFloat = 12
    var spacing: CGFloat = 1.5

    private let barCount = 6
    private let barWidth: CGFloat = 2
    private let minHeight: CGFloat = 1
    private let pausedHeight: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(bar: index, time: time))
                }
            }
            .frame(height: maxHeight)
        }
        .animation(.spring(response: 0.35, dampingFraction: 1), value: isPlaying)
    }

    /// Each bar eases between random targets on its own period, so bars never move in lockstep.
    private func height(bar: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return pausedHeight }
        let period = 0.14 + 0.035 * Double(bar % 3)
        let x = time / period + Double(bar) * 0.37
        let step = x.rounded(.down)
        let t = x - step
        let eased = t * t * (3 - 2 * t)
        let from = random(bar: bar, step: Int64(step))
        let to = random(bar: bar, step: Int64(step) + 1)
        let value = from + (to - from) * eased
        return minHeight + CGFloat(value) * (maxHeight - minHeight)
    }

    private func random(bar: Int, step: Int64) -> Double {
        var state = seed &+ UInt64(bar) &* 0x9e37_79b9_7f4a_7c15 &+ UInt64(bitPattern: step)
        return Double(Self.splitMix64(&state) >> 11) / Double(1 << 53)
    }

    /// SplitMix64, the generator the shipped app seeds per track (spec §3.9).
    private static func splitMix64(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

extension NowPlaying {
    /// Stable per-track seed for the simulated waveform (FNV-1a over title and artist).
    var waveformSeed: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (title + "\u{1F}" + artist).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}
