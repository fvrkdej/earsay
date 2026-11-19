// OCR: turn a picture of the screen into text in reading order.
//
// Apple's Vision framework (the same text reader Photos and Live Text use) finds
// each line of text and where it sits. It runs on this Mac, offline.
// We then rebuild paragraphs: lines that sit close under each other, start at the
// same left edge and have the same size belong together; a gap, a jump sideways
// or a size change starts a new block (a heading, a sidebar, the next paragraph).
import CoreGraphics
import Foundation
import Vision

/// One line found on screen. Position in pixels, top-left origin.
public struct OCRLine {
    public var text: String
    public var x: Double, y: Double, w: Double, h: Double
    public init(text: String, x: Double, y: Double, w: Double, h: Double) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// One paragraph as she speaks it: its text, and the lines it came from. `rows` splits the
/// lines at each list item, the same way `join` puts a new line before each item, so
/// "line 2 of this paragraph" means the same thing here as it does to the voice.
public struct OCRParagraph {
    public var text: String
    public var lines: [OCRLine]
    public var rows: [[OCRLine]]
}

public enum ScreenOCR {
    /// Every line of text Vision finds in the image.
    public static func lines(in image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let W = Double(image.width), H = Double(image.height)
        return (request.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence > 0.3 else { return nil }
            let b = o.boundingBox          // 0...1, bottom-left origin
            return OCRLine(text: c.string, x: b.minX * W, y: (1 - b.maxY) * H, w: b.width * W, h: b.height * H)
        }
    }
}

public enum OCRLayout {
    struct Block {
        var lines: [OCRLine]
        var minX: Double, maxX: Double, minY: Double, maxY: Double
        init(_ l: OCRLine) { lines = [l]; minX = l.x; maxX = l.x + l.w; minY = l.y; maxY = l.y + l.h }
        mutating func add(_ l: OCRLine) {
            lines.append(l); minX = min(minX, l.x); maxX = max(maxX, l.x + l.w); maxY = max(maxY, l.y + l.h)
        }
        func overlapsX(_ o: Block) -> Bool {
            let overlap = min(maxX, o.maxX) - max(minX, o.minX)
            return overlap > 0.3 * min(maxX - minX, o.maxX - o.minX)
        }
    }

    static func blocks(_ input: [OCRLine]) -> [Block] {
        var blocks: [Block] = []
        // A normal line's height on this screen (Vision's heights jump about, so use the middle one).
        let heights = input.map(\.h).sorted()
        let body = heights.isEmpty ? 0 : heights[heights.count / 2]
        for l in input.sorted(by: { $0.y < $1.y }) {
            let fits = blocks.lastIndex { b in
                let last = b.lines.last!
                let size = max(l.h, last.h)
                let gap = l.y - (last.y + last.h)
                return gap > -0.5 * size && gap < 0.75 * body          // right under the last line
                    && abs(l.h - last.h) < 0.4 * size                  // not a heading's size jump
                    && abs(l.x - b.minX) < 2.0 * size                  // same left edge (small indent ok)
                    && min(l.x + l.w, b.maxX) - max(l.x, b.minX) > 0   // same column
            }
            if let i = fits { blocks[i].add(l) } else { blocks.append(Block(l)) }
        }
        // Reading order: top to bottom; blocks starting on the same line go left to right.
        return blocks.sorted { a, b in
            let size = a.lines[0].h
            return abs(a.minY - b.minY) < 0.5 * size ? a.minX < b.minX : a.minY < b.minY
        }
    }

    // Lines of one block back into one paragraph. A word split with a hyphen at the
    // end of a line ("concen-" + "trate") is put back together.
    // A list item ("• ...", "1. ...") starts its own line, so each item is read on its own
    // with a short pause (16 Nov: a bullet list was read as one breathless sentence).
    static func join(_ lines: [OCRLine]) -> String {
        var out = ""
        for l in lines {
            let t = fixMisreads(l.text.trimmingCharacters(in: .whitespaces))
            let isItem = isListItem(t)
            if out.hasSuffix("-"), let f = t.first, f.isLowercase {
                out.removeLast(); out += t
            } else if isItem && !out.isEmpty {
                out += "\n" + t
            } else {
                out += out.isEmpty ? t : " " + t
            }
        }
        return out
    }

