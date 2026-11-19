import CoreGraphics
import CoreImage

/// A rendered preview and the area of the original image it covers.
public struct PreviewFrame: @unchecked Sendable {
    public let image: CGImage
    /// In original-image pixels, top-left origin. Rounded out to whole output
    /// pixels, so it can overhang the requested region by up to one output
    /// pixel; clip to the region when displaying.
    public let coveredRect: CGRect
}

/// GPU preview of the export pipeline: crop, downscale with Lanczos, then
/// (only if that is still larger than the screen area) downscale again to the
/// on-screen size. Upscaling for display is left to the layer, so the preview
/// never has more pixels than the screen shows.
///
/// Any region of the image can be rendered (the whole image, the crop, or the
/// part of the crop that's on screen). It is always resampled with the crop's
/// factors on a pixel grid anchored at the crop's origin, so the pixels inside
/// the crop are the same whichever region is shown. With `clampToCrop` the
/// crop's edge pixels repeat outwards, exactly like the export; without it the
/// outermost crop pixels see their real neighbours and differ slightly.
///
/// Color management is disabled so resampling happens on the encoded values,
/// exactly like the vImage export.
public final class PreviewRenderer: @unchecked Sendable {
    public static let shared = PreviewRenderer()

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false,
    ])

    /// - Parameters:
    ///   - region: The area to render, in original-image pixels, top-left origin.
    ///   - clampToCrop: Sample only inside the crop, repeating its edges.
    ///   - displayScale: Screen pixels per original-image pixel.
    public func render(
        _ image: WorkingImage,
        edits: EditSettings,
        region: CGRect,
        clampToCrop: Bool,
        displayScale: Double
    ) -> PreviewFrame? {
        let full = image.size
        let crop = edits.crop
        // Core Image's origin is bottom-left; anchor everything at the crop's
        // bottom-left corner so the output grid starts exactly on the crop.
        let anchor = CGPoint(x: crop.x, y: full.height - crop.y - crop.height)
        let source = CIImage(cgImage: image.cgImage)
        let sampled = !clampToCrop
            ? source.clampedToExtent()
            : source.cropped(to: CGRect(origin: anchor, size: CGSize(width: crop.width, height: crop.height)))
                .clampedToExtent()
        var result = sampled.transformed(by: CGAffineTransform(translationX: -anchor.x, y: -anchor.y))

        let output = edits.outputSize
        let scaleX = Double(output.width) / Double(crop.width)
        let scaleY = Double(output.height) / Double(crop.height)
        if output != crop.size {
            result = Self.lanczos(result, scaleX: scaleX, scaleY: scaleY)
        }

        // The region relative to the crop's bottom-left corner, y up.
        let region = CGRect(
            x: region.minX - CGFloat(crop.x),
            y: CGFloat(crop.y + crop.height) - region.maxY,
            width: region.width,
            height: region.height
        )
        // Whole output pixels touched by the region (tolerating float error).
        let minX = (region.minX * scaleX + 1e-6).rounded(.down)
        let minY = (region.minY * scaleY + 1e-6).rounded(.down)
        let maxX = (region.maxX * scaleX - 1e-6).rounded(.up)
        let maxY = (region.maxY * scaleY - 1e-6).rounded(.up)
        var pixels = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let covered = CGRect(
            x: Double(crop.x) + pixels.minX / scaleX,
            y: Double(crop.y + crop.height) - pixels.maxY / scaleY,
            width: pixels.width / scaleX,
            height: pixels.height / scaleY
        )

        // More pixels than the screen can show: shrink to screen resolution.
        if scaleX > displayScale * 1.001 || scaleY > displayScale * 1.001 {
            let target = CGSize(
                width: max(1, (covered.width * displayScale).rounded()),
                height: max(1, (covered.height * displayScale).rounded())
            )
            result = Self.lanczos(
                result.cropped(to: pixels)
                    .transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
                    .clampedToExtent(),
                scaleX: target.width / pixels.width,
                scaleY: target.height / pixels.height
            )
            pixels = CGRect(origin: .zero, size: target)
        }

        let space = image.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rendered = image.layout.channels == 1
            ? context.createCGImage(result, from: pixels, format: .L8, colorSpace: space)
            : context.createCGImage(result, from: pixels, format: .RGBA8, colorSpace: space)
        return rendered.map { PreviewFrame(image: $0, coveredRect: covered) }
    }

    private static func lanczos(_ image: CIImage, scaleX: Double, scaleY: Double) -> CIImage {
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        return filter.outputImage!
    }
}
