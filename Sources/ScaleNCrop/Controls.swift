import AppKit
import SwiftUI

/// Which mouse button is dragging a slider.
enum SliderDrag {
    case primary
    case secondary
}

/// An integer slider with the monochrome track used throughout the app.
/// Double-clicking the knob resets it to `resetValue`. It can also be dragged
/// with the right mouse button.
struct PixelSlider: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let resetValue: Int
    /// Called with the button when a drag starts and nil when it ends.
    var onTrackingChanged: (SliderDrag?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> DoubleClickSlider {
        let slider = DoubleClickSlider()
        slider.cell = MonochromeSliderCell()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.focusRingType = .none
        slider.setAccessibilityLabel("Output size")
        slider.onDoubleClick = { context.coordinator.reset() }
        slider.onTrackingChanged = { context.coordinator.parent.onTrackingChanged($0) }
        return slider
    }

    func updateNSView(_ slider: DoubleClickSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(max(range.upperBound, range.lowerBound + 1))
        slider.isEnabled = range.upperBound > range.lowerBound
        if Int(slider.doubleValue.rounded()) != value {
            slider.doubleValue = Double(value)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PixelSlider

        init(parent: PixelSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let newValue = Int(sender.doubleValue.rounded())
            if newValue != parent.value {
                parent.value = newValue
            }
        }

        func reset() {
            parent.value = parent.resetValue
        }
    }
}

final class DoubleClickSlider: NSSlider {
    var onDoubleClick: (() -> Void)?
    var onTrackingChanged: ((SliderDrag?) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        onTrackingChanged?(.primary)
        // NSSlider tracks the drag inside this call and returns on mouse up.
        super.mouseDown(with: event)
        onTrackingChanged?(nil)
    }

    // NSSlider ignores the right button, so track it by hand: the value
    // follows the pointer along the track, as with a left-button drag.
    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onTrackingChanged?(.secondary)
        setValue(from: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        setValue(from: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        setValue(from: event)
        onTrackingChanged?(nil)
    }

    private func setValue(from event: NSEvent) {
        guard let cell = cell as? NSSliderCell else { return }
        let point = convert(event.locationInWindow, from: nil)
        let track = cell.trackRect
        let knob = cell.knobThickness
        let fraction = (point.x - track.minX - knob / 2) / max(track.width - knob, 1)
        let value = minValue + min(max(fraction, 0), 1) * (maxValue - minValue)
        guard value != doubleValue else { return }
        doubleValue = value
        sendAction(action, to: target)
    }
}

private final class MonochromeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(white: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let range = maxValue - minValue
        let fraction = range > 0 ? (doubleValue - minValue) / range : 0
        let filled = NSRect(
            x: track.minX,
            y: track.minY,
            width: track.width * min(max(fraction, 0), 1),
            height: track.height
        )
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}

extension Color {
    /// Fill for the buttons that write images to disk.
    static let savePink = Color(red: 0.93, green: 0.2, blue: 0.53)
}

struct MonochromeButtonStyle: ButtonStyle {
    var prominent = false
    /// A solid fill with white text, overriding `prominent`.
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        MonochromeButton(configuration: configuration, prominent: prominent, fill: fill)
    }

    private struct MonochromeButton: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let prominent: Bool
        let fill: Color?

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(fill == nil && prominent ? Color.black : Color.white)
                .background(fill ?? (prominent ? Color.white : Color.black), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Color.white.opacity(configuration.isPressed ? 0.65 : 0.32),
                            lineWidth: 1
                        )
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .focusEffectDisabled()
        }
    }
}

struct WindowAppearanceConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowAppearanceView()
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class WindowAppearanceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.backgroundColor = .black
        window.isOpaque = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // Since the macOS 27 SDK, SwiftUI's hosting view is stacked above the
        // titlebar container and hides the traffic lights; restore the order.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let closeButton = window?.standardWindowButton(.closeButton) else { return }
            // Closing the only window quits the app, so route the close button
            // through termination: the unsaved-changes prompt then runs while
            // the window is still open, and Cancel leaves it open.
            closeButton.target = self
            closeButton.action = #selector(WindowAppearanceView.closeButtonClicked)
            guard let titlebarContainer = closeButton.superview?.superview,
                  let frameView = titlebarContainer.superview else { return }
            frameView.addSubview(titlebarContainer, positioned: .above, relativeTo: nil)
        }
    }

    @objc private func closeButtonClicked() {
        NSApp.terminate(nil)
    }
}
