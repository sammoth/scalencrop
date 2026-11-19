import CoreGraphics

/// Integer pixel dimensions.
public struct PixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longSide: Int { max(width, height) }

    /// Downscales so the longer side becomes `longSide`, keeping the aspect ratio.
    /// The shorter side is rounded and never drops below one pixel.
    public func scaled(toLongSide longSide: Int) -> PixelSize {
        let target = min(max(longSide, 1), self.longSide)
        guard target != self.longSide else { return self }
        let factor = Double(target) / Double(self.longSide)
        if width >= height {
            return PixelSize(width: target, height: max(1, Int((Double(height) * factor).rounded())))
        }
        return PixelSize(width: max(1, Int((Double(width) * factor).rounded())), height: target)
    }
}

/// A crop rectangle in integer pixel coordinates, origin at the top-left of the
/// upright (orientation-corrected) image.
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(size: PixelSize) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The edits applied to one image: crop first, then downscale.
public struct EditSettings: Hashable, Sendable {
    public var crop: PixelRect
    /// Downscale factor applied to the cropped image, in (0, 1]. Stored as a
    /// fraction so that changing the crop keeps the same percentage.
    public var scale: Double

    public init(crop: PixelRect, scale: Double = 1) {
        self.crop = crop
        self.scale = scale
    }

    /// Scales so the cropped image's long side becomes `targetLongSide` pixels.
    public init(crop: PixelRect, targetLongSide: Int?) {
        self.init(crop: crop)
        if let targetLongSide {
            self.targetLongSide = targetLongSide
        }
    }

    /// Long side of the output in pixels, between 1 and the cropped long side.
    public var targetLongSide: Int {
        get {
            let long = crop.size.longSide
            return min(max(Int((scale * Double(long)).rounded()), 1), long)
        }
        set {
            let long = crop.size.longSide
            scale = Double(min(max(newValue, 1), long)) / Double(long)
        }
    }

    public var outputSize: PixelSize {
        crop.size.scaled(toLongSide: targetLongSide)
    }
}
