import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExporter {
    /// Formats that ImageIO can write, in the order offered in save panels.
    public static let writableTypes: [UTType] = {
        let available = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let preferred: [UTType] = [.jpeg, .png, .heic, .tiff, .webP, .bmp, .gif]
        return preferred.filter { available.contains($0.identifier) }
    }()

    public static func canWrite(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return writableTypes.contains(type)
    }

    /// Crops, then downscales with a Lanczos (vImage high-quality) resampler.
    public static func render(_ image: WorkingImage, edits: EditSettings) throws -> CGImage {
        let cropped: CGImage
        if edits.crop == PixelRect(size: image.size) {
            cropped = image.cgImage
        } else {
            guard let result = image.cgImage.cropping(to: edits.crop.cgRect) else {
                throw ImageError.resampleFailed
            }
            cropped = result
        }

        let output = edits.outputSize
        guard output != edits.crop.size else { return cropped }

        let source = image.cgImage
        guard let data = source.dataProvider?.data,
              let base = CFDataGetBytePtr(data),
              let colorSpace = source.colorSpace,
              let context = image.layout.makeContext(width: output.width, height: output.height, colorSpace: colorSpace),
              let destinationData = context.data else {
            throw ImageError.resampleFailed
        }

        let bytesPerPixel = source.bitsPerPixel / 8
        let offset = edits.crop.y * source.bytesPerRow + edits.crop.x * bytesPerPixel
        let error: vImage_Error = withExtendedLifetime(data) {
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: base + offset),
                height: vImagePixelCount(edits.crop.height),
                width: vImagePixelCount(edits.crop.width),
                rowBytes: source.bytesPerRow
            )
            var dst = vImage_Buffer(
                data: destinationData,
                height: vImagePixelCount(output.height),
                width: vImagePixelCount(output.width),
                rowBytes: context.bytesPerRow
            )
            let flags = vImage_Flags(kvImageHighQualityResampling)
            switch (image.layout.channels, image.layout.depth) {
            case (1, .uint8): return vImageScale_Planar8(&src, &dst, nil, flags)
            case (1, .uint16): return vImageScale_Planar16U(&src, &dst, nil, flags)
            case (1, .float32): return vImageScale_PlanarF(&src, &dst, nil, flags)
            case (_, .uint8): return vImageScale_ARGB8888(&src, &dst, nil, flags)
            case (_, .uint16): return vImageScale_ARGB16U(&src, &dst, nil, flags)
            case (_, .float32): return vImageScale_ARGBFFFF(&src, &dst, nil, flags)
            }
        }
        guard error == kvImageNoError, let scaled = context.makeImage() else {
            throw ImageError.resampleFailed
        }
        return scaled
    }

    /// Encodes `image` as `type` and atomically writes it to `url`. Lossy formats
    /// are always written at maximum quality. Descriptive metadata (EXIF, GPS,
    /// IPTC, TIFF, DPI) is carried over from `metadataSource`, minus anything
    /// that describes the old pixels or orientation.
    public static func write(_ image: CGImage, to url: URL, type: UTType, metadataSource: URL?) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageError.encodeFailed(url.lastPathComponent)
        }
        var properties = metadataSource.map(metadata(from:)) ?? [:]
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.encodeFailed(url.lastPathComponent)
        }
        try (data as Data).write(to: url, options: .atomic)
    }

    static func metadata(from url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var result = [CFString: Any]()
        for key in [
            kCGImagePropertyDPIWidth,
            kCGImagePropertyDPIHeight,
            kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary,
        ] {
            result[key] = properties[key]
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            tiff[kCGImagePropertyTIFFCompression] = nil
            tiff[kCGImagePropertyTIFFPhotometricInterpretation] = nil
            tiff[kCGImagePropertyTIFFTileWidth] = nil
            tiff[kCGImagePropertyTIFFTileLength] = nil
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        return result
    }
}
