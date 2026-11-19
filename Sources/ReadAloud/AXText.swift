// AXText: read an app's text through Accessibility (the same information VoiceOver uses)
// instead of off the pixels. It sees text scrolled out of view, and knows a button from a
// paragraph, so app controls ("Bypass permissions") aren't read out.
import AppKit
import ApplicationServices
import ReadAloudCore

enum AXText {
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    static func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
    static func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "" }
    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Chromium and Electron apps (VS Code, Chrome, Slack, Claude) only build their text tree
    /// once asked. Ask, then give them a moment.
    static func wake(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - Read from a click

    /// The text from the clicked paragraph to the end of the piece it belongs to (one chat
    /// reply, one article, one document), or nil if the app gives no usable text.
    /// `point` is in screen coordinates measured from the top-left.
    static func text(at point: CGPoint, pid: pid_t) -> String? { read(at: point, pid: pid)?.text }

    /// What a click reads, plus where each paragraph and line sits in the app, so the
    /// highlight can follow her. `paragraphs[p]` = the elements of paragraph p, one per line.
    struct Read {
        let text: String
        let paragraphs: [[[AXUIElement]]]     // by paragraph, by spoken line: the elements making that line
        let pid: pid_t
        var start: Start? = nil
    }

    /// Where the read starts. `trusted`: it was confirmed (the block sits under the click and
    /// shares words with the screen, or the screen's own line pointed at it). `moved`: the
    /// screen's line chose a different block than the geometry did. `words`: how many
    /// distinctive words the screen gave. Never holds text.
    struct Start { let trusted: Bool; let moved: Bool; let hintWords: Int }

    // Words too common to tell one paragraph from another.
    static let stopwords: Set<String> = ["the", "and", "you", "for", "that", "this", "with", "are", "was",
        "were", "not", "but", "your", "from", "have", "has", "had", "can", "will", "all", "its", "it's",
        "they", "them", "then", "than", "there", "what", "when", "which", "who", "how", "why", "out",
        "any", "one", "get", "got", "just", "into", "about", "also", "more", "some", "would", "could",
        "should", "been", "being", "our", "his", "her", "she", "him", "their", "these", "those", "does",
        "did", "don't", "isn't", "very", "too", "only", "over", "such", "each", "other", "here"]

    /// Distinctive words of a line of text: lower case, 3+ letters, no common words.
    static func distinctiveWords(_ t: String) -> Set<String> {
        Set(t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    static func read(at point: CGPoint, pid: pid_t, hint: Set<String> = [], legacy: Bool = false) -> Read? {
        let app = AXUIElementCreateApplication(pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        return read(from: hit, point: point, pid: pid, hint: hint, legacy: legacy)
    }

    static func text(from hit: AXUIElement, point: CGPoint) -> String? { read(from: hit, point: point, pid: 0)?.text }

    /// `hint`: the distinctive words of the line the screen shows nearest the click (empty: unknown).
    static func read(from hit: AXUIElement, point: CGPoint, pid: pid_t, hint: Set<String> = [], legacy: Bool = false) -> Read? {
        // A native text view (Notes, TextEdit, Mail): read its text from the clicked paragraph.
        // (No highlight there: the whole text is one element.)
        if let native = nativeText(hit, point) { return Read(text: native, paragraphs: [], pid: pid) }

        // Web-style content (Chromium, Electron, Safari): find the piece, then its blocks.
        let path = ancestors(hit)
        guard let root = readingRoot(path) else { return nil }
        var blocks: [(el: AXUIElement, text: String, list: Bool)] = []
        collect(root, inList: false, into: &blocks)
        guard !blocks.isEmpty else { return nil }
        // Where to start. Two candidates from where things are:
        //  - the block on the click's own path (the clicked element, or the nearest ancestor that
        //    is a block), which the app really put under the click;
        //  - the smallest block whose frame holds the click (a container with a stray word of
        //    its own is bigger than the paragraph in it). Chrome gives text scrolled out of view
        //    a made-up frame near the top, so this one is never taken on geometry alone.
        // Failing both: the block on the click's row (a click in the margin), else the nearest
        // block starting just below. Then the screen decides, see below.
        func f(_ i: Int) -> CGRect? {
            guard let r = frame(blocks[i].el), r.width > 1, r.height > 1 else { return nil }
            return r
        }
        func holds(_ i: Int, slack: CGFloat) -> Bool {      // the click is in the block's row (and column, give or take `slack`)
            guard let r = f(i) else { return false }
            return point.y >= r.minY - 4 && point.y <= r.maxY + 4 && point.x >= r.minX - slack && point.x <= r.maxX + slack
        }
        var pathBlock: Int?
        for el in path { if let i = blocks.firstIndex(where: { CFEqual($0.el, el) }) { pathBlock = i; break } }
        let pathExact = pathBlock.map { holds($0, slack: 40) } ?? false
        var small: Int?
        var bestArea = CGFloat.infinity
        for i in blocks.indices where holds(i, slack: 4) {
            let r = f(i)!
            if r.width * r.height < bestArea { small = i; bestArea = r.width * r.height }
        }
        var other: Int?                                      // not on the click: its row, or just below
        if pathBlock == nil && small == nil {
            other = blocks.indices.filter { holds($0, slack: 80) }
                .min { abs(f($0)!.midX - point.x) < abs(f($1)!.midX - point.x) }
            if other == nil {
                var nearest = CGFloat.infinity
                for i in blocks.indices {
                    guard let r = f(i), r.minY >= point.y - 4, r.minY - point.y < 120, r.minY < nearest else { continue }
                    other = i; nearest = r.minY
                }
            }
        }
        // The screen: the block whose words best hold the line the screen shows at the click.
        func score(_ i: Int) -> Int { distinctiveWords(blocks[i].text).intersection(hint).count }
        var screen: Int?
        if hint.count >= 3 {
            var top = 0
            for i in blocks.indices {
                let sc = score(i)
                let closer: Bool = {
                    guard sc == top, let b = screen, let r = f(i) else { return false }
                    guard let rb = f(b) else { return true }
                    return abs(r.midY - point.y) < abs(rb.midY - point.y)
                }()
                if sc > top || closer { top = sc; screen = i }
            }
            if let b = screen, !(score(b) >= 3 && Double(score(b)) >= 0.6 * Double(hint.count)) { screen = nil }
        }
        let newIndex: Int
        let trusted: Bool
        var moved = false
        let first = pathBlock ?? small ?? other ?? 0
        if hint.count >= 3 {
            // The smallest block on the click that shares words with the screen's line, then the
            // path's block; else the screen's own best match.
            if let s = small, score(s) >= 2 { newIndex = s; trusted = true }
            else if let p = pathBlock, pathExact || f(p) == nil, score(p) >= 2 { newIndex = p; trusted = true }
            else if let b = screen { newIndex = b; trusted = true; moved = b != first }
            else { newIndex = first; trusted = false }
        } else {
            // Nothing on screen to check against: trust only a block that sits on the click.
            newIndex = first
            trusted = pathBlock != nil ? pathExact : small != nil
        }
        // Debug only (axtest): the way the start was picked before 19 Nov, for before and after.
        let startIndex = legacy
            ? (blocks.firstIndex { b in path.contains { CFEqual($0, b.el) } }
                ?? blocks.firstIndex { (frame($0.el)?.maxY ?? 0) >= point.y } ?? 0)
            : newIndex
        let start = Start(trusted: trusted, moved: moved, hintWords: hint.count)
        // List items and table rows next to each other form one paragraph, a line each.
        var paras: [(lines: [String], els: [AXUIElement])] = []
        var prevList = false
        for b in blocks[startIndex...] {
            if b.list && prevList, !paras.isEmpty {
                paras[paras.count - 1].lines.append(b.text)
                paras[paras.count - 1].els.append(b.el)
            } else {
                paras.append(([b.text], [b.el]))
            }
            prevList = b.list
        }
        let out = paras.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n\n")
        let words = out.split(whereSeparator: \.isWhitespace).count
        guard words >= 3 else { return nil }
        // Line up with how the voice splits the text (TextPrep.lineGroups): lines with no words
        // are dropped, and a one-word line ("Audio:") is spoken with the next one, so its
        // element joins that line's. Without this the box lags a line behind after every
        // such line (a parent bullet with a nested list).
        let kept: [[[AXUIElement]]] = paras.compactMap { p in
            var elOfLine: [Int] = []                       // the text's own lines, by element
            for (ei, t) in p.lines.enumerated() { elOfLine += Array(repeating: ei, count: t.components(separatedBy: "\n").count) }
            let groups = TextPrep.lineGroups(p.lines.joined(separator: "\n")).map { g -> [AXUIElement] in
                var seen: [Int] = []
                for l in g where l < elOfLine.count && !seen.contains(elOfLine[l]) { seen.append(elOfLine[l]) }
                return seen.map { p.els[$0] }
            }
            return groups.isEmpty ? nil : groups
        }
        return Read(text: out, paragraphs: kept, pid: pid, start: start)
    }

    static func ancestors(_ e: AXUIElement) -> [AXUIElement] {
        var out = [e]
        var cur = e
        while out.count < 80, let p = attr(cur, kAXParentAttribute) {
            let parent = p as! AXUIElement
            out.append(parent)
            cur = parent
        }
        return out
    }

    // The piece to read: a chat message or article first, then the page's main area,
    // then the whole web page.
    static func readingRoot(_ path: [AXUIElement]) -> AXUIElement? {
        func sub(_ e: AXUIElement) -> String { str(e, kAXSubroleAttribute) ?? "" }
        if let a = path.first(where: { sub($0) == "AXDocumentArticle" }) { return a }
        if let m = path.first(where: { sub($0) == "AXLandmarkMain" }) { return m }
        return path.first { role($0) == "AXWebArea" }
    }

    static let skipRoles: Set<String> = [
        "AXButton", "AXTextArea", "AXTextField", "AXComboBox", "AXPopUpButton", "AXMenuButton",
        "AXImage", "AXCheckBox", "AXRadioButton", "AXSlider", "AXMenu", "AXMenuBar", "AXToolbar",
        "AXTabGroup", "AXScrollBar",
    ]
    static let skipSubroles: Set<String> = [
        "AXTimeGroup", "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo",
        "AXLandmarkComplementary", "AXLandmarkSearch", "AXApplicationStatus", "AXApplicationAlert",
    ]

    // Walk the tree in reading order. A block is anything holding text directly (a paragraph,
    // a heading, a list item); bold or linked words inside it stay part of it.
    static func collect(_ e: AXUIElement, inList: Bool, into blocks: inout [(el: AXUIElement, text: String, list: Bool)]) {
        let r = role(e)
        if skipRoles.contains(r) || skipSubroles.contains(str(e, kAXSubroleAttribute) ?? "") { return }
        let kids = children(e)
        // A table: one line per row, cells in order with a comma between. The header row
        // ("Dish, Price, Vegetarian?") is read once, so you know what the columns are; it can
        // sit inside its own group. The Mac also lists the same cells by column: left out.
        // (17 Nov: a rule that skipped the first row dropped a real row when the header
        // lived in its own group.)
        if r == "AXTable" || r == "AXGrid" {
            var rows: [AXUIElement] = []
            for k in kids {
                let kr = role(k)
                if kr == "AXRow" { rows.append(k) }
                else if kr == "AXGroup" { rows += children(k).filter { role($0) == "AXRow" } }
            }
            for row in rows {
                let cells = children(row).map { words($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                add(row, cells.joined(separator: ", "), true, &blocks)
            }
            return
        }
        // A paragraph is an element made only of words (text, bold, links, a list number).
        // A container that mixes loose words with sections: the loose words are their own
        // paragraph, the sections are walked (16 Nov: a Chrome form page came out as one
        // run-on paragraph, "one check.2. Criteria...").
        if r == "AXStaticText" || (!kids.isEmpty && kids.allSatisfy(isInline)) {
            add(e, inline(e), inList, &blocks)
            return
        }
        let list = inList || r == "AXList"
        var loose: [AXUIElement] = []
        func flush() {
            guard !loose.isEmpty else { return }
            add(loose[0], loose.map(inline).joined(), list, &blocks)
            loose = []
        }
        for k in kids {
            if isInline(k) { loose.append(k) } else { flush(); collect(k, inList: list, into: &blocks) }
        }
        flush()
    }

    static func add(_ e: AXUIElement, _ text: String, _ list: Bool,
                    _ blocks: inout [(el: AXUIElement, text: String, list: Bool)]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Pages often carry a second copy of a table (for phones, or for screen readers):
        // a longer paragraph already read once is skipped. Chrome gives anything scrolled
        // out of view no size, so size can't be used to spot hidden copies.
        if t.split(separator: " ").count >= 6, blocks.contains(where: { $0.text == t }) { return }
        blocks.append((e, t, list))
    }

    // Every word inside an element (a table cell), paragraphs joined by a space.
    static func words(_ e: AXUIElement) -> String {
        let r = role(e)
        if skipRoles.contains(r) { return "" }
        if r == "AXStaticText" { return (attr(e, kAXValueAttribute) as? String) ?? "" }
        let kids = children(e)
        if !kids.isEmpty, kids.allSatisfy(isInline) { return inline(e) }
        return kids.map(words).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func isInline(_ e: AXUIElement) -> Bool {
        let r = role(e)
        if r == "AXStaticText" || r == "AXListMarker" { return true }
        // A link inside a sentence is part of it; a link that wraps a whole card is not.
        if r == "AXLink" { return children(e).allSatisfy(isInline) }
        return r == "AXGroup" && (str(e, kAXSubroleAttribute) ?? "").hasSuffix("StyleGroup")
    }

    // All the words inside a block, in order, skipping buttons and images.
    static func inline(_ e: AXUIElement) -> String {
        let r = role(e)
        if r == "AXStaticText" || r == "AXListMarker" { return (attr(e, kAXValueAttribute) as? String) ?? "" }
        if skipRoles.contains(r) { return "" }
        return children(e).map(inline).joined()
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    // A plain text view with all its words in one value: start at the clicked paragraph.
    static func nativeText(_ e: AXUIElement, _ point: CGPoint) -> String? {
        let r = role(e)
        guard r == "AXTextArea" || r == "AXTextView",
              let all = attr(e, kAXValueAttribute) as? String, all.count > 40 else { return nil }
        // Chromium marks its own text boxes AXTextArea too (a message input): only trust
        // native views, which answer "which character is at this point".
        var pt = point
        guard let pv = AXValueCreate(.cgPoint, &pt) else { return nil }
        var rangeObj: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(e, "AXRangeForPosition" as CFString, pv, &rangeObj) == .success,
              let rv = rangeObj else { return nil }
        var range = CFRange()
        AXValueGetValue(rv as! AXValue, .cfRange, &range)
        let ns = all as NSString
        let loc = min(max(0, range.location), ns.length)
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        return ns.substring(from: para.location)
    }

    /// Debug: the text element whose words are exactly `phrase`, in the app's front window.
    static func find(pid: pid_t, phrase: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let wins = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var found: AXUIElement?
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard found == nil, depth < 60 else { return }
            if role(e) == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String,
               v == phrase || (phrase.count >= 20 && v.hasPrefix(phrase)) { found = e; return }
            for c in children(e) { walk(c, depth + 1) }
        }
        for w in wins where found == nil { walk(w, 0) }
        return found
    }

    /// Debug: find the first text containing `phrase`, "click" its middle, return what she'd read.
    static func test(pid: pid_t, phrase: String) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let win = attr(app, kAXFocusedWindowAttribute) else { return "no window" }
        var found: AXUIElement?
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard found == nil, depth < 60 else { return }
            if role(e) == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String, v == phrase { found = e; return }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(win as! AXUIElement, 0)
        guard let el = found, let f = frame(el) else { return "phrase not found" }
        let pt = CGPoint(x: f.midX, y: f.midY)
        return "clicked at \(Int(pt.x)),\(Int(pt.y))\n\n" + (text(from: el, point: pt) ?? "(no text at that point)")
    }

    // MARK: - Debug: write the tree of the front window of an app to a local file

    static func dump(bundleID: String, to path: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            Log.write("axdump: app not running"); return
        }
        wake(pid: app.processIdentifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            guard let win = attr(el, kAXFocusedWindowAttribute) ?? (attr(el, kAXWindowsAttribute) as? [AnyObject])?.first else {
                Log.write("axdump: no window"); return
            }
            var out = ""
            var count = 0
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard count < 6000, depth < 60 else { return }
                count += 1
                let r = role(e)
                let sub = str(e, kAXSubroleAttribute) ?? ""
                let v = (attr(e, kAXValueAttribute) as? String) ?? ""
                let t = str(e, kAXTitleAttribute) ?? ""
                let d = str(e, kAXDescriptionAttribute) ?? ""
                var line = String(repeating: " ", count: depth) + r
                if !sub.isEmpty { line += "/" + sub }
                for (k, s) in [("v", v), ("t", t), ("d", d)] where !s.isEmpty {
                    line += " \(k)=\"" + s.prefix(70).replacingOccurrences(of: "\n", with: "⏎") + "\""
                }
                out += line + "\n"
                for c in children(e) { walk(c, depth + 1) }
            }
            walk(win as! AXUIElement, 0)
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
            Log.write("axdump: \(count) elements written")
        }
    }
}
