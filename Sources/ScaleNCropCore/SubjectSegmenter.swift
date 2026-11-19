import CoreGraphics
import Vision

/// Segments whatever is at a point of one image (background objects
/// included) with Vision's promptable segmentation, grown or trimmed by
/// further points.
public actor SubjectSegmenter {
    /// A point added to a selection: included to take in what's there, or
    /// excluded to leave it out.
    public struct Refinement: Equatable, Sendable {
        public var point: CGPoint
        public var include: Bool

        public init(point: CGPoint, include: Bool) {
            self.point = point
            self.include = include
        }
    }

    private let image: WorkingImage
    /// The last selection's request, seed and points. Vision keeps the image's
    /// encoding on the request, so adding points to it is much cheaper than
    /// starting a new one.
    private var request: GenerateIterativeSegmentationRequest?
    private var seed: CGPoint?
    private var refinements: [Refinement] = []
    /// The latest call, which the next waits for: a request mustn't gain
    /// points while it's being performed.
    private var queue: Task<Subject?, Never>?

    public init(image: WorkingImage) {
        self.image = image
    }

    /// Downloads Vision's model if needed and loads it, which takes a few
    /// seconds the first time. Throws if the model is unavailable.
    public func prepare() async throws {
        let probe = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
        if await probe.assetStatus != .ready {
            try await probe.downloadAssets()
        }
        _ = try await probe.perform(on: image.cgImage)
    }

    /// The subject at `seed`, adjusted by `refinements` (original-image pixels,
    /// top-left origin). Reuses the last request when this only adds points to it.
    public func segment(at seed: CGPoint, refinements: [Refinement] = []) async -> Subject? {
        let previous = queue
        let task = Task {
            _ = await previous?.value
            return await run(seed: seed, refinements: refinements)
        }
        queue = task
        return await task.value
    }

    private func run(seed: CGPoint, refinements: [Refinement]) async -> Subject? {
        if request == nil || seed != self.seed || !refinements.starts(with: self.refinements) {
            let request = GenerateIterativeSegmentationRequest(seedPoint: normalized(seed))
            request.qualityLevel = .accurate
            self.request = request
            self.seed = seed
            self.refinements = []
        }
        guard let request else { return nil }
        do {
            for refinement in refinements.dropFirst(self.refinements.count) {
                if refinement.include {
                    try request.addIncludedPoint(normalized(refinement.point))
                } else {
                    try request.addExcludedPoint(normalized(refinement.point))
                }
            }
        } catch {
            self.request = nil
            return nil
        }
        self.refinements = refinements
        return await perform(request)
    }

    /// Vision's normalized points have a bottom-left origin.
    private func normalized(_ point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: point.x / Double(image.size.width),
            y: 1 - point.y / Double(image.size.height)
        )
    }

    private func perform(_ request: GenerateIterativeSegmentationRequest) async -> Subject? {
        guard let observation = try? await request.perform(on: image.cgImage),
              let mask = try? observation.cgImage,
              let (alpha, width, height) = Self.alphaValues(of: mask) else { return nil }
        return Subjects.subject(fromMask: alpha, width: width, height: height, imageSize: image.size)
    }

    /// The mask's values as bytes, row-major from the top.
    private static func alphaValues(of image: CGImage) -> ([UInt8], Int, Int)? {
        let width = image.width, height = image.height
        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (values, width, height) : nil
    }
}
