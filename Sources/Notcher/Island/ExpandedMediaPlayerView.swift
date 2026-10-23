import SwiftUI

/// Expanded media player (spec §2.4, §9.6). Layout, sizes and colours are measured from Alcove
/// on a 345 × 175 pt island (values in points, from the island's top-left):
///
/// - artwork row: 56 pt box from y 18, artwork at x 18.5; title block ~23 pt lower (the
///   "compensates for notch" padding), at x 91; title 13.5 pt medium, artist 13 pt medium;
///   waveform centred on the artwork, 24.5 pt from the right edge
/// - progress row centred at y 94; controls row centred at y 135, five 40 pt slots
/// - the output button toggles a volume row centred at y 176 (+32 pt island height)
struct ExpandedMediaPlayerView: View {
    let controller: NotchController
    private let media = MediaManager.shared
    private let output = AudioOutput.shared

    var body: some View {
        let info = media.nowPlaying

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 15.5) {
                ZStack {
                    ArtworkView(image: info?.artwork, box: 56)
                        .id(info?.artwork.map(ObjectIdentifier.init))
                        .transition(.artworkFlip)
                }
                .animation(.default, value: info?.artwork.map(ObjectIdentifier.init))
                    // Paused art shrinks to 0.85 (spec §9.6).
                    .scaleEffect(info?.isPlaying == true ? 1 : 0.85)
                    .animation(.spring(duration: 0.6, bounce: 0.4), value: info?.isPlaying)
                    .onTapGesture { openSourceApp(info) }
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(
                            text: info.map { $0.title.isEmpty ? "No Title" : $0.title } ?? "Not Playing",
                            font: .system(size: 13.5, weight: .medium),
                            lineHeight: 17
                        )
                        Text(subtitle(info))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.47))
                            .lineLimit(1)
                    }
                    .id(trackKey(info))
                    .transition(.trackText)
                }
                // Measured from Alcove: the old text blurs out as the new one blurs in, ~0.25 s.
                .animation(.easeInOut(duration: 0.25), value: trackKey(info))
                .padding(.top, 22.5)
                CompactWaveform(
                    isPlaying: info?.isPlaying == true,
                    seed: info?.waveformSeed ?? 0,
                    color: ArtworkTint.color(for: info?.artwork),
                    maxHeight: 12.5,
                    spacing: 2
                )
                .frame(height: 56)
                .padding(.leading, 0.5)
                .opacity(info == nil ? 0 : 1)
            }
            .frame(height: 56)
            .padding(.leading, -2.5)
            .padding(.trailing, 3.5)

            Spacer().frame(height: 14)

            MediaProgressBar(info: info) { media.perform(.seek($0)) }
                .opacity(info == nil ? 0.35 : 1)
                .allowsHitTesting(info?.acceptsCommands == true)

            Spacer().frame(height: 19)

            PlaybackControls(
                isPlaying: info?.isPlaying == true,
                isShuffled: info?.isShuffled == true,
                isEnabled: info?.acceptsCommands == true,
                device: output.device,
                isShowingVolume: controller.showsOutputRow,
                skipProgress: controller.skipSwipeProgress,
                nextSkips: controller.nextTrackSkips,
                previousSkips: controller.previousTrackSkips,
                skip: { controller.skip(forward: $0) },
                perform: { media.perform($0) },
                toggleVolume: { controller.toggleVolumeRow() }
            )

            if controller.showsOutputRow {
                Spacer().frame(height: 20)
                VolumeRow(output: output)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.horizontal, 21)
        .padding(.top, 18)
        .frame(
            width: controller.notchExpandedWidth,
            height: controller.expandedContentHeight,
            alignment: .top
        )
        .environment(\.colorScheme, .dark)
    }

    private func trackKey(_ info: NowPlaying?) -> String {
        guard let info else { return "" }
        return [info.title, info.artist, info.album].joined(separator: "\u{1F}")
    }

    private func subtitle(_ info: NowPlaying?) -> String {
        guard let info else { return " " }
        if !info.artist.isEmpty { return info.artist }
        return info.appName ?? " "
    }

    /// "Show in": bring the source app forward.
    private func openSourceApp(_ info: NowPlaying?) {
        guard let bundleIdentifier = info?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Controls

/// Five evenly spaced 40 pt slots (sizes matched against Alcove): shuffle (17 pt semibold,
/// dimmed while off), previous/next (18 pt semibold), play/pause (28 pt semibold), and the
/// output device (18 pt medium), which toggles the volume row and then sits on a 48 × 46 pt
/// rounded highlight.
private struct PlaybackControls: View {
    let isPlaying: Bool
    let isShuffled: Bool
    let isEnabled: Bool
    let device: AudioOutput.Device?
    let isShowingVolume: Bool
    /// Skip-swipe progress, −1 (previous) … 1 (next).
    let skipProgress: CGFloat
    let nextSkips: Int
    let previousSkips: Int
    let skip: (_ forward: Bool) -> Void
    let perform: (MediaCommand) -> Void
    let toggleVolume: () -> Void

    var body: some View {
        // While a skip swipe is dragged (measured from Alcove): the target button follows the
        // fingers by up to ~3.5 pt and the other two main buttons dim to ~60 %.
        let next = max(skipProgress, 0)
        let previous = max(-skipProgress, 0)
        let dimmed = { (progress: CGFloat) in 1 - 0.45 * progress }

        HStack(spacing: 0) {
            Group {
                ControlButton(symbol: "shuffle", size: 17, opacity: isShuffled ? 1 : 0.5) { perform(.toggleShuffle) }
                Spacer(minLength: 0)
                ControlButton(action: { skip(false) }) {
                    SkipGlyph(forward: false, trigger: previousSkips)
                }
                .offset(x: -4 * previous)
                .opacity(dimmed(next))
                Spacer(minLength: 0)
                ControlButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 28) { perform(.togglePlayPause) }
                    .contentTransition(.symbolEffect(.replace))
                    // Play/pause symbol swap: Spring(0.35, +0.4) after 0.1 s (spec §3.1).
                    .animation(.spring(duration: 0.35, bounce: 0.4).delay(0.1), value: isPlaying)
                    .opacity(dimmed(abs(skipProgress)))
                Spacer(minLength: 0)
                ControlButton(action: { skip(true) }) {
                    SkipGlyph(forward: true, trigger: nextSkips)
                }
                .offset(x: 4 * next)
                .opacity(dimmed(previous))
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.35)
            Spacer(minLength: 0)
            ControlButton(
                symbol: device?.symbolName ?? "speaker.wave.2.fill",
                size: 18,
                weight: .medium,
                opacity: isShowingVolume ? 0.6 : 0.33,
                action: toggleVolume
            )
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(isShowingVolume ? 0.1 : 0))
                    .frame(width: 48, height: 46)
            }
            .help(device?.name ?? "")
            .disabled(device?.hasVolume != true)
        }
        .frame(height: 30)
    }
}

