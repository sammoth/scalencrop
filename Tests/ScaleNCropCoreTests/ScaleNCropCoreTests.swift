import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import ScaleNCropCore
import Testing
import UniformTypeIdentifiers

/// A 6×4 image where every pixel has a unique red/green value.
private func gradientImage(width: Int = 6, height: Int = 4, bits: Int = 8, alpha: Bool = false) -> CGImage {
    let layout = PixelLayout(channels: 4, depth: bits == 8 ? .uint8 : .uint16, hasAlpha: alpha)
    let context = layout.makeContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    let pixels = context.data!
    for y in 0..<height {
        for x in 0..<width {
            let r = (20 * x + 10) % 256, g = (30 * y + 5) % 256
            if bits == 8 {
                let p = pixels.advanced(by: y * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
                p[0] = UInt8(r); p[1] = UInt8(g); p[2] = 100; p[3] = 255
            } else {
                let p = pixels.advanced(by: y * context.bytesPerRow + x * 8).assumingMemoryBound(to: UInt16.self)
                p[0] = UInt16(r * 257); p[1] = UInt16(g * 257); p[2] = 100 * 257; p[3] = 65535
            }
        }
    }
    return context.makeImage()!
}

private func rgba8(_ image: CGImage) -> [UInt8] {
    let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height * 4))
}

private func temporaryURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
}

@Test func scaledSizeKeepsAspectAndClamps() {
    let size = PixelSize(width: 4000, height: 3000)
    #expect(size.scaled(toLongSide: 1000) == PixelSize(width: 1000, height: 750))
    #expect(size.scaled(toLongSide: 1) == PixelSize(width: 1, height: 1))
    #expect(size.scaled(toLongSide: 99999) == size)
    #expect(PixelSize(width: 300, height: 1200).scaled(toLongSide: 600) == PixelSize(width: 150, height: 600))
}

@Test(arguments: 1...8)
func orientationMatchesCoreImage(rawOrientation: UInt32) throws {
    let orientation = CGImagePropertyOrientation(rawValue: rawOrientation)!
    let source = gradientImage()
    let normalized = try WorkingImage(normalizing: source, orientation: orientation)

    let context = CIContext(options: [.workingColorSpace: NSNull()])
    let reference = CIImage(cgImage: source).oriented(orientation)
    let expected = context.createCGImage(reference, from: reference.extent)!

    #expect(normalized.size == PixelSize(width: expected.width, height: expected.height))
    #expect(rgba8(normalized.cgImage) == rgba8(expected))
}

@Test func cropWithoutScalingIsExact() throws {
    let image = try WorkingImage(normalizing: gradientImage())
    let crop = PixelRect(x: 2, y: 1, width: 3, height: 2)
    let output = try ImageExporter.render(image, edits: EditSettings(crop: crop))
    #expect(output.width == 3 && output.height == 2)
    let pixels = rgba8(output)
    #expect(pixels[0] == 50 && pixels[1] == 35) // pixel (2, 1)
}

@Test(arguments: [8, 16])
func cropAndScaleProducesRequestedSize(bits: Int) throws {
    let image = try WorkingImage(normalizing: gradientImage(width: 400, height: 300, bits: bits))
    #expect(image.layout.depth == (bits == 8 ? .uint8 : .uint16))
    let edits = EditSettings(crop: PixelRect(x: 10, y: 20, width: 200, height: 100), targetLongSide: 50)
    let output = try ImageExporter.render(image, edits: edits)
    #expect(output.width == 50 && output.height == 25)
    #expect(output.bitsPerComponent == bits)
    // Mid-gray-ish blue channel survives resampling, so the bytes weren't misread.
    let pixels = rgba8(output)
    #expect(abs(Int(pixels[2]) - 100) <= 1)
}

