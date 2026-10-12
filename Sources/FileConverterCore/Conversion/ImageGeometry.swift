import CoreGraphics
import Foundation

public enum ImageGeometry {
    /// Full-size conversions decode the whole image into memory.
    public static let fullSizeLimitMegapixels = 250
    /// Resizes decode at reduced size, so far larger sources are safe.
    public static let resizeLimitMegapixels = 1_000

    /// Longest side of the output for an image preset, or nil to keep the
    /// source size. Images are never enlarged.
    public static func maxPixelSize(resolution: ResolutionSetting, sourceWidth: Int, sourceHeight: Int) -> Int? {
        guard let box = VideoGeometry.box(for: resolution) else { return nil }
        let longest = max(sourceWidth, sourceHeight)
        guard longest > box.long else { return nil }
        return box.long
    }

    /// The image drawn over white, for formats without transparency.
    public static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
