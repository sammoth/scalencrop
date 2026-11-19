import AppKit
import ScaleNCropCore
import SwiftUI

/// What the canvas shows.
enum CanvasMode: Equatable {
    /// The whole image, downscaled by the current factor, with the crop drawn
    /// over it ready to adjust.
    case full
    /// Just the cropped area, fitted to the view.
    case cropFit
    /// Just the cropped area at actual size (like Preview's Actual Size),
    /// centred and cut off by the view.
    case cropActualSize
}

/// The main image view; see `CanvasMode`.
struct ImageCanvas: NSViewRepresentable {
    let item: ImageItem
    let image: WorkingImage?
    let mode: CanvasMode
    let pixelated: Bool
    let insets: NSEdgeInsets

    func makeNSView(context: Context) -> CanvasView {
        CanvasView()
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.update(
            item: item,
            image: image,
            edits: item.edits,
            mode: mode,
            pixelated: pixelated,
            insets: insets
        )
    }
}

final class CanvasView: NSView {
    private struct RenderKey: Equatable {
        let image: ObjectIdentifier
        let edits: EditSettings
        let region: CGRect
        let clampToCrop: Bool
        let displayScale: Double
    }

    /// Maps original-image pixels to view points: `origin + pixel * scale`.
    private struct Mapping {
        var origin: CGPoint
        var scale: CGSize
    }

    private enum Drag {
        case creating(anchor: CGPoint, original: PixelRect, started: Bool)
        case moving(start: CGPoint, original: PixelRect)
        case resizing(Handle, start: CGPoint, original: PixelRect)
    }

    private struct Handle: OptionSet, Hashable {
        let rawValue: Int
        static let left = Handle(rawValue: 1)
        static let right = Handle(rawValue: 2)
        static let top = Handle(rawValue: 4)
        static let bottom = Handle(rawValue: 8)

        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition = switch self {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            default: .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
    }

    private weak var item: ImageItem?
    private var image: WorkingImage?
    private var edits: EditSettings?
    private var mode = CanvasMode.full
    private var insets = NSEdgeInsets()
    private var drag: Drag?
    /// The resize zone under the pointer, highlighted on the crop.
    private var hoveredHandle: Handle?

    /// Clips the preview to the visible image area, since a downscaled
    /// full-image preview can overhang the image edges by a partial pixel.
    private let clipLayer = CALayer()
    private let imageLayer = CALayer()
    private let overlay = CropOverlay()
    /// The original-image area covered by `imageLayer`'s current contents.
    private var contentsRect = CGRect.zero

    private var requestedKey: RenderKey?
    private var isRendering = false

    /// The salient point of the current crop (original-image pixels), which
    /// the actual-size view centres on. Computed in the background whenever
    /// the crop settles.
    private var focusPoint: CGPoint?
    private var focusKey: FocusKey?
    private var focusTask: Task<Void, Never>?

    private struct FocusKey: Equatable {
        let image: ObjectIdentifier
        let crop: PixelRect
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let noAnimation: [String: any CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
        ]
        clipLayer.masksToBounds = true
        clipLayer.actions = noAnimation
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .linear
        imageLayer.actions = noAnimation
        clipLayer.addSublayer(imageLayer)
        layer?.addSublayer(clipLayer)
        overlay.install(in: layer!)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(
        item: ImageItem,
        image: WorkingImage?,
        edits: EditSettings,
        mode: CanvasMode,
        pixelated: Bool,
        insets: NSEdgeInsets
    ) {
        let itemChanged = self.item !== item
        self.item = item
        self.image = image
        self.edits = edits
        self.mode = mode
        self.insets = insets
        imageLayer.magnificationFilter = pixelated ? .nearest : .linear

        if itemChanged || (image == nil && imageLayer.contents == nil) {
            requestedKey = nil
            drag = nil
            imageLayer.contents = item.thumbnail
            contentsRect = CGRect(x: 0, y: 0, width: item.originalSize.width, height: item.originalSize.height)
        }
        layoutImage()
    }

    override func layout() {
        super.layout()
        layoutImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        overlay.contentsScale = window?.backingScaleFactor ?? 2
        layoutImage()
    }

    // MARK: Geometry

    /// The view's usable area: the bounds minus the space kept for controls.
    private var area: CGRect {
        bounds.insetBy(insets)
    }

