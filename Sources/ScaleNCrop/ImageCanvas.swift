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

    /// Hover-to-crop: the selection is tinted pink and a middle click crops to
    /// it. Hovering segments whatever is under the pointer;
    /// ⌥-click grows the selection and ⌥⇧-click trims it, which also pins it
    /// against hovering until Escape or a crop. Until Vision's segmentation
    /// model is ready, hovering picks from `subjects` instead.
    private var subjects: [Subject] = []
    private var subjectsKey: ObjectIdentifier?
    private var subjectsTask: Task<Void, Never>?
    private var segmenter: SubjectSegmenter?
    private var segmenterReady = false
    private var selection: Subject?
    /// Where the selection was seeded and the points refining it, in
    /// original-image pixels. Any refinement pins the selection.
    private var selectionSeed: CGPoint?
    private var refinements: [SubjectSegmenter.Refinement] = []
    private var selectionTask: Task<Void, Never>?
    /// Hover segmentations run one at a time; moves while one is running
    /// coalesce into `pendingHover`, segmented as soon as it finishes.
    private var isHoverRunning = false
    private var pendingHover: CGPoint?

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

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        viewRect(CGRect(origin: point, size: .zero)).origin
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
        updateSubjects()
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

    /// Sets up hover-to-crop for a new image: finds its subjects for the
    /// fallback, then loads the segmentation model.
    private func updateSubjects() {
        guard mode == .full, let image else { return }
        let key = ObjectIdentifier(image.cgImage)
        guard key != subjectsKey else { return }
        subjectsKey = key
        subjects = []
        segmenterReady = false
        clearSelection()
        let segmenter = SubjectSegmenter(image: image)
        self.segmenter = segmenter
        subjectsTask?.cancel()
        subjectsTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                await Subjects.detect(in: image)
            }.value
            guard let self, !Task.isCancelled, subjectsKey == key else { return }
            subjects = found
            hover(at: pointerLocation)
            let ready = (try? await segmenter.prepare()) != nil
            guard !Task.isCancelled, subjectsKey == key else { return }
            segmenterReady = ready
            hover(at: pointerLocation)
        }
    }

    private func updateOverlay() {
        let showsCrop = mode == .full && edits != nil
        let cropFrame = showsCrop ? edits.map { viewRect($0.crop.cgRect) } : nil
        let subject = showsCrop && drag == nil ? selection : nil
        overlay.update(
            imageFrame: imageFrame,
            cropFrame: cropFrame,
            cropSize: edits?.crop.size,
            dimsOutside: showsCrop && isCropped,
            isDragging: drag != nil,
            subject: subject.map { (viewRect($0.bounds), $0.mask) },
            marks: showsCrop && drag == nil ? refinements.map { (viewPoint($0.point), $0.include) } : []
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
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hover(at: nil)
    }

    private var pointerLocation: CGPoint? {
        window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    private var isSelectionPinned: Bool { !refinements.isEmpty }

    private func setSelection(_ subject: Subject?) {
        selection = subject
        updateOverlay()
    }

    private func clearSelection() {
        cancelSelectionTask()
        selectionSeed = nil
        refinements = []
        setSelection(nil)
    }

    private func cancelSelectionTask() {
        selectionTask?.cancel()
        pendingHover = nil
    }

    /// Selects what's under the view point `point`, unless the selection is pinned.
    private func hover(at point: CGPoint?) {
        guard !isSelectionPinned else { return }
        guard let point, mode == .full, drag == nil, bounds.contains(point) else {
            cancelSelectionTask()
            selectionSeed = nil
            setSelection(nil)
            return
        }
        guard segmenterReady, segmenter != nil else {
            setSelection(subjectIndex(at: point).map { subjects[$0] })
            return
        }
        guard imageFrame.contains(point) else {
            cancelSelectionTask()
            selectionSeed = nil
            setSelection(nil)
            return
        }
        pendingHover = imagePoint(point)
        runPendingHover()
    }

    private func runPendingHover() {
        guard !isHoverRunning, let seed = pendingHover, let segmenter else { return }
        pendingHover = nil
        isHoverRunning = true
        selectionTask = Task { [weak self] in
            let subject = await segmenter.segment(at: seed)
            guard let self else { return }
            isHoverRunning = false
            if !Task.isCancelled, !isSelectionPinned {
                selectionSeed = seed
                setSelection(subject)
            }
            runPendingHover()
        }
    }

    /// Grows the selection to take in what's at the view point `point`, or
    /// trims it to leave that out, pinning it. Includes start a selection if
    /// there's none.
    private func refineSelection(at point: CGPoint, include: Bool) {
        guard segmenterReady, let segmenter, imageFrame.contains(point) else {
            NSSound.beep()
            return
        }
        cancelSelectionTask()
        let pixel = imagePoint(point)
        if selectionSeed == nil || selection == nil {
            guard include else { return }
            selectionSeed = pixel
            refinements = [SubjectSegmenter.Refinement(point: pixel, include: true)]
        } else {
            refinements.append(SubjectSegmenter.Refinement(point: pixel, include: include))
        }
        updateOverlay()
        guard let seed = selectionSeed else { return }
        let refinements = refinements
        selectionTask = Task { [weak self] in
            let subject = await segmenter.segment(at: seed, refinements: refinements)
            guard let self, !Task.isCancelled else { return }
            setSelection(subject)
        }
    }

    /// The fallback subject under the view point `point`, or failing that the
    /// one whose bounds come nearest, if within a short reach.
    private func subjectIndex(at point: CGPoint) -> Int? {
        guard !subjects.isEmpty else { return nil }
        let pixel = imagePoint(point, clamped: false)
        if let hit = subjects.indices.filter({ subjects[$0].contains(pixel) })
            .min(by: { subjects[$0].bounds.area < subjects[$1].bounds.area }) {
            return hit
        }
        let reach: CGFloat = 32
        let distances = subjects.indices.map { index in
            let rect = viewRect(subjects[index].bounds)
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return (index, hypot(dx, dy), subjects[index].bounds.area)
        }
        return distances.filter { $0.1 <= reach }
            .min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, mode == .full, drag == nil else {
            super.otherMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // A hover segmentation may still be pending if the pointer only just
        // got here; segment the clicked spot rather than crop to a stale one.
        let isCurrent = selectionSeed.map { hypot(viewPoint($0).x - point.x, viewPoint($0).y - point.y) < 6 } ?? false
        if isSelectionPinned || !segmenterReady || isCurrent {
            if let selection {
                crop(to: selection)
            }
            return
        }
        guard let segmenter, imageFrame.contains(point) else { return }
        cancelSelectionTask()
        let seed = imagePoint(point)
        selectionTask = Task { [weak self] in
            let subject = await segmenter.segment(at: seed)
            guard let self, !Task.isCancelled, let subject else { return }
            selectionSeed = seed
            setSelection(subject)
            crop(to: subject)
        }
    }

    private func crop(to subject: Subject) {
        guard let item else { return }
        item.setCrop(subject.crop(in: item.originalSize))
        refinements = []
        layoutImage()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isSelectionPinned {
            clearSelection()
            hover(at: pointerLocation)
        } else {
            super.keyDown(with: event)
        }
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

        if event.modifierFlags.contains(.option) {
            refineSelection(at: point, include: !event.modifierFlags.contains(.shift))
            return
        }
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
        layoutImage()
        hover(at: convert(event.locationInWindow, from: nil))
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
    /// Pink tint over the hovered subject, cut to its silhouette by `highlightMask`.
    private let highlight = CALayer()
    private let highlightMask = CALayer()
    /// Dots where the selection was refined: included and excluded points.
    private let includeMarks = CAShapeLayer()
    private let excludeMarks = CAShapeLayer()

    var contentsScale: CGFloat = 2 {
        didSet {
            for layer in [dim, highlight, includeMarks, excludeMarks, border, handles, label] as [CALayer] {
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
        highlight.backgroundColor = NSColor(red: 0.93, green: 0.2, blue: 0.53, alpha: 0.45).cgColor
        highlightMask.contentsGravity = .resize
        for (marks, color) in [(includeMarks, NSColor.systemGreen), (excludeMarks, NSColor.systemRed)] {
            marks.fillColor = color.cgColor
            marks.strokeColor = NSColor.white.cgColor
            marks.lineWidth = 1.5
        }
    }

    func install(in parent: CALayer) {
        for layer in [dim, highlight, includeMarks, excludeMarks, border, handles, label] as [CALayer] {
            parent.addSublayer(layer)
        }
    }

    /// - Parameters:
    ///   - subject: The subject to tint: its bounds in view coordinates and
    ///     its silhouette, or nil to tint the whole box.
    ///   - marks: Refinement points in view coordinates, and whether each
    ///     was included.
    func update(
        imageFrame: CGRect,
        cropFrame: CGRect?,
        cropSize: PixelSize?,
        dimsOutside: Bool,
        isDragging: Bool,
        subject: (frame: CGRect, mask: CGImage?)?,
        marks: [(point: CGPoint, include: Bool)]
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let crop = cropFrame else {
            for layer in [dim, highlight, includeMarks, excludeMarks, border, handles, label] as [CALayer] {
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

        highlight.isHidden = subject == nil
        if let subject {
            highlight.frame = subject.frame
            highlightMask.frame = highlight.bounds
            highlightMask.contents = subject.mask
            highlight.mask = subject.mask == nil ? nil : highlightMask
        }
        for (layer, include) in [(includeMarks, true), (excludeMarks, false)] {
            let path = CGMutablePath()
            for mark in marks where mark.include == include {
                path.addEllipse(in: CGRect(x: mark.point.x - 4, y: mark.point.y - 4, width: 8, height: 8))
            }
            layer.path = path
            layer.isHidden = path.isEmpty
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
    var area: CGFloat { width * height }

    func insetBy(_ insets: NSEdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}
