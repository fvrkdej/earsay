// BookReader: hands-free reading in Apple Books.
//
// Store-bought books are locked, so we read them the only way possible: off the screen.
// 1. You click a page in Books (with the crosshair). She starts from that sentence.
// 2. When the voice has everything on this page queued (it runs up to 30 s ahead), we
//    press the right arrow in Books to turn the page, read the new page, and hand it on.
//    So there's no gap at a page turn.
// 3. If the page didn't change after a turn, that's the end of the book (or Books
//    stopped listening): she finishes what she has and stops.
// We capture only the Books window, so other windows on top don't get in the way.
import AppKit
import ReadAloudCore

@MainActor
final class BookReader {
    static let booksBundleID = "com.apple.iBooksX"

    private let speaker: Speaker
    private(set) var active = false
    private var windowID: CGWindowID = 0
    private var pid: pid_t = 0
    private var pageShown = 0                    // pages turned since you clicked (0 = the clicked page)
    private var pageStarts: [(sentence: Int, page: Int)] = []
    private var lastPage = ""                    // text of the page on screen, to spot "didn't turn"
    private var token = 0                        // bumps on stop and on page jumps; late work is dropped
    private var turning = false
    // The end of a page is often the middle of a sentence. That unfinished part is held back
    // and joined to the start of the next page, so her voice doesn't drop as if it ended.
    private var carry = ""

    /// Short messages for the pill while she's busy flipping ("Finding the next chapter...").
    var onStatus: ((String) -> Void)?

    init(speaker: Speaker) { self.speaker = speaker }

    /// Is this window a Books window?
    static func isBooks(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == booksBundleID
    }

    /// Start: read the page you clicked, from the clicked sentence.
    /// Read the page on screen (whole page) without starting anything.
    func peek(window: CGWindowID) async -> String? {
        windowID = window
        guard let (lines, _, _) = await readPage() else { return nil }
        let text = OCRLayout.text(from: lines)
        return text.isEmpty ? nil : text
    }

    /// Start at the clicked sentence, or with no click at the top of the page.
    func begin(window: CGWindowID, pid: pid_t, click: CGPoint?) async {
        end()
        token += 1
        let my = token
        windowID = window
        self.pid = pid
        active = true
        pageShown = 0
        guard let (lines, frame, scale) = await readPage(), my == token else { return }
        var start: String?
        if let click {
            start = OCRLayout.text(from: lines, startingAt: (click.x - frame.minX) * scale, (click.y - frame.minY) * scale)
        } else {
            start = OCRLayout.text(from: lines)
        }
        guard let text = start, !text.isEmpty else {
            Log.write("book: no text on the clicked page"); active = false; return
        }
        lastPage = OCRLayout.text(from: lines)
        pageStarts = [(0, 0)]
        carry = ""
        Log.write("book: started, \(lines.count) lines on the first page")
        speaker.onNeedMore = { [weak self] in self?.turnAndAppend() }
        speaker.speak(hold(text), more: true)
    }

    func end() {
        token += 1
        active = false
        turning = false
        speaker.onNeedMore = nil
        speaker.expectingMore = false
        carry = ""
    }

