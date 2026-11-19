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

    private func remove(_ item: ImageItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        discardDecodedImage(for: item.id)
        if selectedID == item.id {
            selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
    }

    // MARK: Saving

    func save(_ item: ImageItem) {
        Task { await save(item, closing: false) }
    }

    func saveAndClose(_ item: ImageItem) {
        Task { await save(item, closing: true) }
    }

    func saveAs(_ item: ImageItem) {
        Task {
            guard let (url, type) = chooseSaveDestination(for: item) else { return }
            await perform("Saving “\(url.lastPathComponent)”…") {
                try await self.write(item, to: url, type: type)
            }
        }
    }

    /// Saves every edited image over its original.
    func saveAll() {
        Task { _ = await saveAllModified() }
    }

    /// Writes every open image (edited or not) into a chosen folder.
    func saveAllIn() {
        Task {
            guard !items.isEmpty else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save All Here"
            panel.message = "Choose a folder for all \(items.count) images"
            guard panel.runModal() == .OK, let folder = panel.url else { return }

            var usedNames = Set<String>()
            let plan = items.map { item in
                let type = ImageExporter.canWrite(item.type) ? item.type! : .jpeg
                let url = Self.uniqueURL(in: folder, for: item, type: type, usedNames: &usedNames)
                return (item, url, type)
            }
            let conflicts = plan.filter { _, url, _ in FileManager.default.fileExists(atPath: url.path) }
            if !conflicts.isEmpty {
                let alert = NSAlert()
                alert.messageText = conflicts.count == 1
                    ? "“\(conflicts[0].1.lastPathComponent)” already exists in “\(folder.lastPathComponent)”."
                    : "\(conflicts.count) files already exist in “\(folder.lastPathComponent)”."
                alert.informativeText = "Replacing them will overwrite their current contents."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            for (index, (item, url, type)) in plan.enumerated() {
                let ok = await perform("Saving \(index + 1) of \(plan.count)…") {
                    try await self.write(item, to: url, type: type)
                }
                if !ok { break }
            }
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
        let ok = await perform(message ?? "Saving “\(destination.0.lastPathComponent)”…") {
            try await self.write(item, to: destination.0, type: destination.1)
        }
        if ok && closing {
            remove(item)
        }
        return ok
    }

    private func write(_ item: ImageItem, to url: URL, type: UTType) async throws {
        let image = try await workingImage(for: item)
        let edits = item.edits
        let source = item.url
        let info = try await Task.detached(priority: .userInitiated) {
            let output = try ImageExporter.render(image, edits: edits)
            try ImageExporter.write(output, to: url, type: type, metadataSource: source)
            return try ImageInfo(url: url)
        }.value

        discardDecodedImage(for: item.id)
        item.reload(from: info)
        if selectedID == item.id {
            loadSelectedImage()
        }
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

    private static func uniqueURL(in folder: URL, for item: ImageItem, type: UTType, usedNames: inout Set<String>) -> URL {
        let base = item.url.deletingPathExtension().lastPathComponent
        let ext = type == item.type ? item.url.pathExtension : (type.preferredFilenameExtension ?? "jpg")
        var name = "\(base).\(ext)"
        var counter = 2
        while usedNames.contains(name.lowercased()) {
            name = "\(base) \(counter).\(ext)"
            counter += 1
        }
        usedNames.insert(name.lowercased())
        return folder.appendingPathComponent(name)
    }

    @discardableResult
    private func perform(_ message: String, _ work: @escaping () async throws -> Void) async -> Bool {
        busyMessage = message
        defer { busyMessage = nil }
        do {
            try await work()
            return true
        } catch {
            showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
