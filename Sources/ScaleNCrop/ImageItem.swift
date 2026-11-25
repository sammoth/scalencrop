import AppKit
import ScaleNCropCore
import UniformTypeIdentifiers

/// One opened image and its pending, unsaved edits.
@MainActor
@Observable
final class ImageItem: Identifiable {
    let id = UUID()
    private(set) var url: URL
    private(set) var type: UTType?
    private(set) var originalSize: PixelSize
    private(set) var pointsPerPixel: CGSize
    private(set) var thumbnail: CGImage?
    var edits: EditSettings

    init(info: ImageInfo) {
        url = info.url
        type = info.type
        originalSize = info.size
        pointsPerPixel = info.pointsPerPixel
        edits = EditSettings(crop: PixelRect(size: info.size))
        loadThumbnail()
    }

    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }

    var isCropped: Bool { edits.crop != PixelRect(size: originalSize) }
    var isModified: Bool { isCropped || edits.outputSize != edits.crop.size }

    /// The slider's upper bound: the longest side after cropping.
    var maxLongSide: Int { edits.crop.size.longSide }

    var targetLongSide: Int {
        get { edits.targetLongSide }
        set { edits.targetLongSide = newValue }
    }

    /// Changes the crop; the downscale percentage is kept.
    func setCrop(_ crop: PixelRect) {
        edits.crop = crop
    }

    func resetCrop() {
        setCrop(PixelRect(size: originalSize))
    }

    func revert() {
        edits = EditSettings(crop: PixelRect(size: originalSize))
    }

    /// Points the item at a freshly written file whose pixels now include the edits.
    func reload(from info: ImageInfo) {
        url = info.url
        type = info.type
        originalSize = info.size
        pointsPerPixel = info.pointsPerPixel
        edits = EditSettings(crop: PixelRect(size: info.size))
        loadThumbnail()
    }

    private func loadThumbnail() {
        let url = url
        Task {
            let image = await Task.detached(priority: .utility) {
                ImageInfo.thumbnail(for: url, maxPixelSize: 360)
            }.value
            if self.url == url {
                thumbnail = image
            }
        }
    }
}
