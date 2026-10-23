import AppKit
import CoreImage
import SwiftUI

/// Average colour of an artwork, lifted so it stays visible on the black island.
@MainActor
enum ArtworkTint {
    private static let cache = NSCache<NSImage, NSColor>()
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func color(for image: NSImage?) -> Color {
        guard let image else { return .white }
        if let cached = cache.object(forKey: image) { return Color(nsColor: cached) }
        let color = averageColor(of: image).map(lifted) ?? .white
        cache.setObject(color, forKey: image)
        return Color(nsColor: color)
    }

    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    /// Keeps the hue, but guarantees enough brightness against black.
    private static func lifted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(saturation * 1.2, 0.75),
            brightness: max(brightness, 0.85),
            alpha: 1
        )
    }
}