    // In plain fonts a capital I and a small l look the same, so "AI" comes back as "Al".
    // Keep "Al" only when a name follows ("Al Pacino").
    static func fixMisreads(_ t: String) -> String {
        t.replacingOccurrences(of: #"\bAl\b(?!\.?\s+[A-Z])"#, with: "AI", options: .regularExpression)
    }

    /// Everything found, as paragraphs separated by blank lines.
    /// Side-by-side columns are read one after the other, left to right.
    public static func text(from lines: [OCRLine]) -> String {
        paragraphs(from: lines).map(\.text).joined(separator: "\n\n")
    }

    /// The same paragraphs `text(from:)` speaks, in the same order, with their lines kept
    /// so the app can show where each one sits on the page.
    public static func paragraphs(from lines: [OCRLine]) -> [OCRParagraph] {
        var columns: [[Block]] = []
        for b in blocks(lines) {
            if let i = columns.firstIndex(where: { $0.contains { $0.overlapsX(b) } }) { columns[i].append(b) }
            else { columns.append([b]) }
        }
        return columns
            .sorted { ($0.map(\.minX).min() ?? 0) < ($1.map(\.minX).min() ?? 0) }
            .flatMap { $0 }
            .map(paragraph)
    }

    static func paragraph(_ b: Block) -> OCRParagraph {
        OCRParagraph(text: join(b.lines), lines: b.lines, rows: rows(b.lines))
    }

    static func isListItem(_ t: String) -> Bool {
        t.range(of: #"^([•◦○●▪‣*-]|\d{1,3}[.)])\s"#, options: .regularExpression) != nil
    }

    // Lines of one block grouped by what the voice treats as a line: a new one at each list item.
    static func rows(_ lines: [OCRLine]) -> [[OCRLine]] {
        var out: [[OCRLine]] = []
        for l in lines {
            let t = fixMisreads(l.text.trimmingCharacters(in: .whitespaces))
            if isListItem(t) && !out.isEmpty { out.append([l]) }
            else if out.isEmpty { out = [[l]] }
            else { out[out.count - 1].append(l) }
        }
        return out
    }

    /// Where lines sit on the screen. `frame` is the captured area in screen points
    /// (top-left origin), `scale` the pixels per point the picture was taken at.
    public static func screenRect(of lines: [OCRLine], frame: CGRect, scale: CGFloat) -> CGRect {
        var r = CGRect.null
        for l in lines {
            r = r.union(CGRect(x: l.x, y: l.y, width: l.w, height: l.h))
        }
        guard !r.isNull else { return .null }
        return CGRect(x: frame.minX + r.minX / scale, y: frame.minY + r.minY / scale,
                      width: r.width / scale, height: r.height / scale)
    }

    /// Read from the clicked line on: the rest of its paragraph, then every block
    /// below it in the same column (so sidebars and menus beside it are left out).
    public static func text(from lines: [OCRLine], startingAt px: Double, _ py: Double) -> String? {
        paragraphs(from: lines, startingAt: px, py)?.map(\.text).joined(separator: "\n\n")
    }

    /// The paragraphs behind `text(from:startingAt:_:)`. The first one's text starts at the
    /// clicked sentence, but its lines are the whole block (the highlight covers it all).
    public static func paragraphs(from lines: [OCRLine], startingAt px: Double, _ py: Double) -> [OCRParagraph]? {
        let all = blocks(lines)
        guard !all.isEmpty else { return nil }
        func distance(_ b: Block) -> Double {
            let dx = px < b.minX ? b.minX - px : (px > b.maxX ? px - b.maxX : 0)
            let dy = py < b.minY ? b.minY - py : (py > b.maxY ? py - b.maxY : 0)
            return dx * 3 + dy        // prefer the block in the clicked column
        }
        let start = all.min { distance($0) < distance($1) }!
        // In the clicked block, start at the clicked line (or the first line below the click).
        // Start at the beginning of the sentence the click landed in.
        var opening = join(start.lines)
        if let i = start.lines.firstIndex(where: { $0.y + $0.h >= py }), i > 0 {
            let before = join(Array(start.lines[..<i]))
            if let end = before.range(of: #"[.!?]["”')]?\s"#, options: [.regularExpression, .backwards]) {
                opening = String(opening[end.upperBound...])
            }
        }
        var first = paragraph(start)
        first.text = opening
        var parts = [first]
        for b in all where b.minY > start.minY && b.overlapsX(start) {
            parts.append(paragraph(b))
        }
        return parts
    }
}
