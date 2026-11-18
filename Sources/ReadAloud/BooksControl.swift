// BooksControl: turn a page in Apple Books without bringing it to the front.
//
// First choice: press Books' own next / previous page button through the accessibility
// system (the same way VoiceOver presses buttons). That works while you're in another app.
// If the button can't be found, send the arrow key to Books directly.
import AppKit
import ApplicationServices
import ReadAloudCore

@MainActor
enum BooksControl {
    private static var buttons: [String: AXUIElement] = [:]      // "pid-next" / "pid-prev"

    static func turn(right: Bool, pid: pid_t) {
        let key = "\(pid)-\(right ? "next" : "prev")"
        if buttons[key] == nil, let b = findButton(right: right, pid: pid) { buttons[key] = b }
        if let b = buttons[key], AXUIElementPerformAction(b, kAXPressAction as CFString) == .success { return }
        buttons[key] = nil
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: right ? 124 : 123, keyDown: down)?.postToPid(pid)
        }
    }

    // Look through Books' window for a button described as next / previous page.
    private static func findButton(right: Bool, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let words = right ? ["next page", "next", "forward"] : ["previous page", "previous", "back"]
        var found: AXUIElement?
        func text(_ e: AXUIElement, _ attr: String) -> String {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, attr as CFString, &v)
            return (v as? String)?.lowercased() ?? ""
        }
        func walk(_ e: AXUIElement, depth: Int) {
            guard found == nil, depth < 12 else { return }
            if text(e, kAXRoleAttribute) == "axbutton" {
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, "AXIdentifier"]
                    .map { text(e, $0) }.joined(separator: " ")
                if words.contains(where: { label.contains($0) }) { found = e; return }
            }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
            for k in (kids as? [AXUIElement]) ?? [] { walk(k, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for w in (windows as? [AXUIElement]) ?? [] { walk(w, depth: 0) }
        if found != nil { Log.write("books: using Books' own \(right ? "next" : "previous") page button") }
        return found
    }
}

/// While reading one of your files that's open in Books, keep Books on the page she's reading.
@MainActor
final class BooksSync {
    private(set) var active = false
    private var windowID: CGWindowID = 0
    private var pid: pid_t = 0
    private var path = ""
    private var visible = (start: 0, end: 0)          // letters of the file on screen
    private var busy = false
    private var paraCache: [Int: (offset: Int, length: Int)] = [:]
    private var lastTarget = 0

    func begin(window: CGWindowID, pid: pid_t, path: String, pageText: String) {
        self.windowID = window; self.pid = pid; self.path = path
        paraCache = [:]
        busy = false
        if let v = BookMatcher.locate(pageText: pageText, in: path) { visible = v; lastTarget = v.start; active = true }
        Log.write(active ? "books: following along in Books" : "books: couldn't place the page, not following")
    }

    func end() { active = false; busy = false }

    /// Called on every new sentence: turn Books' page if she's read past what's on screen.
    func follow(paragraph: String, paragraphID: Int, fraction: Double) {
        guard active, !busy else { return }
        let place = paraCache[paragraphID] ?? BookMatcher.letterOffset(of: paragraph, in: path, near: lastTarget)
        guard let place else { return }
        paraCache[paragraphID] = place
        let target = place.offset + Int(Double(place.length) * fraction)
        lastTarget = target
        if target >= visible.start - 40 && target < visible.end - 20 { return }   // still on screen
        busy = true
        Task { @MainActor in
            defer { busy = false }
            for _ in 0..<5 {
                guard active else { return }
                let span = max(400, visible.end - visible.start)
                let forward = target >= visible.end - 20
                let gap = forward ? target - visible.end : visible.start - target
                let presses = min(40, max(1, gap / span + 1))
                for _ in 0..<presses {
                    BooksControl.turn(right: forward, pid: pid)
                    try? await Task.sleep(nanoseconds: presses > 1 ? 180_000_000 : 50_000_000)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let page = await readPage(), let v = BookMatcher.locate(pageText: page, in: path) else {
                    Log.write("books: couldn't read Books after turning"); return
                }
                let moved = v.start != visible.start
                visible = v
                if !moved { Log.write("books: Books didn't turn the page"); return }
                if target >= visible.start - 40 && target < visible.end - 20 { return }
            }
        }
    }

    private func readPage() async -> String? {
        do {
            let (image, _, _) = try await ScreenText.capture(window: windowID)
            let lines = try await Task.detached(priority: .userInitiated) { try ScreenOCR.lines(in: image) }.value
            return OCRLayout.text(from: lines)
        } catch { return nil }
    }
}