    /// The part of the original image on screen (in pixels, possibly
    /// fractional) and how it maps to the view.
    private var geometry: (shown: CGRect, mapping: Mapping)? {
        guard let edits, let item, area.width > 0, area.height > 0 else { return nil }
        let area = area
        switch mode {
        case .full, .cropFit:
            let region = mode == .full ? PixelRect(size: item.originalSize).cgRect : edits.crop.cgRect
            let fit = min(area.width / region.width, area.height / region.height)
            let frame = backingAlignedRect(CGRect(
                x: area.midX - region.width * fit / 2,
                y: area.midY - region.height * fit / 2,
                width: region.width * fit,
                height: region.height * fit
            ), options: .alignAllEdgesNearest)
            let scale = CGSize(width: frame.width / region.width, height: frame.height / region.height)
            let origin = CGPoint(x: frame.minX - region.minX * scale.width, y: frame.minY - region.minY * scale.height)
            return (region, Mapping(origin: origin, scale: scale))

        case .cropActualSize:
            let crop = edits.crop.cgRect
            let scale = item.pointsPerPixel
            let backing = window?.backingScaleFactor ?? 2
            // Centre on the crop's salient point, but keep the view inside the
            // crop where it's big enough; snap to device pixels so pixels stay crisp.
            let focus = focusPoint ?? CGPoint(x: crop.midX, y: crop.midY)
            func centre(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat, halfSpan: CGFloat) -> CGFloat {
                high - low <= 2 * halfSpan ? (low + high) / 2 : min(max(value, low + halfSpan), high - halfSpan)
            }
            let centreX = centre(focus.x, crop.minX, crop.maxX, halfSpan: area.width / scale.width / 2)
            let centreY = centre(focus.y, crop.minY, crop.maxY, halfSpan: area.height / scale.height / 2)
            let origin = CGPoint(
                x: ((area.midX - centreX * scale.width) * backing).rounded() / backing,
                y: ((area.midY - centreY * scale.height) * backing).rounded() / backing
            )
            let visible = CGRect(
                x: (area.minX - origin.x) / scale.width,
                y: (area.minY - origin.y) / scale.height,
                width: area.width / scale.width,
                height: area.height / scale.height
            )
            let shown = crop.intersection(visible)
            guard !shown.isNull, shown.width > 0, shown.height > 0 else { return nil }
            return (shown, Mapping(origin: origin, scale: scale))
        }
    }

    /// Where the shown part of the image sits in the view.
    private var imageFrame: CGRect {
        geometry.map { viewRect($0.shown) } ?? .zero
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        guard let mapping = geometry?.mapping else { return .zero }
        return CGRect(
            x: mapping.origin.x + rect.minX * mapping.scale.width,
            y: mapping.origin.y + rect.minY * mapping.scale.height,
            width: rect.width * mapping.scale.width,
            height: rect.height * mapping.scale.height
        )
    }

    /// Converts a view point to original-image pixels, by default clamped to
    /// the shown area.
    private func imagePoint(_ point: CGPoint, clamped: Bool = true) -> CGPoint {
        guard let (shown, mapping) = geometry else { return .zero }
        let x = (point.x - mapping.origin.x) / mapping.scale.width
        let y = (point.y - mapping.origin.y) / mapping.scale.height
        guard clamped else { return CGPoint(x: x, y: y) }
        return CGPoint(
            x: min(max(x, shown.minX), shown.maxX),
            y: min(max(y, shown.minY), shown.maxY)
        )
    }

    private var isCropped: Bool {
        guard let edits, let item else { return false }
        return edits.crop != PixelRect(size: item.originalSize)
    }

    private func layoutImage() {
        let frame = imageFrame
        clipLayer.frame = frame
        let contents = viewRect(contentsRect)
        imageLayer.frame = contents.offsetBy(dx: -frame.minX, dy: -frame.minY)

        updateOverlay()
        window?.invalidateCursorRects(for: self)
        updateFocusPoint()
        scheduleRender()
    }

    /// Finds the crop's salient point once the crop has settled.
    private func updateFocusPoint() {
        guard drag == nil, let image, let crop = edits?.crop else { return }
        let key = FocusKey(image: ObjectIdentifier(image.cgImage), crop: crop)
        guard key != focusKey else { return }
        focusKey = key
        focusPoint = nil
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            let point = await Task.detached(priority: .utility) {
                await Saliency.focusPoint(in: image, crop: crop)
            }.value
            guard let self, !Task.isCancelled, focusKey == key else { return }
            focusPoint = point
            if mode == .cropActualSize {
                layoutImage()
            }
        }
    }