/// 40 × 30 control slot with a hover highlight and a springy press.
private struct ControlButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(.white)
                .frame(width: 40, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}

extension ControlButton where Label == AnyView {
    init(symbol: String, size: CGFloat, weight: Font.Weight = .semibold, opacity: Double = 1, action: @escaping () -> Void) {
        self.action = action
        label = AnyView(
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white.opacity(opacity))
        )
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule()
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : (isHovering ? 0.1 : 0)))
                    .frame(width: 44, height: 34)
                    .animation(.easeOut(duration: 0.1), value: isHovering)
            }
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            // Skip buttons: Spring(0.3, +0.25) (spec §3.1).
            .animation(.spring(duration: 0.3, bounce: 0.25), value: configuration.isPressed)
    }
}

// MARK: - Volume row

/// Revealed by the output button (measured from Alcove): speaker, a 230 pt slider in the
/// progress bar's greys, speaker with waves.
private struct VolumeRow: View {
    let output: AudioOutput

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? (output.isMuted ? 0 : Double(output.volume))
        // Slider spans x 56…286 pt; glyphs start 34.5 pt in and end ~8 pt from the content edge.
        HStack(spacing: 0) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 10)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(0.47))
                        .frame(width: max(6, proxy.size.width * shown))
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let fraction = min(max(drag.location.x / proxy.size.width, 0), 1)
                            dragValue = fraction
                            output.setVolume(Float(fraction))
                        }
                        .onEnded { _ in dragValue = nil }
                )
            }
            .frame(height: 12)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 9)
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: 12)
    }
}

// MARK: - Track change

private struct FlipModifier: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

private extension AnyTransition {
    /// New artwork flips in (measured from Alcove): the old cover turns edge-on in ~0.1 s,
    /// then the new one turns in from the other side.
    static var artworkFlip: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: FlipModifier(angle: -90), identity: FlipModifier(angle: 0))
                .animation(.easeOut(duration: 0.14).delay(0.11)),
            removal: .modifier(active: FlipModifier(angle: 90), identity: FlipModifier(angle: 0))
                .animation(.easeIn(duration: 0.11))
        )
    }

    /// Title and artist blur across to the new track.
    static var trackText: AnyTransition {
        .opacity.combined(with: .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0)))
    }
}
