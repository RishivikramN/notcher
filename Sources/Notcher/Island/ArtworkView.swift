import SwiftUI

/// Artwork aspect-fitted in a square box (spec §9.6, matched against Alcove).
///
/// The corner radius is 12 pt at the player's 56 pt and scales with the box (≈4.3 pt at the
/// compact 20 pt). Non-square art uses `min(r, r / (w / h))` so the curve looks the same.
struct ArtworkView: View {
    let image: NSImage?
    let box: CGFloat

    var body: some View {
        let baseRadius = 12 * box / 56
        Group {
            if let image, image.size.width > 0, image.size.height > 0 {
                let aspect = image.size.width / image.size.height
                let fitted = aspect >= 1
                    ? CGSize(width: box, height: box / aspect)
                    : CGSize(width: box * aspect, height: box)
                let radius = abs(aspect - 1) > 0.01 ? min(baseRadius, baseRadius / aspect) : baseRadius
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: baseRadius, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: box * 0.4, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
            }
        }
        .frame(width: box, height: box)
    }
}