    private func updateOverlay() {
        let showsCrop = mode == .full && edits != nil
        let cropFrame = showsCrop ? edits.map { viewRect($0.crop.cgRect) } : nil
        // Highlight the zone being resized, or else the one under the pointer.
        var activeHandle: Handle?
        switch drag {
        case .resizing(let handle, _, _): activeHandle = handle
        case nil: activeHandle = hoveredHandle
        default: activeHandle = nil
        }
        // A side lights up along its whole length (its zone and both corners);
        // a corner lights up just its own zone.
        let highlight = cropFrame.flatMap { crop in
            activeHandle.flatMap { handle in
                handleZones(for: crop)
                    .filter { $0.0.contains(handle) }
                    .map(\.1)
                    .reduce(nil) { $0?.union($1) ?? $1 }?
                    .intersection(crop)
            }
        }
        overlay.update(
            imageFrame: imageFrame,
            cropFrame: cropFrame,
            cropSize: edits?.crop.size,
            dimsOutside: showsCrop && isCropped,
            isDragging: drag != nil,
            highlight: highlight
        )
    }

    // MARK: Rendering

    private func currentKey() -> RenderKey? {
        guard let image, var edits, let (shown, mapping) = geometry else { return nil }
        // Without downscaling the full-image preview doesn't depend on the
        // crop, so moving the crop shouldn't trigger a re-render.
        if mode == .full, edits.outputSize == edits.crop.size {
            edits = EditSettings(crop: PixelRect(size: image.size))
        }
        return RenderKey(
            image: ObjectIdentifier(image.cgImage),
            edits: edits,
            region: shown,
            clampToCrop: mode != .full,
            displayScale: mapping.scale.width * (window?.backingScaleFactor ?? 2)
        )
    }

    /// Renders on a background thread. While a render is in flight, newer
    /// requests just mark the view stale, so slider drags never queue up.
    ///
    /// While the crop is being dragged the current preview is kept: a new crop
    /// only nudges the downscale grid, and re-rendering every frame would cost
    /// a full-size texture upload. It re-renders once the mouse is released.
    private func scheduleRender() {
        guard drag == nil || mode != .full,
              let key = currentKey(), key != requestedKey, !isRendering, let image else { return }
        requestedKey = key
        isRendering = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let frame = PreviewRenderer.shared.render(
                image,
                edits: key.edits,
                region: key.region,
                clampToCrop: key.clampToCrop,
                displayScale: key.displayScale
            )
            await self?.finishRender(frame, key: key)
        }
    }

    private func finishRender(_ frame: PreviewFrame?, key: RenderKey) {
        isRendering = false
        if let frame, let image, ObjectIdentifier(image.cgImage) == key.image {
            imageLayer.contents = frame.image
            contentsRect = frame.coveredRect
            layoutImage()
        } else {
            scheduleRender()
        }
    }

