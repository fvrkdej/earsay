// Highlighter: a soft highlight over the paragraph (or list line, or table row) she's
// reading, in the app you clicked in. It follows her down the page.
//
// - Where things are comes from the same accessibility information the click read used
//   (AXText.Read): each paragraph's elements and their positions on screen.
// - Positions are checked 10 times a second, so the highlight stays put when you scroll.
// - With "Scroll that app to keep up" on, when she moves to a paragraph that's out of view
//   the app is asked to scroll it into view (the same request VoiceOver makes).
// - It shows only while that app is in front, only inside its window, and only while that
//   window is the app's front window: it stays hidden over another window, tab or chat of the
//   same app, and comes back when you return to the page the read started on. A tab switched
//   inside the same window is caught by asking the screen what is at the middle of the
//   highlight (twice a second): it must be the highlighted text or part of it.
// - The highlight is a see-through window that ignores the mouse: clicks go to the app below.
// - Apple Books has no accessibility text, so there the positions come from the screen reader
//   (OCR) instead: BookReader hands over where each paragraph sat when it read the page.
//   The highlight hides when a page turns and comes back once the new page has been read.
//   If the Books window moves or is resized, it hides (the boxes would be in the wrong place);
//   it comes back if the window returns to where it was. Scrolling inside a page isn't noticed.
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
    private var startWindow: CGWindowID?  // the window the click read started in
    var onOffScreen: (Bool) -> Void = { _ in }   // tells the pill: her paragraph is out of view
    private var offScreen = false
    private var followedAt: Date?               // when she moved on; cleared when the box has moved (for the sync log)
    private var followedIndex = 0
    private var flashUntil = Date.distantPast   // set by Find my place: flash the box when it lands
    private var pageCheck: (at: Date, ok: Bool) = (.distantPast, false)
    private var hitCheck: (at: Date, ok: Bool) = (.distantPast, true)

    /// Where a Books paragraph sits on the screen (points, top-left origin): the whole
    /// paragraph, and each list item inside it.
    struct BooksPara { var whole: CGRect; var rows: [CGRect] }
    private struct BooksState {
        var pid: pid_t
        var window: CGWindowID?          // the Books window the read started in
        var paras: [Int: (page: Int, para: BooksPara, window: CGRect)] = [:]   // by the voice's paragraph number
        var pages = 0                    // pages registered so far
        var onScreen = -1                // the page now showing in Books (-1: mid turn, show nothing)
    }
    private var books: BooksState?
    private var now = (paragraph: -1, line: 0)

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
    func begin(_ read: AXText.Read, window: CGWindowID? = nil) {
        end()
        guard !read.paragraphs.isEmpty else { return }
        source = read
        startWindow = window
        recolor()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// A Books read started (or restarted after a jump): forget the old pages.
    func beginBooks(pid: pid_t, window: CGWindowID? = nil) {
        let w = window ?? books?.window ?? ScreenText.frontWindow(of: pid)?.id
        end()
        books = BooksState(pid: pid, window: w)
        recolor()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// Books is about to turn the page: show nothing until the new one has been read.
    func booksTurning() {
        books?.onScreen = -1
        panel.orderOut(nil)
    }

    /// The turn didn't happen (end of the book): the old page is still there.
    func booksStayed() {
        if let b = books { books?.onScreen = b.pages - 1 }
        place()
    }

    /// A page was read and is on screen now. Its paragraphs are the voice's paragraphs
    /// `first`, `first + 1`, ... `window` is where the Books window sat when it was captured.
    func booksPage(_ paras: [BooksPara], first: Int, window: CGRect) {
        guard var b = books else { return }
        for (i, p) in paras.enumerated() { b.paras[first + i] = (b.pages, p, window) }
        b.onScreen = b.pages
        b.pages += 1
        books = b
        place()
    }

    func end() {
        ticker?.invalidate()
        ticker = nil
        source = nil
        books = nil
        startWindow = nil
        hitCheck = (.distantPast, true)
        pageCheck = (.distantPast, false)
        flashUntil = .distantPast
        setOffScreen(false)
        now = (-1, 0)
        current = []
        key = ""
        panel.orderOut(nil)
    }

    var active: Bool { source != nil || books != nil }

    /// She moved on: paragraph `p`, line `line` inside it.
    func follow(paragraph p: Int, line: Int) {
        if books != nil {
            now = (p, line)
            place()
            return
        }
        guard let src = source, Prefs.shared.highlightOnScreen, p >= 0, p < src.paragraphs.count else {
            panel.orderOut(nil); return
        }
        let lines = src.paragraphs[p]
        followedAt = Date(); followedIndex += 1
        // A "no" from the last check was about the old spot: ask again for the new one.
        if !hitCheck.ok { hitCheck.at = .distantPast }
        if !pageCheck.ok { pageCheck.at = .distantPast }
        current = line < lines.count ? lines[line] : lines.flatMap { $0 }   // can't tell the line: the whole paragraph
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
        if books != nil { placeInBooks(); return }
        guard let src = source, Prefs.shared.highlightOnScreen, !current.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == src.pid,
              inStartWindow(src.pid, startWindow),
              let win = windowFrame() else { panel.orderOut(nil); setOffScreen(false); return }
        var area = CGRect.null
        for el in current { if let f = AXText.frame(el), f.width > 1, f.height > 1 { area = area.union(f) } }
        // Out of view (Chrome gives text scrolled away no size at all): hide the box, and offer
        // "Find my place" if the window is still showing the page the read started on.
        let visible = area.isNull ? CGRect.null : area.intersection(win)
        guard !visible.isNull else {
            panel.orderOut(nil)
            setOffScreen(onSamePage(win))
            return
        }
        // Another tab or page in the same window: what's under the highlight isn't our text.
        guard onThisPage(CGPoint(x: visible.midX, y: visible.midY)) else {
            panel.orderOut(nil); setOffScreen(false); return
        }
        setOffScreen(false)
        show(area, inside: win)
        if flashUntil > Date() { flashUntil = .distantPast; flash() }
    }

    private func setOffScreen(_ v: Bool) {
        guard v != offScreen else { return }
        offScreen = v
        onOffScreen(v)
    }

    /// The "Find my place" button: ask the app to scroll her paragraph into view.
    func scrollToPlace() {
        guard let el = current.first else { return }
        AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
        flashUntil = Date().addingTimeInterval(4)
    }

    // One short flash after the page has scrolled: the border brightens and settles (0.4 s).
    private func flash() {
        guard let layer = box.layer else { return }
        let c = NSColor.controlAccentColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = 3.5
        layer.borderColor = c.withAlphaComponent(1).cgColor
        layer.backgroundColor = c.withAlphaComponent(0.30).cgColor
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        layer.borderWidth = 1.5
        layer.borderColor = c.withAlphaComponent(0.55).cgColor
        layer.backgroundColor = c.withAlphaComponent(0.14).cgColor
        CATransaction.commit()
    }

    // Is the window showing the page our text belongs to? Looks at three spots across the
    // window's middle for the page (web area) holding the highlighted text. Twice a second.
    private func onSamePage(_ win: CGRect) -> Bool {
        if Date().timeIntervalSince(pageCheck.at) < 0.4 { return pageCheck.ok }
        var ok = true
        if let el = current.first, let web = AXText.ancestors(el).first(where: { AXText.role($0) == "AXWebArea" }) {
            ok = [0.5, 0.3, 0.7].contains { f in
                var hit: AXUIElement?
                let p = CGPoint(x: win.minX + win.width * f, y: win.midY)
                guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
                      let hit else { return false }
                return AXText.ancestors(hit).prefix(60).contains { CFEqual($0, web) }
            }
        }
        pageCheck = (Date(), ok)
        return ok
    }

    // Is the app's front window the one the read started in? (Unknown start: no check.)
    private func inStartWindow(_ pid: pid_t, _ id: CGWindowID?) -> Bool {
        guard let id else { return true }
        return ScreenText.frontWindow(of: pid)?.id == id
    }

    // Is the highlighted text what's on screen at this point? Asked twice a second, not five times.
    private func onThisPage(_ p: CGPoint) -> Bool {
        if Date().timeIntervalSince(hitCheck.at) < 0.4 { return hitCheck.ok }
        let ok = Self.hitIsRelated(at: p, to: current)
        hitCheck = (Date(), ok)
        return ok
    }

    /// The element on screen at `p` is one of `els`, inside one, or holds one. If the screen
    /// can't say (no answer, or it's our own window), it counts as a yes.
    static func hitIsRelated(at p: CGPoint, to els: [AXUIElement]) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
              let hit else { return true }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        // Inside one: walk up from what's there.
        if AXText.ancestors(hit).prefix(40).contains(where: { a in els.contains { CFEqual($0, a) } }) { return true }
        // Holds one: walk up from the highlighted text.
        for el in els where AXText.ancestors(el).prefix(40).contains(where: { CFEqual($0, hit) }) { return true }
        return false
    }

    // Books: the paragraph she's on, if its page is the one showing and the window hasn't moved.
    private func placeInBooks() {
        guard let b = books, Prefs.shared.highlightOnScreen, let e = b.paras[now.paragraph], e.page == b.onScreen,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == b.pid,
              inStartWindow(b.pid, b.window),
              let win = ScreenText.frontWindow(of: b.pid)?.frame,
              abs(win.minX - e.window.minX) < 2, abs(win.minY - e.window.minY) < 2,
              abs(win.width - e.window.width) < 2, abs(win.height - e.window.height) < 2 else {
            panel.orderOut(nil); return
        }
        show(now.line < e.para.rows.count ? e.para.rows[now.line] : e.para.whole, inside: win)
    }

    // For measuring: how long after she moved on the box was put on the new spot. Times only.
    private func logMoved() {
        guard let t = followedAt else { return }
        followedAt = nil
        Log.write("sync: box on line \(followedIndex) \(Int(Date().timeIntervalSince(t) * 1000)) ms after she moved on")
    }

    // Put the panel over `area` (screen points, top-left origin), clipped to the window.
    private func show(_ rect: CGRect, inside win: CGRect) {
        let area = rect.insetBy(dx: -6, dy: -2).intersection(win)
        guard !area.isNull, area.height > 6 else { panel.orderOut(nil); return }
        // Accessibility measures from the top-left of the main screen; windows from the bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height)
        if panel.isVisible && panel.frame.integral == frame.integral { logMoved(); return }
        logMoved()
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }
}