    // Send everything up to the last finished sentence; keep the unfinished end for the next page.
    // Only the page's last paragraph can carry over, and only if it's real prose (8+ words,
    // no end mark). Headings, list lines and contents pages are never held back (16 Nov: a
    // contents page got glued onto the next page and read as one run-on sentence).
    private func hold(_ pageText: String) -> String {
        let full = (carry.isEmpty ? pageText : carry + " " + pageText).trimmingCharacters(in: .whitespacesAndNewlines)
        carry = ""
        var paras = full.components(separatedBy: "\n\n")
        guard let last = paras.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else { return full }
        let endsDone = last.range(of: #"[.!?…]["”’')\]]*$"#, options: .regularExpression) != nil
        guard !endsDone, last.split(separator: " ").count >= 8 else { return full }
        // Keep what's finished in that paragraph; carry the unfinished end.
        if let end = last.range(of: #"[.!?…]["”’')\]]*(?=\s)"#, options: [.regularExpression, .backwards]) {
            carry = last[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            paras[paras.count - 1] = String(last[..<end.upperBound])
        } else {
            carry = last
            paras.removeLast()
        }
        let out = paras.joined(separator: "\n\n")
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { carry = ""; return full }
        return out
    }

    /// The page you're hearing now, counted from the clicked page.
    var pageHeard: Int {
        let i = speaker.playingIndex
        return pageStarts.last { $0.sentence <= i }?.page ?? 0
    }

    // The voice has queued everything we gave it: turn the page and add the next one.
    private func turnAndAppend() {
        guard active, !turning else { return }
        turning = true
        let my = token
        Task { @MainActor in
            defer { if my == token { turning = false } }
            // Keep the page on screen until she's nearly finished reading it.
            while speaker.secondsAhead > 5 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard my == token else { return }
            }
            for attempt in 1...2 {
                press(right: true)
                try? await Task.sleep(nanoseconds: attempt == 1 ? 900_000_000 : 1_500_000_000)
                guard my == token else { return }
                guard let (lines, _, _) = await readPage(), my == token else { return }
                let text = OCRLayout.text(from: lines)
                if text != lastPage && !text.isEmpty {
                    pageShown += 1
                    lastPage = text
                    pageStarts.append((speaker.sentenceCount, pageShown))
                    Log.write("book: turned to page \(pageShown + 1), \(lines.count) lines")
                    speaker.append(hold(text))
                    return
                }
                Log.write("book: page didn't change after turn \(attempt)")
            }
            Log.write("book: end of the book, or Books didn't turn; finishing")
            if !carry.isEmpty { speaker.append(carry); carry = "" }
            speaker.expectingMore = false
        }
    }

    /// Jump to the page before or after the one you're hearing.
    func jumpPage(by step: Int) {
        guard active else { return }
        let target = max(0, pageHeard + step)
        token += 1
        let my = token
        turning = true
        speaker.stop()
        Task { @MainActor in
            defer { if my == token { turning = false } }
            let presses = target - pageShown
            for _ in 0..<abs(presses) {
                press(right: presses > 0)
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard my == token, let (lines, _, _) = await readPage(), my == token else { return }
            pageShown = target
            lastPage = OCRLayout.text(from: lines)
            pageStarts = [(0, target)]
            carry = ""
            Log.write("book: jumped to page \(target + 1)")
            speaker.onNeedMore = { [weak self] in self?.turnAndAppend() }
            speaker.speak(hold(lastPage), more: true)
        }
    }

    /// Flip forward (+1) or back (-1) to the next page that starts a chapter, then read it.
    /// Back from inside a chapter finds the start of that chapter first.
    func jumpChapter(by step: Int) {
        guard active else { return }
        token += 1
        let my = token
        turning = true
        speaker.stop()
        onStatus?(step > 0 ? "Finding the next chapter..." : "Finding the chapter start...")
        Task { @MainActor in
            defer { if my == token { turning = false } }
            // First bring the screen back to the page you were hearing.
            var page = pageHeard
            for _ in 0..<abs(page - pageShown) {
                press(right: page > pageShown)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            pageShown = page
            var previous = ""
            var found: [OCRLine]? = nil
            for _ in 0..<120 {                                   // never flip more than 120 pages
                press(right: step > 0)
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard my == token, let (lines, _, _) = await readPage(), my == token else { return }
                page += step > 0 ? 1 : -1
                let text = OCRLayout.text(from: lines)
                if text == previous { break }                    // start or end of the book
                previous = text
                if Self.startsChapter(lines) { found = lines; break }
            }
            pageShown = page
            var landed = found
            if landed == nil { landed = await readPage()?.0 }
            guard let lines = landed, my == token else { return }
            lastPage = OCRLayout.text(from: lines)
            pageStarts = [(0, page)]
            carry = ""
            Log.write("book: chapter jump landed \(page) pages from the start page" + (found == nil ? " (no heading found)" : ""))
            speaker.onNeedMore = { [weak self] in self?.turnAndAppend() }
            speaker.speak(hold(lastPage), more: true)
        }
    }

    // A chapter's first page: a line starting "Chapter"/"Part" near the top, or a heading
    // much bigger than the body text in the top half of the page.
    static func startsChapter(_ lines: [OCRLine]) -> Bool {
        guard !lines.isEmpty else { return false }
        let heights = lines.map(\.h).sorted()
        let body = heights[heights.count / 2]
        let pageBottom = lines.map { $0.y + $0.h }.max() ?? 1
        let pageTop = lines.map(\.y).min() ?? 0
        let upper = lines.filter { $0.y < pageTop + 0.45 * (pageBottom - pageTop) }
        return upper.contains { l in
            l.text.range(of: #"^(chapter|part)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                || l.h > 1.6 * body
        }
    }

    // MARK: - Reading and turning

    // Capture the Books window and read its lines, minus the title bar and the page number.
    private func readPage() async -> ([OCRLine], CGRect, CGFloat)? {
        // The text reader and the voice share the Mac's AI chip; now and then a read fails
        // because the chip was busy. Try up to three times.
        for attempt in 1...3 {
            if let page = await readPageOnce(attempt: attempt) { return page }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    private func readPageOnce(attempt: Int) async -> ([OCRLine], CGRect, CGFloat)? {
        do {
            let (image, frame, scale) = try await ScreenText.capture(window: windowID)
            let all = try await Task.detached(priority: .userInitiated) { try ScreenOCR.lines(in: image) }.value
            let h = Double(image.height)
            let lines = all.filter { l in
                let short = l.text.split(separator: " ").count < 8
                let inTitleBar = l.y < 0.08 * h
                let atFoot = l.y > 0.92 * h
                return !(short && (inTitleBar || atFoot))
            }
            return (lines, frame, scale)
        } catch {
            Log.write("book: couldn't read the Books window (try \(attempt)): \(error)")
            return nil
        }
    }

    // Press the arrow key in Books, without bringing Books to the front.
    private func press(right: Bool) {
        BooksControl.turn(right: right, pid: pid)
    }
}
