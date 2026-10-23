import SwiftUI

/// Animatable blur, used as `.modifier(active: Blur(4), identity: Blur(0))` (spec §3.6).
struct BlurModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    /// House style for content entering the expanded island: scale 0.6 + blur 4 + fade,
    /// slightly delayed relative to the shape; it leaves on a shorter spring (spec §3.5, §3.6).
    @MainActor
    static func expandedContent(_ tuning: Tuning) -> AnyTransition {
        let base = AnyTransition.scale(scale: 0.6, anchor: .center)
            .combined(with: .opacity)
            .combined(with: .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0)))
        let delay = tuning.values.contentDelay * tuning.timeScale
        return .asymmetric(
            insertion: base.animation(tuning.contentAnimation.delay(delay)),
            removal: base.animation(tuning.contentRemovalAnimation)
        )
    }
}

extension AnyTransition {
    /// Compact content beside the notch: same house style, presented with
    /// Spring(0.35, +0.3) and dismissed with the overdamped Spring(0.35, −0.2) (spec §3.1).
    @MainActor
    static func compactContent(_ tuning: Tuning) -> AnyTransition {
        let base = AnyTransition.scale(scale: 0.6, anchor: .center)
            .combined(with: .opacity)
            .combined(with: .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0)))
        return .asymmetric(
            insertion: base.animation(tuning.presentAnimation),
            removal: base.animation(tuning.contentRemovalAnimation)
        )
    }
}
