import SwiftUI

/// The island outline (spec §9.2).
///
/// In `.notch` style the rect includes room for two concave "ears" of width `topCornerRadius`
/// on each side, so the black body is `rect.width − 2 × topR` wide and flares into the menu bar
/// like the hardware notch. In `.pill` style it is a plain capsule.
struct NotchShape: Shape {
    enum Style: Sendable { case notch, pill }

    var style: Style
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    /// Ear width actually used for a given height, so callers can size the frame.
    static func earWidth(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat, height: CGFloat) -> CGFloat {
        let bottomR = min(bottomCornerRadius, height)
        return max(0, min(topCornerRadius, 24, height - bottomR))
    }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .pill:
            return Capsule(style: .continuous).path(in: rect)
        case .notch:
            return notchPath(in: rect)
        }
    }

    private func notchPath(in rect: CGRect) -> Path {
        let topR = Self.earWidth(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            height: rect.height
        )
        let body = rect.insetBy(dx: topR, dy: 0)
        let bottomR = min(bottomCornerRadius, body.width / 2, body.height)

        var path = UnevenRoundedRectangle(
            bottomLeadingRadius: bottomR,
            bottomTrailingRadius: bottomR,
            style: .continuous
        ).path(in: body)

        guard topR > 0 else { return path }

        // Each ear is a topR square whose inner corner meets the body; a concave arc runs from
        // the menu bar edge down into the body's side. The 0.5 pt overlap avoids a hairline seam.
        let overlap: CGFloat = 0.5
        var ears = Path()

        ears.move(to: CGPoint(x: body.minX + overlap, y: rect.minY))
        ears.addLine(to: CGPoint(x: body.minX + overlap, y: rect.minY + topR))
        ears.addLine(to: CGPoint(x: body.minX, y: rect.minY + topR))
        ears.addArc(
            tangent1End: CGPoint(x: body.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: topR
        )
        ears.closeSubpath()

        ears.move(to: CGPoint(x: body.maxX - overlap, y: rect.minY))
        ears.addLine(to: CGPoint(x: body.maxX - overlap, y: rect.minY + topR))
        ears.addLine(to: CGPoint(x: body.maxX, y: rect.minY + topR))
        ears.addArc(
            tangent1End: CGPoint(x: body.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: topR
        )
        ears.closeSubpath()

        path = Path(path.cgPath.union(ears.cgPath))
        return path
    }
}
