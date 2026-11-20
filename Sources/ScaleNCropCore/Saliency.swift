import CoreGraphics
import Vision

public enum Saliency {
    /// Attention-based saliency over a whole image: values in 0...1,
    /// row-major from the top.
    struct HeatMap {
        let values: [Double]
        let width: Int
        let height: Int
    }

    static func heatMap(of image: WorkingImage) async -> HeatMap? {
        guard let observation = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image.cgImage),
              let heatMap = try? observation.heatMap.cgImage,
              let (values, width, height) = grayValues(of: heatMap) else {
            return nil
        }
        return HeatMap(values: values, width: width, height: height)
    }

    /// The most eye-catching point of `crop`, in original-image pixels (top-left
    /// origin), from Vision's attention-based saliency. Takes the most
    /// confident salient region and returns the centre of mass of the heat
    /// map's hot core inside it: the model's map has a diffuse tail towards the
    /// image centre, so only cells near the peak value count. Returns nil if
    /// Vision finds nothing.
    public static func focusPoint(in image: WorkingImage, crop: PixelRect) async -> CGPoint? {
        guard let cropped = image.cgImage.cropping(to: crop.cgRect),
              let observation = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: cropped),
              let heatMap = try? observation.heatMap.cgImage,
              let (values, width, height) = grayValues(of: heatMap) else {
            return nil
        }

        // Vision's normalized rects have a bottom-left origin; the heat map's
        // first row is the top of the image.
        var region = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let best = observation.salientObjects.max(by: { $0.confidence < $1.confidence }) {
            let box = best.boundingBox.cgRect
            region = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }

        let cells = (0..<height).flatMap { row in
            (0..<width).map { column in
                (x: (Double(column) + 0.5) / Double(width),
                 y: (Double(row) + 0.5) / Double(height),
                 value: values[row * width + column])
            }
        }.filter { region.contains(CGPoint(x: $0.x, y: $0.y)) }
        let peak = cells.map(\.value).max() ?? 0

        var total = 0.0, sumX = 0.0, sumY = 0.0
        for (x, y, value) in cells {
            let weight = max(0, value - 0.7 * peak)
            if weight > 0 {
                total += weight
                sumX += weight * x
                sumY += weight * y
            }
        }
        let point = total > 0
            ? CGPoint(x: sumX / total, y: sumY / total)
            : CGPoint(x: region.midX, y: region.midY)
        return CGPoint(
            x: Double(crop.x) + point.x * Double(crop.width),
            y: Double(crop.y) + point.y * Double(crop.height)
        )
    }

    /// The heat map's values in 0...1, row-major from the top.
    private static func grayValues(of image: CGImage) -> ([Double], Int, Int)? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        var values = [Double]()
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let pixels = data.advanced(by: row * context.bytesPerRow).assumingMemoryBound(to: Float.self)
            for column in 0..<width {
                values.append(Double(min(max(pixels[column], 0), 1)))
            }
        }
        return (values, width, height)
    }
}
