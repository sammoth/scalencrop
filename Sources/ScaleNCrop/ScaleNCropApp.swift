import AppKit
import SwiftUI

/// Files handed to the app by Finder ("Open With", drag onto Dock icon), buffered
/// until the main window is ready to consume them.
@MainActor
@Observable
final class OpenedFiles {
    static let shared = OpenedFiles()
    var pending = [URL]()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Files opened at launch arrive here. Implementing this takes over from
    // SwiftUI's onOpenURL, which only delivers the first file when several are
    // opened at once; SwiftUI also creates the main window while handling it.
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenedFiles.shared.pending.append(contentsOf: urls)
    }

    // Once running, handle the open-documents Apple Event directly instead:
    // SwiftUI's delegate sees application(_:open:) first and, for a Window
    // scene, closes and reopens the window before forwarding it.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @MainActor @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let files = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let descriptors = files.numberOfItems == 0
            ? [files]
            : (1...files.numberOfItems).compactMap(files.atIndex)
        OpenedFiles.shared.pending.append(contentsOf: descriptors.compactMap(\.fileURLValue))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let unsaved = model.items.filter(\.isModified).count
        guard unsaved > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = unsaved == 1
            ? "1 image has unsaved changes."
            : "\(unsaved) images have unsaved changes."
        alert.informativeText = "Do you want to save them before quitting?"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                let saved = await model.saveAllModified()
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct ScaleNCropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.shared

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        DispatchQueue.main.async {
            NSApplication.shared.activate()
        }
    }

    var body: some Scene {
        Window("Scale n Crop", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…", action: model.showOpenPanel)
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.selected.map(model.save) }
                    .keyboardShortcut("s")
                    .disabled(model.selected?.isModified != true)
                Button("Save and Close") { model.selected.map(model.saveAndClose) }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(model.selected == nil)
                Button("Save As…") { model.selected.map(model.saveAs) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.selected == nil)
                Divider()
                Button("Save All", action: model.saveAll)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.hasUnsavedChanges)
                Button("Save All In…", action: model.saveAllIn)
                    .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                    .disabled(model.items.isEmpty)
                Button("Save All In and Close…", action: model.saveAllInAndClose)
                    .disabled(model.items.isEmpty)
                Divider()
                if model.items.isEmpty {
                    Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w")
                } else {
                    Button("Close Image") { model.selected.map(model.close) }
                        .keyboardShortcut("w")
                        .disabled(model.selected == nil)
                }
            }
            CommandMenu("Image") {
                Button("Reset Crop") { model.selected?.resetCrop() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selected?.isCropped != true)
                Button("Revert Changes") { model.selected?.revert() }
                    .disabled(model.selected?.isModified != true)
                Divider()
                Button("Auto Crop") { model.selected.map(model.autoCrop) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.selected == nil || model.busyMessage != nil)
                Button("Auto Crop All", action: model.autoCropAll)
                    .keyboardShortcut("a", modifiers: [.command, .option, .shift])
                    .disabled(model.items.isEmpty || model.busyMessage != nil)
                Divider()
                Toggle("Pixelated Preview", isOn: $model.pixelatedPreview)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Previous Image", action: model.selectPrevious)
                    .keyboardShortcut("[")
                    .disabled(model.items.count < 2)
                Button("Next Image", action: model.selectNext)
                    .keyboardShortcut("]")
                    .disabled(model.items.count < 2)
            }
            CommandGroup(replacing: .help) {
                Button("Scale n Crop Help") { model.showingHelp = true }
                    .keyboardShortcut("?")
            }
        }
    }
}