@Test func jpegIsWrittenUprightAtFullQuality() throws {
    // Source JPEG at low quality with a rotate-90 orientation tag.
    let sourceURL = temporaryURL("jpg")
    let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, gradientImage(width: 64, height: 32), [
        kCGImageDestinationLossyCompressionQuality: 0.1,
        kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let info = try ImageInfo(url: sourceURL)
    #expect(info.size == PixelSize(width: 32, height: 64))

    let image = try WorkingImage(contentsOf: sourceURL)
    let output = try ImageExporter.render(image, edits: EditSettings(crop: PixelRect(size: info.size), targetLongSide: 32))
    let outputURL = temporaryURL("jpg")
    try ImageExporter.write(output, to: outputURL, type: .jpeg, metadataSource: sourceURL)

    let written = CGImageSourceCreateWithURL(outputURL as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as! [CFString: Any]
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 16)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 32)
    #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)

    // A max-quality JPEG of the same pixels is much larger than a q=0.1 one.
    let lowURL = temporaryURL("jpg")
    let low = CGImageDestinationCreateWithURL(lowURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(low, output, [kCGImageDestinationLossyCompressionQuality: 0.1] as CFDictionary)
    #expect(CGImageDestinationFinalize(low))
    let size = { (url: URL) in try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    #expect(try size(outputURL) > size(lowURL))
}

@Test func previewNeverExceedsDisplayResolution() throws {
    let image = try WorkingImage(normalizing: gradientImage(width: 400, height: 300))
    let full = EditSettings(crop: PixelRect(size: image.size))
    let large = PreviewRenderer.shared.render(image, edits: full, region: CGRect(origin: .zero, size: CGSize(width: image.size.width, height: image.size.height)), clampToCrop: false, displayScale: 0.5)!
    #expect(large.image.width == 200 && large.image.height == 150)

    let small = PreviewRenderer.shared.render(
        image,
        edits: EditSettings(crop: PixelRect(size: image.size), targetLongSide: 40),
        region: CGRect(x: 0, y: 0, width: 400, height: 300),
        clampToCrop: false,
        displayScale: 0.5
    )!
    #expect(small.image.width == 40 && small.image.height == 30)
    #expect(small.coveredRect == CGRect(x: 0, y: 0, width: 400, height: 300))
}

@Test func fullPreviewMatchesCropPreviewInsideCrop() throws {
    // Noisy content so any grid misalignment would show up.
    let width = 300, height = 200
    let layout = PixelLayout(channels: 4, depth: .uint8, hasAlpha: false)
    let context = layout.makeContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    var generator = SystemRandomNumberGenerator()
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(context.bytesPerRow * height) { pixels[i] = UInt8.random(in: 0...255, using: &generator) }
    let image = try WorkingImage(normalizing: context.makeImage()!)

    let edits = EditSettings(crop: PixelRect(x: 37, y: 51, width: 170, height: 110), targetLongSide: 61)
    let output = edits.outputSize
    let cropOnly = PreviewRenderer.shared.render(image, edits: edits, region: edits.crop.cgRect, clampToCrop: true, displayScale: 10)!
    let full = PreviewRenderer.shared.render(image, edits: edits, region: CGRect(origin: .zero, size: CGSize(width: image.size.width, height: image.size.height)), clampToCrop: false, displayScale: 10)!
    #expect(cropOnly.image.width == output.width && cropOnly.image.height == output.height)
    #expect(cropOnly.coveredRect == edits.crop.cgRect)

    // Locate the crop's first output pixel inside the full preview.
    let scaleX = Double(output.width) / Double(edits.crop.width)
    let scaleY = Double(output.height) / Double(edits.crop.height)
    let offsetX = Int(((Double(edits.crop.x) - full.coveredRect.minX) * scaleX).rounded())
    let offsetY = Int(((Double(edits.crop.y) - full.coveredRect.minY) * scaleY).rounded())

    let a = rgba8(cropOnly.image), b = rgba8(full.image)
    var maxDifference = 0
    // Skip a 3-pixel border, where the crop preview repeats edge pixels.
    for y in 3..<(output.height - 3) {
        for x in 3..<(output.width - 3) {
            for c in 0..<3 {
                let pa = Int(a[(y * output.width + x) * 4 + c])
                let pb = Int(b[((y + offsetY) * full.image.width + x + offsetX) * 4 + c])
                maxDifference = max(maxDifference, abs(pa - pb))
            }
        }
    }
    #expect(maxDifference <= 1)
}

@Test func partialRegionMatchesWholeCropRender() throws {
    let width = 300, height = 200
    let layout = PixelLayout(channels: 4, depth: .uint8, hasAlpha: false)
    let context = layout.makeContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    var generator = SystemRandomNumberGenerator()
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(context.bytesPerRow * height) { pixels[i] = UInt8.random(in: 0...255, using: &generator) }
    let image = try WorkingImage(normalizing: context.makeImage()!)

    let edits = EditSettings(crop: PixelRect(x: 20, y: 30, width: 240, height: 150), targetLongSide: 120)
    let whole = PreviewRenderer.shared.render(image, edits: edits, region: edits.crop.cgRect, clampToCrop: true, displayScale: 10)!
    // An on-screen window into the middle of the crop, as at actual size.
    let part = PreviewRenderer.shared.render(
        image, edits: edits, region: CGRect(x: 81.3, y: 64.7, width: 100, height: 60), clampToCrop: true, displayScale: 10
    )!
    #expect(part.image.width < whole.image.width && part.image.height < whole.image.height)
    #expect(part.coveredRect.contains(CGRect(x: 81.3, y: 64.7, width: 100, height: 60)))

    // The partial render's pixels are a sub-block of the whole render.
    let scale = Double(edits.outputSize.width) / Double(edits.crop.width)
    let offsetX = Int(((part.coveredRect.minX - Double(edits.crop.x)) * scale).rounded())
    let offsetY = Int(((part.coveredRect.minY - Double(edits.crop.y)) * scale).rounded())
    let a = rgba8(part.image), b = rgba8(whole.image)
    var maxDifference = 0
    for y in 0..<part.image.height {
        for x in 0..<part.image.width {
            for c in 0..<3 {
                let pa = Int(a[(y * part.image.width + x) * 4 + c])
                let pb = Int(b[((y + offsetY) * whole.image.width + x + offsetX) * 4 + c])
                maxDifference = max(maxDifference, abs(pa - pb))
            }
        }
    }
    #expect(maxDifference <= 1)
}

@Test func saliencyFindsTheOffCentreSubject() async throws {
    // A plain grey field with one bright red disc towards the bottom right
    // (top-left coordinates: centre at 600, 430).
    let layout = PixelLayout(channels: 4, depth: .uint8, hasAlpha: false)
    let context = layout.makeContext(width: 800, height: 600, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 600 - 70, y: (600 - 430) - 70, width: 140, height: 140))
    let image = try WorkingImage(normalizing: context.makeImage()!)

    let full = try #require(await Saliency.focusPoint(in: image, crop: PixelRect(size: image.size)))
    #expect(abs(full.x - 600) < 80 && abs(full.y - 430) < 80, "focus \(full)")

    // Same subject found within a crop, reported in original-image pixels.
    let crop = PixelRect(x: 300, y: 200, width: 450, height: 380)
    let cropped = try #require(await Saliency.focusPoint(in: image, crop: crop))
    #expect(abs(cropped.x - 600) < 80 && abs(cropped.y - 430) < 80, "focus \(cropped)")
}
