import AppKit
import ScaleNCropCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var items = [ImageItem]()
    var selectedID: UUID? {
        didSet { loadSelectedImage() }
    }
    /// The decoded pixels of the selected item, once available.
    private(set) var selectedImage: (id: UUID, image: WorkingImage)?
    var pixelatedPreview = true
    /// What the canvas shows. While the size slider is dragged it switches to
    /// the cropped area: fitted for a left-button drag, at actual size for a
    /// right-button drag.
    var canvasMode = CanvasMode.full
    var showingHelp = false
    private(set) var busyMessage: String?

    /// Decoded images, most recently used last. Unselected entries beyond the
    /// limit are dropped; they are re-decoded on demand.
    @ObservationIgnored private var decodeTasks = [UUID: Task<WorkingImage, Error>]()
    @ObservationIgnored private var decodeOrder = [UUID]()
    private let decodedImageLimit = 4

    var selected: ImageItem? {
        items.first { $0.id == selectedID }
    }

    var hasUnsavedChanges: Bool {
        items.contains(where: \.isModified)
    }

    // MARK: Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose images or folders of images"
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ urls: [URL]) {
        let files = urls.flatMap(Self.imageFiles(in:))
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                files.map { url in Result { try ImageInfo(url: url.standardizedFileURL) } }
            }.value

            var firstOpened: UUID?
            var failures = [String]()
            for result in results {
                switch result {
                case .success(let info):
                    if let existing = items.first(where: { $0.url == info.url }) {
                        firstOpened = firstOpened ?? existing.id
                        continue
                    }
                    let item = ImageItem(info: info)
                    items.append(item)
                    firstOpened = firstOpened ?? item.id
                case .failure(let error):
                    failures.append(error.localizedDescription)
                }
            }
            if let firstOpened {
                selectedID = firstOpened
            }
            if !failures.isEmpty {
                showError(title: "Some files couldn't be opened", message: failures.joined(separator: "\n"))
            }
        }
    }

    private nonisolated static func imageFiles(in url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return [url]
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Selection

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? -offset
        selectedID = items[min(max(index + offset, 0), items.count - 1)].id
    }

    // MARK: Decoding

    private func loadSelectedImage() {
        guard let item = selected else {
            selectedImage = nil
            return
        }
        if selectedImage?.id != item.id {
            selectedImage = nil
        }
        let id = item.id
        Task {
            do {
                let image = try await workingImage(for: item)
                if selectedID == id {
                    selectedImage = (id, image)
                }
            } catch {
                if selectedID == id {
                    showError(title: "Couldn't open “\(item.name)”", message: error.localizedDescription)
                }
            }
        }
    }

    private func workingImage(for item: ImageItem) async throws -> WorkingImage {
        let task: Task<WorkingImage, Error>
        if let existing = decodeTasks[item.id] {
            task = existing
        } else {
            let url = item.url
            task = Task.detached(priority: .userInitiated) {
                try WorkingImage(contentsOf: url)
            }
            decodeTasks[item.id] = task
        }
        decodeOrder.removeAll { $0 == item.id }
        decodeOrder.append(item.id)
        while decodeOrder.count > decodedImageLimit,
              let victim = decodeOrder.first(where: { $0 != selectedID }) {
            decodeOrder.removeAll { $0 == victim }
            decodeTasks[victim] = nil
        }
        do {
            return try await task.value
        } catch {
            discardDecodedImage(for: item.id)
            throw error
        }
    }

    private func discardDecodedImage(for id: UUID) {
        decodeTasks[id] = nil
        decodeOrder.removeAll { $0 == id }
    }

    // MARK: Auto crop

    func autoCrop(_ item: ImageItem) {
        Task { await autoCrop([item]) }
    }

    func autoCropAll() {
        Task { await autoCrop(items) }
    }

    /// Crops each of `items` to its main subject, as a middle click on it
    /// would. Images without a subject are left alone.
    private func autoCrop(_ items: [ImageItem]) async {
        var failures = [String]()
        for (index, item) in items.enumerated() {
            busyMessage = items.count == 1 ? "Finding the subject…" : "Auto-cropping \(index + 1) of \(items.count)…"
            do {
                let image = try await workingImage(for: item)
                let subject = await Task.detached(priority: .userInitiated) {
                    await Subjects.main(in: image)
                }.value
                if let subject, self.items.contains(where: { $0 === item }) {
                    item.setCrop(subject.crop(in: item.originalSize))
                }
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        busyMessage = nil
        if !failures.isEmpty {
            showError(title: "Some images couldn't be auto-cropped", message: failures.joined(separator: "\n"))
        }
    }

    // MARK: Closing

    /// Closes `item`, asking first if it has unsaved edits.
    func close(_ item: ImageItem) {
        guard item.isModified else {
            remove(item)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(item.name)” before closing?"
        alert.informativeText = "Your crop and resize will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveAndClose(item)
        case .alertThirdButtonReturn:
            remove(item)
        default:
            break
        }
    }

    /// Closes every image without asking, which quits the app.
    private func removeAll() {
        for item in items {
            discardDecodedImage(for: item.id)
        }
        items.removeAll()
        selectedID = nil
        NSApp.terminate(nil)
    }

    private func remove(_ item: ImageItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        discardDecodedImage(for: item.id)
        if selectedID == item.id {
            selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
        // The app starts empty, but once images have been opened, closing the
        // last one quits.
        if items.isEmpty {
            NSApp.terminate(nil)
        }
    }

    // MARK: Saving

    /// One image to write: the item's edits rendered to `url` as `type`.
    private typealias SaveJob = (item: ImageItem, url: URL, type: UTType)

    func save(_ item: ImageItem) {
        Task { await save(item, closing: false) }
    }

    func saveAndClose(_ item: ImageItem) {
        Task { await save(item, closing: true) }
    }

    /// Writes a copy elsewhere. The item keeps its original and edits, unless
    /// the copy replaced its own original.
    func saveAs(_ item: ImageItem) {
        Task {
            guard let (url, type) = chooseSaveDestination(for: item) else { return }
            await export([(item, url, type)]) { _ in "Saving “\(url.lastPathComponent)”…" }
        }
    }

    /// Saves every edited image over its original.
    func saveAll() {
        Task { _ = await saveAllModified() }
    }

    /// Writes every open image (edited or not) into a chosen folder. The open
    /// images keep their original files and edits, unless a copy replaced one.
    func saveAllIn() {
        Task { await saveAllIn(closing: false) }
    }

    /// Like Save All In…, then closes every image (and so quits) once all of
    /// them have been written.
    func saveAllInAndClose() {
        Task { await saveAllIn(closing: true) }
    }

    private func saveAllIn(closing: Bool) async {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save All Here"
        panel.message = "Choose a folder for all \(items.count) images"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        // Default names: each image's own name, made unique among the batch.
        var usedNames = Set<String>()
        var plan: [SaveJob] = items.map { item in
            let type = ImageExporter.canWrite(item.type) ? item.type! : .jpeg
            let ext = Self.fileExtension(for: item, type: type)
            let name = Self.uniqueName(base: item.baseName, ext: ext) { usedNames.contains($0.lowercased()) }
            usedNames.insert(name.lowercased())
            return (item, folder.appendingPathComponent(name), type)
        }
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        let conflicts = plan.indices.filter { exists(plan[$0].url) }
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = conflicts.count == 1
                ? "“\(plan[conflicts[0]].url.lastPathComponent)” already exists in “\(folder.lastPathComponent)”."
                : "\(conflicts.count) files already exist in “\(folder.lastPathComponent)”."
            alert.informativeText = "Replacing them will overwrite their current contents. Open images whose originals are replaced are reloaded, losing their crop and resize. Saving with new names never overwrites anything."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Save with New Names")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break
            case .alertSecondButtonReturn:
                // Every name must be free both on disk and in the batch, which
                // includes the non-conflicting names already planned.
                var reserved = Set(plan.indices.filter { !conflicts.contains($0) }.map {
                    plan[$0].url.lastPathComponent.lowercased()
                })
                for index in conflicts {
                    let job = plan[index]
                    let name = Self.uniqueName(base: job.item.baseName, ext: job.url.pathExtension) {
                        reserved.contains($0.lowercased()) || exists(folder.appendingPathComponent($0))
                    }
                    reserved.insert(name.lowercased())
                    plan[index].url = folder.appendingPathComponent(name)
                }
            default:
                return
            }
        }

        let count = plan.count
        let ok = await export(plan) { "Saving \($0 + 1) of \(count)…" }
        if ok && closing {
            removeAll()
        }
    }

    /// Returns false if any save failed or was cancelled.
    func saveAllModified() async -> Bool {
        let modified = items.filter(\.isModified)
        for (index, item) in modified.enumerated() {
            let message = modified.count == 1 ? "Saving “\(item.name)”…" : "Saving \(index + 1) of \(modified.count)…"
            guard await save(item, closing: false, message: message) else { return false }
        }
        return true
    }

    @discardableResult
    private func save(_ item: ImageItem, closing: Bool, message: String? = nil) async -> Bool {
        guard item.isModified else {
            if closing { remove(item) }
            return true
        }
        let destination: (URL, UTType)
        if let type = item.type, ImageExporter.canWrite(type) {
            destination = (item.url, type)
        } else if let chosen = chooseSaveDestination(for: item) {
            destination = chosen
        } else {
            return false
        }
        let ok = await export([(item, destination.0, destination.1)]) { _ in
            message ?? "Saving “\(destination.0.lastPathComponent)”…"
        }
        if ok && closing {
            remove(item)
        }
        return ok
    }

    /// Writes the jobs in two stages: every image is first rendered to a
    /// temporary file, while all originals are still intact, and only then are
    /// the files moved into place. So one image's output can never replace a
    /// file another image still needs to read, and a failed render leaves
    /// every file untouched. Afterwards, any open image whose original was
    /// replaced (including by its own save) is reloaded from the new file,
    /// with its crop and resize reset.
    @discardableResult
    private func export(_ jobs: [SaveJob], message: (Int) -> String) async -> Bool {
        defer { busyMessage = nil }
        var staged = [(temp: URL, job: SaveJob)]()
        var replaced = [URL]()
        defer {
            for (temp, _) in staged {
                try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
            }
            reloadItems(at: replaced)
        }
        do {
            for (index, job) in jobs.enumerated() {
                busyMessage = message(index)
                let image = try await workingImage(for: job.item)
                let edits = job.item.edits
                let source = job.item.url
                let type = job.type
                let temp = try Self.temporaryURL(near: job.url)
                staged.append((temp, job))
                try await Task.detached(priority: .userInitiated) {
                    let output = try ImageExporter.render(image, edits: edits)
                    try ImageExporter.write(output, to: temp, type: type, metadataSource: source)
                }.value
            }
            for (temp, job) in staged {
                if FileManager.default.fileExists(atPath: job.url.path) {
                    _ = try FileManager.default.replaceItemAt(job.url, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: job.url)
                }
                replaced.append(job.url)
            }
            return true
        } catch {
            showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    /// Reloads, in place, every open image whose file is one of `urls`.
    private func reloadItems(at urls: [URL]) {
        var failures = [String]()
        for item in items where urls.contains(where: { Self.isSameFile($0, item.url) }) {
            discardDecodedImage(for: item.id)
            do {
                item.reload(from: try ImageInfo(url: item.url))
            } catch {
                failures.append(error.localizedDescription)
            }
            if selectedID == item.id {
                loadSelectedImage()
            }
        }
        if !failures.isEmpty {
            showError(title: "Some saved images couldn't be reloaded", message: failures.joined(separator: "\n"))
        }
    }

    /// A fresh file in its own temporary folder, on the same volume as
    /// `destination` where possible so moving it into place is cheap.
    private static func temporaryURL(near destination: URL) throws -> URL {
        let folder = (try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(), create: true
        )) ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(destination.lastPathComponent)
    }

    private func chooseSaveDestination(for item: ImageItem) -> (URL, UTType)? {
        let type = ImageExporter.canWrite(item.type) ? item.type! : .jpeg
        let panel = NSSavePanel()
        panel.allowedContentTypes = ImageExporter.writableTypes
        panel.showsContentTypes = true
        panel.currentContentType = type
        panel.canCreateDirectories = true
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.nameFieldStringValue = item.url.deletingPathExtension()
            .appendingPathExtension(type.preferredFilenameExtension ?? "jpg").lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let chosenType = panel.currentContentType
            ?? UTType(filenameExtension: url.pathExtension)
            ?? type
        return (url, chosenType)
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            == b.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    private static func fileExtension(for item: ImageItem, type: UTType) -> String {
        type == item.type ? item.url.pathExtension : (type.preferredFilenameExtension ?? "jpg")
    }

    /// "base.ext", or the first of "base 2.ext", "base 3.ext"… not taken.
    private static func uniqueName(base: String, ext: String, isTaken: (String) -> Bool) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var name = base + suffix
        var counter = 2
        while isTaken(name) {
            name = "\(base) \(counter)\(suffix)"
            counter += 1
        }
        return name
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
