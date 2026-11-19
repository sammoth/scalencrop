import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageError: LocalizedError {
    case unreadable(URL)
    case decodeFailed(URL)
    case unsupportedPixelFormat
    case resampleFailed
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            "“\(url.lastPathComponent)” could not be opened as an image."
        case .decodeFailed(let url):
            "“\(url.lastPathComponent)” could not be decoded."
        case .unsupportedPixelFormat:
            "The image uses a pixel format that can't be processed."
        case .resampleFailed:
            "The image could not be resized."
        case .encodeFailed(let name):
            "“\(name)” could not be encoded."
        }
    }
}

public enum PixelDepth: Sendable {
    case uint8
    case uint16
    case float32

    var bitsPerComponent: Int {
        switch self {
        case .uint8: 8
        case .uint16: 16
        case .float32: 32
        }
    }
}

/// The in-memory pixel format of a `WorkingImage`. Only these combinations are
/// produced, so cropping and resampling never need to handle anything else.
public struct PixelLayout: Hashable, Sendable {
    /// 1 (gray, no alpha) or 4 (RGB plus an alpha or padding channel).
    public let channels: Int
    public let depth: PixelDepth
    public let hasAlpha: Bool

    var bitmapInfo: UInt32 {
        var info: UInt32
        switch depth {
        case .uint8:
            info = 0
        case .uint16:
            info = CGBitmapInfo.byteOrder16Little.rawValue
        case .float32:
            info = CGBitmapInfo.byteOrder32Little.rawValue | CGBitmapInfo.floatComponents.rawValue
        }
        let alpha: CGImageAlphaInfo = channels == 1 ? .none : (hasAlpha ? .premultipliedLast : .noneSkipLast)
        return info | alpha.rawValue
    }

    func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: depth.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }
}

/// Basic facts about an image file, read without decoding its pixels.
public struct ImageInfo: Sendable {
    public let url: URL
    public let type: UTType?
    /// Pixel size after the EXIF orientation is applied.
    public let size: PixelSize
    /// Screen points per pixel at actual size (72 ÷ DPI, like Preview), after
    /// the orientation is applied. Images without a DPI count as 72 DPI.
    public let pointsPerPixel: CGSize

    public init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageError.unreadable(url)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        self.url = url
        self.type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        self.size = orientation.swapsAxes
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
        let dpi = { (key: CFString) in
            (properties[key] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        }
        let perPixel = CGSize(width: 72 / dpi(kCGImagePropertyDPIWidth), height: 72 / dpi(kCGImagePropertyDPIHeight))
        self.pointsPerPixel = orientation.swapsAxes
            ? CGSize(width: perPixel.height, height: perPixel.width)
            : perPixel
    }

    public static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}

/// A fully decoded, upright image in a normalized pixel layout.
public struct WorkingImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let layout: PixelLayout

    public var size: PixelSize { PixelSize(width: cgImage.width, height: cgImage.height) }

    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageError.unreadable(url)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw ImageError.decodeFailed(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        try self.init(normalizing: image, orientation: orientation)
    }

    /// Redraws `image` upright into one of the supported layouts. Drawing uses
    /// no interpolation and a copy blend, so pixel values are carried over as-is.
    public init(normalizing image: CGImage, orientation: CGImagePropertyOrientation = .up) throws {
        let model = image.colorSpace?.model
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let depth: PixelDepth = if image.bitmapInfo.contains(.floatComponents) || image.bitsPerComponent > 16 {
            .float32
        } else if image.bitsPerComponent > 8 {
            .uint16
        } else {
            .uint8
        }
        let isGray = model == .monochrome && !hasAlpha
        let preferred = PixelLayout(channels: isGray ? 1 : 4, depth: depth, hasAlpha: hasAlpha)
        let preferredSpace: CGColorSpace = if (isGray || model == .rgb), let space = image.colorSpace {
            space
        } else {
            CGColorSpace(name: CGColorSpace.sRGB)!
        }

        let size = orientation.swapsAxes
            ? PixelSize(width: image.height, height: image.width)
            : PixelSize(width: image.width, height: image.height)

        // Some color spaces can't back a bitmap context; fall back to 8-bit sRGB.
        let fallback = PixelLayout(channels: 4, depth: .uint8, hasAlpha: hasAlpha)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let (layout, context) = [(preferred, preferredSpace), (fallback, sRGB)].lazy
            .compactMap({ layout, space in
                layout.makeContext(width: size.width, height: size.height, colorSpace: space).map { (layout, $0) }
            })
            .first else {
            throw ImageError.unsupportedPixelFormat
        }

        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.concatenate(orientation.drawingTransform(for: size))
        let drawSize = orientation.swapsAxes
            ? CGSize(width: size.height, height: size.width)
            : CGSize(width: size.width, height: size.height)
        context.draw(image, in: CGRect(origin: .zero, size: drawSize))

        guard let normalized = context.makeImage() else {
            throw ImageError.unsupportedPixelFormat
        }
        self.cgImage = normalized
        self.layout = layout
    }
}

extension CGImagePropertyOrientation {
    var swapsAxes: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }

    /// The transform for a bottom-left-origin context of the upright `size` that
    /// draws the stored (unrotated) image so it appears upright.
    func drawingTransform(for size: PixelSize) -> CGAffineTransform {
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        var transform = CGAffineTransform.identity
        switch self {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: width, y: height).rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: width, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: height).rotated(by: -.pi / 2)
        default:
            break
        }
        switch self {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: width, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: height, y: 0).scaledBy(x: -1, y: 1)
        default:
            break
        }
        return transform
    }
}
