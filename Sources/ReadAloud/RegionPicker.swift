// RegionPicker: the crosshair. Click a paragraph, or drag a box. Esc cancels.
//
// A clear window covers every screen for a moment, so the click goes to us and not
// to the app underneath. When you're done it disappears and the app you were in gets
// its focus back.
import AppKit

final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class PickerView: NSView {
    private var start: NSPoint?
    private var current: NSPoint?
    /// The picked area in screen coordinates; zero size means a click; nil means cancelled.
    var finish: ((NSRect?) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with e: NSEvent) { start = e.locationInWindow; current = start; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current = e.locationInWindow; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard let s = start, let w = window else { return }
        let c = e.locationInWindow
        let box = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
        let isClick = box.width < 6 && box.height < 6
        finish?(w.convertToScreen(isClick ? NSRect(origin: c, size: .zero) : box))
    }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { finish?(nil) } }   // Esc

    // A label at the top of the screen, so it's obvious what mode you're in.
    private func drawHint() {
        let text = "Click a paragraph to read from there, or drag a box     Esc to cancel" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 20, y: bounds.maxY - 130,
                         width: size.width + 40, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 20, y: box.minY + 10), withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        drawHint()
        guard let s = start, let c = current else { return }
        let box = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
        NSColor.clear.setFill()
        box.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let edge = NSBezierPath(rect: box.insetBy(dx: 0.75, dy: 0.75))
        edge.lineWidth = 1.5
        edge.stroke()
    }
}

@MainActor
final class RegionPicker {
    private var windows: [PickerWindow] = []
    private var previousApp: NSRunningApplication?
    private var done: ((NSRect?) -> Void)?
    var isActive: Bool { !windows.isEmpty }

    func pick(_ completion: @escaping (NSRect?) -> Void) {
        guard windows.isEmpty else { return }
        done = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.setFrame(screen.frame, display: false)
            let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.finish = { [weak self] area in self?.end(area) }
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
        }
        // Take the keyboard (for Esc) on the screen the mouse is on.
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let main = windows.first { $0.frame.contains(mouse) } ?? windows.first
        main?.makeKeyAndOrderFront(nil)
        main?.makeFirstResponder(main?.contentView)
        NSCursor.crosshair.set()
    }

    func cancel() { end(nil) }

    private func end(_ area: NSRect?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        previousApp?.activate()                 // hand focus back to the app you were in
        let d = done
        done = nil
        d?(area)
    }
}
