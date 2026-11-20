import CoreGraphics
import CoreVideo
import Vision

/// Something in the image worth cropping to.
public struct Subject: @unchecked Sendable {
    /// Tight bounds in original-image pixels (top-left origin).
    public let bounds: CGRect
    /// The subject's silhouette stretched over `bounds`: white, with the mask
    /// in the alpha channel. Nil when Vision only found a bounding box.
    public let mask: CGImage?
    /// The mask's alpha values, row-major from the top, for hit-testing.
    private let coverage: [UInt8]
    private let coverageWidth: Int
    private let coverageHeight: Int

    init(bounds: CGRect) {
        self.bounds = bounds
        mask = nil
        coverage = []
        coverageWidth = 0
        coverageHeight = 0
    }

    init?(bounds: CGRect, coverage: [UInt8], width: Int, height: Int) {
        guard let provider = CGDataProvider(data: Data(coverage.flatMap { [$0, $0, $0, $0] }) as CFData),
              let mask = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        self.bounds = bounds
        self.mask = mask
        self.coverage = coverage
        coverageWidth = width
        coverageHeight = height
    }

    /// Whether `point` (original-image pixels) is on the subject itself: inside
    /// its silhouette, or for a box-only subject inside the box.
    public func contains(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard mask != nil else { return true }
        let column = min(Int((point.x - bounds.minX) / bounds.width * Double(coverageWidth)), coverageWidth - 1)
        let row = min(Int((point.y - bounds.minY) / bounds.height * Double(coverageHeight)), coverageHeight - 1)
        return coverage[row * coverageWidth + column] >= 128
    }

    /// The pixels the subject covers: its silhouette's share of `bounds`, or
    /// for a box-only subject the whole box.
    var area: Double {
        let box = bounds.width * bounds.height
        guard mask != nil, !coverage.isEmpty else { return box }
        return box * Double(coverage.count { $0 >= 128 }) / Double(coverage.count)
    }

    /// How much of `heatMap` (stretched over an image of `imageSize`) falls
    /// on the subject.
    func attention(in heatMap: Saliency.HeatMap, imageSize: PixelSize) -> Double {
        let cellWidth = Double(imageSize.width) / Double(heatMap.width)
        let cellHeight = Double(imageSize.height) / Double(heatMap.height)
        let rows = max(0, Int(bounds.minY / cellHeight))...min(heatMap.height - 1, Int(bounds.maxY / cellHeight))
        let columns = max(0, Int(bounds.minX / cellWidth))...min(heatMap.width - 1, Int(bounds.maxX / cellWidth))
        var total = 0.0
        for row in rows {
            for column in columns
            where contains(CGPoint(x: (Double(column) + 0.5) * cellWidth, y: (Double(row) + 0.5) * cellHeight)) {
                total += heatMap.values[row * heatMap.width + column]
            }
        }
        return total
    }

    /// A crop around the subject with a small margin on each side, clamped to
    /// an image of `size`.
    public func crop(in size: PixelSize) -> PixelRect {
        let padding = max(2, 0.02 * max(bounds.width, bounds.height))
        let rect = bounds.insetBy(dx: -padding, dy: -padding)
        let minX = max(0, Int(rect.minX.rounded(.down))), maxX = min(size.width, Int(rect.maxX.rounded(.up)))
        let minY = max(0, Int(rect.minY.rounded(.down))), maxY = min(size.height, Int(rect.maxY.rounded(.up)))
        return PixelRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
}

public enum Subjects {
    /// The image's subjects: Vision's foreground instances (people, animals,
    /// objects) with their silhouettes, or when it finds none, the bounding
    /// boxes of objectness-based saliency.
    public static func detect(in image: WorkingImage) async -> [Subject] {
        let foreground = await foregroundSubjects(in: image)
        return foreground.isEmpty ? await salientObjects(in: image) : foreground
    }

    /// The image's main subject: of those `detect` finds, the one that holds
    /// the most attention-based saliency, so both large and eye-catching
    /// subjects score well. Vision doesn't rank its foreground instances.
    public static func main(in image: WorkingImage) async -> Subject? {
        let subjects = await detect(in: image)
        guard subjects.count > 1 else { return subjects.first }
        return mostSignificant(subjects, heatMap: await Saliency.heatMap(of: image), imageSize: image.size)
    }

    /// The subject with the most of `heatMap` on it, the largest breaking
    /// ties (including when there's no heat map).
    static func mostSignificant(_ subjects: [Subject], heatMap: Saliency.HeatMap?, imageSize: PixelSize) -> Subject? {
        subjects
            .map { subject in
                (subject, heatMap.map { subject.attention(in: $0, imageSize: imageSize) } ?? 0, subject.area)
            }
            .max { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    private static func foregroundSubjects(in image: WorkingImage) async -> [Subject] {
        guard let observation = try? await GenerateForegroundInstanceMaskRequest().perform(on: image.cgImage) else {
            return []
        }
        return observation.allInstances.compactMap { instance in
            guard let buffer = try? observation.generateMask(for: IndexSet(integer: instance)) else { return nil }
            return subject(fromMask: buffer, imageSize: image.size)
        }
    }

    private static func subject(fromMask buffer: CVPixelBuffer, imageSize: PixelSize) -> Subject? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var alpha = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes)
            for column in 0..<width {
                alpha[row * width + column] = format == kCVPixelFormatType_OneComponent8
                    ? line.assumingMemoryBound(to: UInt8.self)[column]
                    : UInt8(min(max(line.assumingMemoryBound(to: Float.self)[column], 0), 1) * 255)
            }
        }
        return subject(fromMask: alpha, width: width, height: height, imageSize: imageSize)
    }

    /// Crops a soft mask (row-major from the top, stretched over the whole
    /// image) to the pixels it covers and maps them to the image.
    static func subject(fromMask alpha: [UInt8], width: Int, height: Int, imageSize: PixelSize) -> Subject? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where alpha[row * width + column] >= 128 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1
        let coverage = (minY...maxY).flatMap { row in alpha[(row * width + minX)...(row * width + maxX)] }
        let scaleX = Double(imageSize.width) / Double(width), scaleY = Double(imageSize.height) / Double(height)
        return Subject(
            bounds: CGRect(
                x: Double(minX) * scaleX, y: Double(minY) * scaleY,
                width: Double(boxWidth) * scaleX, height: Double(boxHeight) * scaleY
            ),
            coverage: coverage, width: boxWidth, height: boxHeight
        )
    }

    private static func salientObjects(in image: WorkingImage) async -> [Subject] {
        guard let observation = try? await GenerateObjectnessBasedSaliencyImageRequest().perform(on: image.cgImage) else {
            return []
        }
        let width = Double(image.size.width), height = Double(image.size.height)
        // Vision's normalized rects have a bottom-left origin.
        return observation.salientObjects.map { object in
            let box = object.boundingBox.cgRect
            return Subject(bounds: CGRect(
                x: box.minX * width, y: (1 - box.maxY) * height,
                width: box.width * width, height: box.height * height
            ))
        }
    }
}
