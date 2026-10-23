import SwiftUI

/// The skip button's two arrows, animated like iOS on every skip (measured from Alcove at 57 fps):
/// the front arrow shrinks away in ~0.1 s, the back arrow slides into its place with a slight
/// overshoot (~0.25 s), and a new back arrow grows in from the left. Previous is the mirror image.
///
/// The arrows are identical shapes in a sliding window of ids, so each skip only moves the window
/// forward. Nothing resets afterwards, and quick repeated skips chain smoothly.
struct SkipGlyph: View {
    let forward: Bool
    /// Changes once per skip.
    let trigger: Int

    /// Matched to Alcove's skip glyph: two touching arrows 12.75 pt apart, drawn 14.6 × 17.8 pt so
    /// that with rounded corners each shows 12.75 × 15 pt.
    private let arrowSize = CGSize(width: 14.6, height: 17.8)
    private let spacing: CGFloat = 12.75

    /// Id of the back arrow; the front arrow is `back + 1`.
    @State private var back = 0

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach([back, back + 1], id: \.self) { id in
                SkipArrow()
                    .frame(width: arrowSize.width, height: arrowSize.height)
                    .offset(x: CGFloat(id - back) * spacing)
                    .transition(.skipArrow)
            }
        }
        // Framed to the visible arrows so the glyph centres like the symbol it replaces.
        .frame(width: spacing * 2, height: arrowSize.height, alignment: .leading)
        .scaleEffect(x: forward ? 1 : -1)
        // Both glyphs sit 1 pt right of centre in Alcove.
        .offset(x: 1)
        .onChange(of: trigger) {
            withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                back -= 1
            }
        }
    }
}

private extension AnyTransition {
    static var skipArrow: AnyTransition {
        .asymmetric(
            // The new back arrow grows in just behind its slot once the front one is going.
            insertion: .modifier(
                active: SkipArrowModifier(scale: 0.3, opacity: 0, x: -3),
                identity: SkipArrowModifier(scale: 1, opacity: 1, x: 0)
            )
            .animation(.spring(duration: 0.25, bounce: 0).delay(0.08)),
            // The old front arrow shrinks out where it stands.
            removal: .modifier(
                active: SkipArrowModifier(scale: 0.3, opacity: 0, x: 0),
                identity: SkipArrowModifier(scale: 1, opacity: 1, x: 0)
            )
            .animation(.easeIn(duration: 0.1))
        )
    }
}

private struct SkipArrowModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double
    let x: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(scale).opacity(opacity).offset(x: x)
    }
}

/// One rounded play-style arrow pointing right.
private struct SkipArrow: View {
    var body: some View {
        RoundedTriangle(cornerRadius: 1.8).fill(.foreground)
    }
}

private struct RoundedTriangle: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = CGPoint(x: rect.minX, y: rect.minY)
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        let bottom = CGPoint(x: rect.minX, y: rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addArc(tangent1End: top, tangent2End: tip, radius: cornerRadius)
        path.addArc(tangent1End: tip, tangent2End: bottom, radius: cornerRadius)
        path.addArc(tangent1End: bottom, tangent2End: top, radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}
