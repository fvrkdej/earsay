// Highlighter: a soft highlight over the paragraph (or list line, or table row) she's
// reading, in the app you clicked in. It follows her down the page.
//
// - Where things are comes from the same accessibility information the click read used
//   (AXText.Read): each paragraph's elements and their positions on screen.
// - Positions are checked 5 times a second, so the highlight stays put when you scroll.
// - With "Scroll that app to keep up" on, when she moves to a paragraph that's out of view
//   the app is asked to scroll it into view (the same request VoiceOver makes).
// - It shows only while that app is in front, and only inside its window.
// - The highlight is a see-through window that ignores the mouse: clicks go to the app below.
import AppKit
import ApplicationServices

@MainActor
final class Highlighter {
    private let panel: NSPanel
    private let box = NSView()
    private var source: AXText.Read?
    private var current: [AXUIElement] = []
    private var key = ""                 // "paragraph:line" now showing; scroll only when it changes
    private var ticker: Timer?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.borderWidth = 1.5
        panel.contentView = box
        recolor()
    }

    private func recolor() {
        let c = NSColor.controlAccentColor
        box.layer?.backgroundColor = c.withAlphaComponent(0.14).cgColor
        box.layer?.borderColor = c.withAlphaComponent(0.55).cgColor
    }

    /// A clicked read started: remember where its paragraphs are.
    func begin(_ read: AXText.Read) {
        end()
        guard !read.paragraphs.isEmpty else { return }
        source = read
        recolor()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func end() {
        ticker?.invalidate()
        ticker = nil
        source = nil
        current = []
        key = ""
        panel.orderOut(nil)
    }

    var active: Bool { source != nil }

    /// She moved on: paragraph `p`, line `line` inside it.
    func follow(paragraph p: Int, line: Int) {
        guard let src = source, Prefs.shared.highlightOnScreen, p >= 0, p < src.paragraphs.count else {
            panel.orderOut(nil); return
        }
        let els = src.paragraphs[p]
        current = line < els.count ? [els[line]] : els      // can't tell the line: the whole paragraph
        let k = "\(p):\(line)"
        if k != key {
            key = k
            if Prefs.shared.scrollAlong, let el = current.first, !inView(el) {
                AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
            }
        }
        place()
    }

    // Is this element fully inside its window's visible area?
    private func inView(_ el: AXUIElement) -> Bool {
        guard let f = AXText.frame(el), let w = windowFrame() else { return true }
        return w.contains(CGRect(x: f.midX, y: f.minY, width: 1, height: min(f.height, 40)))
    }

    private func windowFrame() -> CGRect? {
        guard let pid = source?.pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let w = AXText.attr(app, kAXFocusedWindowAttribute) else { return nil }
        return AXText.frame(w as! AXUIElement)
    }

    // Put the highlight over the current element, clipped to the app's window.
    private func place() {
        guard let src = source, Prefs.shared.highlightOnScreen, !current.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == src.pid,
              let win = windowFrame() else { panel.orderOut(nil); return }
        var area = CGRect.null
        for el in current { if let f = AXText.frame(el), f.width > 1, f.height > 1 { area = area.union(f) } }
        guard !area.isNull else { panel.orderOut(nil); return }
        area = area.insetBy(dx: -6, dy: -2).intersection(win)
        guard !area.isNull, area.height > 6 else { panel.orderOut(nil); return }
        // Accessibility measures from the top-left of the main screen; windows from the bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height)
        if panel.isVisible && panel.frame.integral == frame.integral { return }
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }
}
