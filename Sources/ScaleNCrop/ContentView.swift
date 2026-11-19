import AppKit
import ScaleNCropCore
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel.shared
    @State private var openedFiles = OpenedFiles.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 208)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            ZStack {
                Color.black
                if let item = model.selected {
                    ImageEditor(model: model, item: item)
                } else {
                    emptyState
                }
            }
        }
        .foregroundStyle(.white)
        .background(Color.black)
        .background { WindowAppearanceConfigurator() }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        }
        .overlay {
            if let message = model.busyMessage {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView(message)
                        .padding(22)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.35))
                        }
                }
            }
        }
        .onChange(of: openedFiles.pending, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            openedFiles.pending.removeAll()
            model.open(urls)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "crop")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Button("Open Images…", systemImage: "photo.badge.plus", action: model.showOpenPanel)
                .buttonStyle(MonochromeButtonStyle())
                .focusable(false)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.items.count) image\(model.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: model.showOpenPanel) {
                    Image(systemName: "plus")
                }
                .buttonStyle(MonochromeButtonStyle())
                .help("Open images")
                .focusable(false)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.items) { item in
                            ThumbnailCell(item: item, isSelected: item.id == model.selectedID)
                                .id(item.id)
                                .onTapGesture {
                                    model.selectedID = item.id
                                    focused = true
                                }
                                .contextMenu { ItemMenu(model: model, item: item) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    model.selectPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.selectNext()
                    return .handled
                }
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id)
                    }
                }
            }

            Button(action: model.saveAllIn) {
                Label("Save All In…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MonochromeButtonStyle(fill: .savePink))
            .disabled(model.items.isEmpty)
            .help("Save every image into a chosen folder")
            .focusable(false)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Color.black)
    }
}

private struct ThumbnailCell: View {
    let item: ImageItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)

            HStack(spacing: 5) {
                if item.isModified {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(sizeDescription)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            Color.white.opacity(isSelected ? 0.1 : 0),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(isSelected ? 0.6 : 0.12), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sizeDescription: String {
        let original = item.originalSize
        let output = item.edits.outputSize
        guard item.isModified else { return "\(original.width) × \(original.height)" }
        return "\(original.width)×\(original.height) → \(output.width)×\(output.height)"
    }
}

/// Save/close actions shared by the context menu.
struct ItemMenu: View {
    let model: AppModel
    let item: ImageItem

    var body: some View {
        Button("Save") { model.save(item) }
            .disabled(!item.isModified)
        Button("Save and Close") { model.saveAndClose(item) }
        Button("Save As…") { model.saveAs(item) }
        Divider()
        Button("Save All") { model.saveAll() }
            .disabled(!model.hasUnsavedChanges)
        Button("Save All In…") { model.saveAllIn() }
        Divider()
        Button("Reset Crop") { item.resetCrop() }
            .disabled(!item.isCropped)
        Button("Revert Changes") { item.revert() }
            .disabled(!item.isModified)
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Button("Close") { model.close(item) }
    }
}

// MARK: - Editor

private struct ImageEditor: View {
    let model: AppModel
    let item: ImageItem

    private static let barHeight: CGFloat = 64

    var body: some View {
        ImageCanvas(
            item: item,
            image: model.selectedImage?.id == item.id ? model.selectedImage?.image : nil,
            mode: model.canvasMode,
            pixelated: model.pixelatedPreview,
            insets: NSEdgeInsets(top: 52, left: 24, bottom: Self.barHeight + 20, right: 24)
        )
        .contextMenu { ItemMenu(model: model, item: item) }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { scaleBar }
        .overlay {
            if model.selectedImage?.id != item.id {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(Color.black.opacity(0.6), in: Circle())
            }
        }
    }

    // MARK: Crop controls

    private var topBar: some View {
        HStack(spacing: 8) {
            if item.isCropped {
                Button("Reset Crop", systemImage: "arrow.uturn.backward") { item.resetCrop() }
            }
        }
        .buttonStyle(MonochromeButtonStyle())
        .focusable(false)
        .frame(height: 30)
        .padding(.top, 12)
        .padding(.horizontal, 16)
    }

    // MARK: Scale controls

    private var scaleBar: some View {
        let output = item.edits.outputSize
        let percent = Double(item.targetLongSide) / Double(item.maxLongSide) * 100
        return HStack(spacing: 12) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .foregroundStyle(.secondary)
                .help("Downscale: longest side in pixels")

            PixelSlider(
                value: Binding(get: { item.targetLongSide }, set: { item.targetLongSide = $0 }),
                range: 1...item.maxLongSide,
                resetValue: item.maxLongSide,
                onTrackingChanged: { drag in
                    model.canvasMode = switch drag {
                    case .primary: .cropFit
                    case .secondary: .cropActualSize
                    case nil: .full
                    }
                }
            )
            .frame(minWidth: 120)
            .help("Longest side in pixels. Drag to preview the crop fitted; right-drag to preview it at actual size. Double-click to reset.")

            TextField(
                "Size",
                value: Binding(get: { item.targetLongSide }, set: { item.targetLongSide = $0 }),
                format: .number.grouping(.never)
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospacedDigit())
            .frame(width: 52)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.25)) }
            .help("Longest side in pixels")

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(output.width) × \(output.height) px")
                Text(percent.formatted(.number.precision(.fractionLength(percent < 10 ? 1 : 0))) + "%")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .frame(width: 104, alignment: .leading)

            Button {
                model.pixelatedPreview.toggle()
            } label: {
                Image(systemName: "square.grid.3x3.fill")
            }
            .buttonStyle(MonochromeButtonStyle(prominent: model.pixelatedPreview))
            .help("Show pixels without smoothing")
            .focusable(false)

            Button("Save & Close", systemImage: "checkmark") { model.saveAndClose(item) }
                .buttonStyle(MonochromeButtonStyle(fill: .savePink))
                .help("Save over the original and close it")
                .focusable(false)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.barHeight - 16)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.18))
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