    // MARK: Crop interaction

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredHandle(mode == .full ? handle(at: convert(event.locationInWindow, from: nil)) : nil)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredHandle(nil)
    }

    private func setHoveredHandle(_ handle: Handle?) {
        guard handle != hoveredHandle else { return }
        hoveredHandle = handle
        updateOverlay()
    }
    override var acceptsFirstResponder: Bool { true }

    /// The crop's resize zones in view coordinates: a 3×3 grid whose corner
    /// cells are squares a quarter of the crop's shorter side and whose edge
    /// cells run between them. The middle cell (not included) moves the crop.
    /// Zones reach a little outside the crop so thin edges stay easy to grab.
    /// Until something is cropped the "crop" is the whole image, so only a thin
    /// band at its edges resizes and dragging anywhere else draws a new crop.
    private func handleZones(for rect: CGRect) -> [(Handle, CGRect)] {
        let inner = isCropped ? min(rect.width, rect.height) / 4 : 9
        let outside: CGFloat = 9
        let columns: [(Handle, CGFloat, CGFloat)] = [
            (.left, rect.minX - outside, rect.minX + inner),
            ([], rect.minX + inner, rect.maxX - inner),
            (.right, rect.maxX - inner, rect.maxX + outside),
        ]
        let rows: [(Handle, CGFloat, CGFloat)] = [
            (.top, rect.minY - outside, rect.minY + inner),
            ([], rect.minY + inner, rect.maxY - inner),
            (.bottom, rect.maxY - inner, rect.maxY + outside),
        ]
        return columns.flatMap { column, minX, maxX in
            rows.compactMap { row, minY, maxY in
                let handle = column.union(row)
                guard !handle.isEmpty else { return nil }
                return (handle, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
        }
    }

    private func handle(at point: CGPoint) -> Handle? {
        guard let crop = edits?.crop else { return nil }
        return handleZones(for: viewRect(crop.cgRect)).first { $0.1.contains(point) }?.0
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .full, let crop = edits?.crop else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if let handle = handle(at: point) {
            drag = .resizing(handle, start: imagePoint(point, clamped: false), original: crop)
        } else if isCropped, viewRect(crop.cgRect).contains(point) {
            drag = .moving(start: imagePoint(point), original: crop)
            NSCursor.closedHand.push()
        } else if imageFrame.insetBy(dx: -12, dy: -12).contains(point) {
            drag = .creating(anchor: imagePoint(point), original: crop, started: false)
        }
        layoutImage()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item, let drag, let full = geometry?.shown else { return }
        let location = convert(event.locationInWindow, from: nil)
        let current = imagePoint(location)

        switch drag {
        case .creating(let anchor, let original, let started):
            let anchorInView = viewRect(CGRect(origin: anchor, size: .zero)).origin
            guard started || hypot(location.x - anchorInView.x, location.y - anchorInView.y) > 3 else { return }
            self.drag = .creating(anchor: anchor, original: original, started: true)
            let rect = CGRect(
                x: min(anchor.x, current.x),
                y: min(anchor.y, current.y),
                width: abs(current.x - anchor.x),
                height: abs(current.y - anchor.y)
            )
            if let crop = Self.pixelRect(rect, within: full) {
                item.setCrop(crop)
            }

        case .moving(let start, let original):
            var rect = original.cgRect.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
            rect.origin.x = min(max(rect.minX, full.minX), full.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, full.minY), full.maxY - rect.height)
            if let crop = Self.pixelRect(rect, within: full) {
                item.setCrop(crop)
            }

        case .resizing(let handle, let start, let original):
            // Scale the grabbed side(s) about the opposite, fixed side so the
            // point under the cursor keeps its relative place in the crop:
            // grab 1 cm from the fixed edge, drag to 2 cm, and the crop doubles.
            let pointer = imagePoint(location, clamped: false)
            func scaled(fixed: CGFloat, moving: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
                let grabbed = from - fixed
                // Grabbed (almost) on the fixed edge: fall back to following the pointer.
                guard abs(grabbed) > 0.5 else { return moving + (to - from) }
                return fixed + (moving - fixed) * (to - fixed) / grabbed
            }
            var minX = CGFloat(original.x), maxX = CGFloat(original.x + original.width)
            var minY = CGFloat(original.y), maxY = CGFloat(original.y + original.height)
            if handle.contains(.left) {
                minX = min(max(scaled(fixed: maxX, moving: minX, from: start.x, to: pointer.x), full.minX), maxX - 1)
            }
            if handle.contains(.right) {
                maxX = max(min(scaled(fixed: minX, moving: maxX, from: start.x, to: pointer.x), full.maxX), minX + 1)
            }
            if handle.contains(.top) {
                minY = min(max(scaled(fixed: maxY, moving: minY, from: start.y, to: pointer.y), full.minY), maxY - 1)
            }
            if handle.contains(.bottom) {
                maxY = max(min(scaled(fixed: minY, moving: maxY, from: start.y, to: pointer.y), full.maxY), minY + 1)
            }
            if let crop = Self.pixelRect(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), within: full) {
                item.setCrop(crop)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, let drag else { return }
        switch drag {
        case .moving:
            NSCursor.pop()
        case .creating(_, let original, let started):
            // A tiny accidental drag shouldn't replace a real crop.
            let rect = viewRect(item.edits.crop.cgRect)
            if started, rect.width < 4 || rect.height < 4 {
                item.setCrop(original)
            }
        case .resizing:
            break
        }
        self.drag = nil
        hoveredHandle = handle(at: convert(event.locationInWindow, from: nil))
        layoutImage()
    }

    private static func pixelRect(_ rect: CGRect, within bounds: CGRect) -> PixelRect? {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull else { return nil }
        let minX = Int(clipped.minX.rounded()), maxX = Int(clipped.maxX.rounded())
        let minY = Int(clipped.minY.rounded()), maxY = Int(clipped.maxY.rounded())
        guard maxX > minX, maxY > minY else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func resetCursorRects() {
        guard let crop = edits?.crop, mode == .full else { return }
        addCursorRect(imageFrame, cursor: .crosshair)
        let rect = viewRect(crop.cgRect)
        if isCropped {
            addCursorRect(rect, cursor: .openHand)
        }
        for (handle, zone) in handleZones(for: rect) {
            addCursorRect(zone, cursor: handle.cursor)
        }
    }
}

/// The dimmed surround, frame, handles and size label of the
/// crop, drawn with shape layers so that moving the crop only changes paths
/// and never re-uploads a view-sized bitmap.
@MainActor
private final class CropOverlay {
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let label = CATextLayer()
    private let highlight = CAShapeLayer()

    var contentsScale: CGFloat = 2 {
        didSet {
            for layer in [dim, highlight, border, handles, label] as [CALayer] {
                layer.contentsScale = contentsScale
            }
        }
    }

    init() {
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.6).cgColor
        border.fillColor = nil
        border.lineWidth = 1
        handles.fillColor = nil
        handles.lineWidth = 3
        handles.lineCap = .square
        handles.strokeColor = NSColor.white.cgColor
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        label.cornerRadius = 5
        label.alignmentMode = .center
        highlight.fillColor = NSColor(red: 0.93, green: 0.2, blue: 0.53, alpha: 0.3).cgColor
    }

    func install(in parent: CALayer) {
        for layer in [dim, highlight, border, handles, label] as [CALayer] {
            parent.addSublayer(layer)
        }
    }

    /// - Parameter highlight: The resize zone to tint, in view coordinates.
    func update(
        imageFrame: CGRect,
        cropFrame: CGRect?,
        cropSize: PixelSize?,
        dimsOutside: Bool,
        isDragging: Bool,
        highlight highlightFrame: CGRect?
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let crop = cropFrame else {
            for layer in [dim, highlight, border, handles, label] as [CALayer] {
                layer.isHidden = true
            }
            return
        }

        dim.isHidden = !dimsOutside
        if dimsOutside {
            let path = CGMutablePath()
            path.addRect(imageFrame)
            path.addRect(crop)
            dim.path = path
        }

        highlight.isHidden = highlightFrame == nil
        if let highlightFrame {
            highlight.path = CGPath(rect: highlightFrame, transform: nil)
        }

        border.isHidden = false
        border.path = CGPath(rect: crop.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        border.strokeColor = NSColor.white.withAlphaComponent(dimsOutside || isDragging ? 0.9 : 0.35).cgColor

        handles.isHidden = false
        handles.path = Self.handlesPath(around: crop)

        label.isHidden = !isDragging
        if isDragging, let cropSize {
            let text = "\(cropSize.width) × \(cropSize.height)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let box = CGSize(width: (textSize.width + 12).rounded(.up), height: (textSize.height + 6).rounded(.up))
            var origin = CGPoint(x: (crop.midX - box.width / 2).rounded(), y: crop.minY - box.height - 8)
            if origin.y < 4 {
                origin.y = crop.minY + 8
            }
            label.string = text
            // CATextLayer draws from the top; pad it down to centre vertically.
            label.frame = CGRect(origin: origin, size: box)
            label.contentsRect = CGRect(x: 0, y: -3 / box.height, width: 1, height: 1)
        }
    }

    private static func handlesPath(around crop: CGRect) -> CGPath {
        let length = min(18, crop.width / 3, crop.height / 3)
        let path = CGMutablePath()
        let outer = crop.insetBy(dx: -1.5, dy: -1.5)
        for (x, dx) in [(outer.minX, 1.0), (outer.maxX, -1.0)] {
            for (y, dy) in [(outer.minY, 1.0), (outer.maxY, -1.0)] {
                path.move(to: CGPoint(x: x + dx * length, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dy * length))
            }
        }
        let edge = min(14, crop.width / 4, crop.height / 4)
        path.move(to: CGPoint(x: crop.midX - edge, y: outer.minY))
        path.addLine(to: CGPoint(x: crop.midX + edge, y: outer.minY))
        path.move(to: CGPoint(x: crop.midX - edge, y: outer.maxY))
        path.addLine(to: CGPoint(x: crop.midX + edge, y: outer.maxY))
        path.move(to: CGPoint(x: outer.minX, y: crop.midY - edge))
        path.addLine(to: CGPoint(x: outer.minX, y: crop.midY + edge))
        path.move(to: CGPoint(x: outer.maxX, y: crop.midY - edge))
        path.addLine(to: CGPoint(x: outer.maxX, y: crop.midY + edge))
        return path
    }
}

private extension CGRect {
    func insetBy(_ insets: NSEdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}
