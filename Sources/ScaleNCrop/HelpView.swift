import AppKit
import SwiftUI

/// How to use the app, shown as a sheet from the Help menu.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scale n Crop Help")
                        .font(.title2.weight(.semibold))
                    Text("Crop images, then downscale them with high-quality resampling.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    opening
                    cropping
                    subjects
                    selectAnything
                    scaling
                    saving
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(MonochromeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .focusable(false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 680)
        .foregroundStyle(.white)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var opening: some View {
        HelpSection("Opening Images", systemImage: "photo.on.rectangle") {
            Text("Open images with File › Open…, the + button above the sidebar, or by dragging files onto the window or the Dock icon. You can also use Open With in Finder. Opening a folder opens every image directly inside it.")
            Text("Open images are listed in the sidebar. Click a thumbnail to edit it. Thumbnails are dimmed outside the crop. Edited images have a dot next to their name, and their size shows the original and output dimensions.")
            ShortcutRow("⌘O", "Open images or folders")
            ShortcutRow("↑ ↓", "Previous or next image, when the sidebar is focused")
            ShortcutRow("⌘[  ⌘]", "Previous or next image")
            ShortcutRow("⌘W", "Close the image, asking first if it has unsaved changes")
        }
    }

    private var cropping: some View {
        HelpSection("Cropping", systemImage: "crop") {
            Text("Drag across the image to draw a crop. Everything outside it is dimmed, and its size in pixels is shown as you drag.")
            Bullet("Drag inside the crop to move it.")
            Bullet("Drag an edge or corner to resize it. The crop scales from the opposite side, so the spot you grabbed stays under the pointer.")
            Bullet("Dragging outside the current crop draws a new one.")
            ShortcutRow("⇧⌘R", "Reset Crop (also the button above the image)")
        }
    }

    private var subjects: some View {
        HelpSection("Crop to a Subject", systemImage: "person.crop.rectangle") {
            Text("People, animals and other prominent subjects are found automatically. Hover over one to tint it pink, then click the middle mouse button to crop to it with a small margin.")
            Text("Image › Auto Crop does this for the image's main subject: when there are several, the one that draws the eye most, which favours subjects that are both large and prominent. Auto Crop All, also the button above Save All In…, does it for every open image and replaces their crops. Images with no subject found are left as they are.")
            ShortcutRow("⇧⌘A", "Auto Crop the current image")
            ShortcutRow("⌥⇧⌘A", "Auto Crop All images")
        }
    }

    private var selectAnything: some View {
        HelpSection("Crop to Anything", systemImage: "wand.and.rays") {
            Text("Hold ⌥ (Option) and hover to select whatever is under the pointer, including objects in the background. While still holding ⌥, refine the selection:")
            ShortcutRow("⌥-click", "Add a point to include (+)")
            ShortcutRow("⌥-right-click", "Add a point to exclude (−)")
            ShortcutRow("Middle-click", "Crop to the selection")
            Text("Releasing ⌥ clears the points. The first time, the segmentation model may take a few seconds to load.")
                .foregroundStyle(.secondary)
        }
    }

    private var scaling: some View {
        HelpSection("Scaling", systemImage: "arrow.down.right.and.arrow.up.left") {
            Text("The slider at the bottom sets the length of the output's longest side in pixels. To enter an exact size, type it in the box next to the slider. The output dimensions and the percentage of the cropped size are shown alongside.")
            Bullet("Drag the slider to preview just the crop, fitted to the window.")
            Bullet("Right-drag the slider to preview the crop at actual size, centred on its most eye-catching point.")
            Bullet("Double-click the slider's knob to go back to full size.")
            Text("The scale is a percentage, so changing the crop keeps the same percentage. Images are only ever downscaled.")
            ShortcutRow("⇧⌘P", "Pixelated Preview: show pixels without smoothing (also the grid button)")
        }
    }

    private var saving: some View {
        HelpSection("Saving", systemImage: "square.and.arrow.down") {
            Text("Saving overwrites the original file in its own format. Lossy formats are written at maximum quality. Photo metadata such as EXIF and location is kept.")
            ShortcutRow("⌘S", "Save over the original")
            ShortcutRow("⌥⌘W", "Save and Close (also the pink button)")
            ShortcutRow("⇧⌘S", "Save As…: choose a new name, place or format")
            ShortcutRow("⌥⌘S", "Save All edited images over their originals")
            ShortcutRow("⌥⇧⌘S", "Save All In…: write every open image into a folder")
            Text("Save As… and Save All In… write copies: the open images keep pointing at their originals, with their crop and scale intact. Save All In and Close… does the same, then closes every image and quits once all are written.")
            Text("Save All In… asks before replacing existing files, or can save with new names (“image 2.jpg”) so nothing is overwritten. If a save replaces an open image's original, that image is reloaded with its crop and resize reset. If the app can't write an image's format, saving asks for a new file, as JPEG by default.")
            Text("Image › Revert Changes discards an image's crop and scale. Right-click a thumbnail or the image for these commands and Show in Finder. When you quit, you're asked about any unsaved changes.")
        }
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Bullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    init(_ keys: String, _ action: String) {
        self.keys = keys
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.25)) }
                .frame(width: 120, alignment: .leading)
            Text(action)
        }
    }
}
