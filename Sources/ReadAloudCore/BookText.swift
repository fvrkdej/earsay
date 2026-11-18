// BookText: get readable text out of a file. Everything happens in memory; nothing
// is written to disk.
//
// - .txt / .md: read as is. A hard-wrapped text file (every line cut at ~70 letters,
//   like Project Gutenberg books) is joined back into paragraphs first.
// - .pdf: Apple's PDFKit gives the text page by page, one line per printed line, so
//   lines are joined back into paragraphs and page numbers are dropped.
// - .epub: an EPUB is a zip of web pages. We read the book's table of contents to get
//   the chapters in order, take each page straight out of the zip, and strip the HTML.
// - .docx / .rtf / .odt / .doc: macOS's own document reader.
import AppKit
import Foundation
import PDFKit

public enum BookText {
    /// Put between chapters in the text we return; the speaker splits on it to know
    /// where each chapter starts (it is never read out).
    public static let chapterMark = "\u{1E}"
    /// Ends a chapter's name, written straight after the mark: "\u{1E}Chapter 1: Don't Try\u{1F}".
    public static let titleEnd = "\u{1F}"

    static func mark(_ title: String) -> String {
        let clean = title.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\n\n" + chapterMark + clean + titleEnd + "\n\n"
    }

    public static let fileTypes = ["txt", "md", "markdown", "pdf", "epub", "docx", "doc", "rtf", "odt"]

    public static func load(_ url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
            // Chapters: the PDF's own table of contents (top-level entries), if it has one.
            // Many PDFs wrap everything in one top entry (the book's title): look inside it.
            // Chapters inside a "Part" count too.
            var chapterPages: [Int: String] = [:]
            var level = doc.outlineRoot
            while let l = level, l.numberOfChildren == 1, let only = l.child(at: 0), only.numberOfChildren > 0 { level = only }
            if let level {
                for i in 0..<level.numberOfChildren {
                    guard let entry = level.child(at: i) else { continue }
                    if let page = entry.destination?.page { chapterPages[doc.index(for: page)] = entry.label ?? "" }
                    if (entry.label ?? "").range(of: #"^part\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        for j in 0..<entry.numberOfChildren {
                            if let c = entry.child(at: j), let page = c.destination?.page {
                                chapterPages[doc.index(for: page)] = c.label ?? ""
                            }
                        }
                    }
                }
            }
            let pages = (0..<doc.pageCount).map { i -> String in
                let text = doc.page(at: i)?.string ?? ""
                guard let title = chapterPages[i] else { return text }
                return mark(title) + text
            }
            return reflow(pages.joined(separator: "\n"))
        case "epub":
            return try epub(url)
        case "docx", "doc", "rtf", "odt":
            let text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            return markChapterLines(looksHardWrapped(text) ? reflow(text) : text)
        default:
            let text = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")      // Windows line endings
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" { return markHeadings(text) }
            return markChapterLines(looksHardWrapped(text) ? reflow(text) : text)
        }
    }

    // MARK: - Joining printed lines back into paragraphs

    /// Lines of a paragraph are joined; a paragraph ends at a blank line, or at a line that
    /// ends a sentence and stops well short of the usual line length. Page numbers go.
    public static func reflow(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        let typical = lengths.isEmpty ? 60 : Double(lengths[lengths.count * 8 / 10])
        var out = "", para = ""
        func flush() { if !para.isEmpty { out += para + "\n\n"; para = "" } }
        for line in lines {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix(chapterMark) { flush(); out += line + "\n\n"; continue }
            if line.allSatisfy(\.isNumber) { continue }                     // a page number
            if para.hasSuffix("-"), let f = line.first, f.isLowercase {
                para.removeLast(); para += line                              // "concen-" + "trate"
            } else {
                para += para.isEmpty ? line : " " + line
            }
            let short = Double(line.count) < 0.75 * typical
            let endsSentence = line.last.map { ".!?:\"”’)".contains($0) } ?? false
            if (short && endsSentence) || Double(line.count) < 0.45 * typical { flush() }
        }
        flush()
        return out
    }

    /// Most lines between 55 and 80 letters, blank lines between paragraphs.
    static func looksHardWrapped(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 40 else { return false }
        let wrapped = lines.filter { (55...80).contains($0.count) }.count
        return Double(wrapped) / Double(lines.count) > 0.5
    }

    // MARK: - Chapter marks

    // Markdown: top headings start chapters (# if there are 3 or more, otherwise ##).
    static func markHeadings(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let h1 = lines.filter { $0.hasPrefix("# ") }.count
        let prefix = h1 >= 3 ? "# " : "## "
        return lines.map { $0.hasPrefix(prefix) ? mark(String($0.dropFirst(prefix.count))) + $0 : $0 }.joined(separator: "\n")
    }

    // Plain text and Word: a line like "CHAPTER IV" or "Part Two" starts a chapter.
    static func markChapterLines(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^(?=[ \t]*(CHAPTER|Chapter|PART|Part)[ \t]+[A-Za-z0-9]+[.:]?[ \t]*$)"#,
                                  with: chapterMark + titleEnd + "\n\n", options: .regularExpression)
    }

    // MARK: - EPUB

    static func epub(_ url: URL) throws -> String {
        // Apple Books keeps EPUBs unpacked, as a folder; elsewhere an EPUB is one zip file.
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        func file(_ path: String) throws -> String {
            if isFolder.boolValue {
                return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, path]                             // -p: to memory, not disk
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        func first(_ pattern: String, in s: String) -> String? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(s[r])
            guard let q = m.range(of: #"(?<=")[^"]*(?=")"#, options: .regularExpression) else { return nil }
            return String(m[q])
        }
        let container = try file("META-INF/container.xml")
        guard let opfPath = first(#"full-path="[^"]*""#, in: container) else { throw CocoaError(.fileReadCorruptFile) }
        let opf = try file(opfPath)
        let base = (opfPath as NSString).deletingLastPathComponent

        // id -> file, from the manifest; then the reading order from the spine.
        var hrefs: [String: String] = [:]
        for item in matches(#"<item\b[^>]*>"#, in: opf) {
            if let id = first(#"\bid="[^"]*""#, in: item), let href = first(#"\bhref="[^"]*""#, in: item) {
                hrefs[id] = href.removingPercentEncoding ?? href
            }
        }
        let order = matches(#"<itemref\b[^>]*>"#, in: opf).compactMap { first(#"\bidref="[^"]*""#, in: $0) }
        let spine = order.compactMap { hrefs[$0] }
        var pages = try spine.map { href in try file(base.isEmpty ? href : base + "/" + href) }

        // The book's own table of contents (what Books shows): EPUB 3 "nav", or the older NCX.
        var tocPath: String?
        for item in matches(#"<item\b[^>]*>"#, in: opf) {
            let props = first(#"\bproperties="[^"]*""#, in: item) ?? ""
            let type = first(#"\bmedia-type="[^"]*""#, in: item) ?? ""
            if props.split(separator: " ").contains("nav"), let h = first(#"\bhref="[^"]*""#, in: item) { tocPath = h; break }
            if type == "application/x-dtbncx+xml", let h = first(#"\bhref="[^"]*""#, in: item) { tocPath = h }
        }
        if let tocHref = tocPath?.removingPercentEncoding,
           let tocText = try? file(base.isEmpty ? tocHref : base + "/" + tocHref) {
            let tocDir = (tocHref as NSString).deletingLastPathComponent
            var entries = TOCParser.topLevel(tocText)
            // Some books list sections at the same level as chapters. If at least three entries
            // are named "Chapter..." or "Part...", drop the others that sit between the first and
            // last of those (keeping Introduction, Conclusion and the like).
            let chapterLike = #"^\s*(chapter|part|book)\b"#
            let keepAnyway = #"^\s*(introduction|conclusion|prologue|epilogue|interlude|afterword|preface|foreword)\b"#
            let named = entries.indices.filter { entries[$0].title.range(of: chapterLike, options: [.regularExpression, .caseInsensitive]) != nil }
            if named.count >= 3, let firstC = named.first, let lastC = named.last {
                entries = entries.enumerated().filter { i, e in
                    i < firstC || i > lastC + 0 && !isSectionAfterLast(i, lastC, entries)
                        || e.title.range(of: chapterLike, options: [.regularExpression, .caseInsensitive]) != nil
                        || e.title.range(of: keepAnyway, options: [.regularExpression, .caseInsensitive]) != nil
                }.map(\.element)
            }
            if entries.count >= 2 {
                var marked = 0
                for e in entries {
                    let parts = e.href.split(separator: "#", maxSplits: 1).map(String.init)
                    let target = resolve(parts[0].removingPercentEncoding ?? parts[0], from: tocDir)
                    guard let i = spine.firstIndex(where: { resolve($0, from: "") == target }) else { continue }
                    let m = mark(e.title)
                    if parts.count == 2, let r = pages[i].range(of: #"<[^>]+\bid=["']\#(NSRegularExpression.escapedPattern(for: parts[1]))["']"#,
                                                              options: .regularExpression) {
                        pages[i].insert(contentsOf: m, at: r.lowerBound)
                    } else if let body = pages[i].range(of: #"<body[^>]*>"#, options: .regularExpression) {
                        pages[i].insert(contentsOf: m, at: body.upperBound)
                    } else {
                        pages[i] = m + pages[i]
                    }
                    marked += 1
                }
                if marked >= 2 {
                    return pages.map { plain(fromHTML: $0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
            }
        }
        // No usable table of contents: fall back to headings.
        // Chapters: each file in the reading order, and each top heading inside one (some books
        // keep several chapters per file). Top heading = h1 if the book uses it, otherwise h2.
        let h1s = pages.reduce(0) { $0 + matches("(?i)<h1\\b", in: $1).count }
        let top = h1s >= 3 ? "h1" : "h2"
        return pages.map { html in
            plain(fromHTML: html.replacingOccurrences(of: "(?i)<\(top)\\b", with: "\(chapterMark)<\(top)",
                                                      options: .regularExpression))
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n" + chapterMark + "\n\n")
    }

    // After the last chapter, its own sections still follow until back matter starts
    // (Acknowledgments, Notes, About the Author...): those sections are dropped too.
    static func isSectionAfterLast(_ i: Int, _ lastChapter: Int, _ entries: [TOCParser.Entry]) -> Bool {
        let back = #"^\s*(acknowledg|notes|about|index|references|bibliography|credits|copyright|appendix|glossary|endnotes|also by)"#
        for j in (lastChapter + 1)...i where entries[j].title.range(of: back, options: [.regularExpression, .caseInsensitive]) != nil {
            return false            // we've reached the back matter: keep it
        }
        return true
    }

    // "Text/../Text/ch1.xhtml" from "OEBPS" -> "OEBPS/Text/ch1.xhtml" style, for comparing paths.
    static func resolve(_ href: String, from dir: String) -> String {
        var parts: [String] = []
        for p in (dir.isEmpty ? href : dir + "/" + href).split(separator: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    /// Web page to plain text: block ends become paragraph breaks, tags go, entities decode.
    public static func plain(fromHTML html: String) -> String {
        var s = html
        // A decorative large first letter: <span class="dropcap">I</span>T is -> It is.
        if let re = try? NSRegularExpression(pattern: #"<span[^>]*>([A-Z])</span>([A-Z]+)\b"#) {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let all = Range(m.range, in: s), let a = Range(m.range(at: 1), in: s),
                      let b = Range(m.range(at: 2), in: s) else { continue }
                s.replaceSubrange(all, with: String(s[a]) + s[b].lowercased())
            }
        }
        for dead in [#"(?is)<head\b.*?</head>"#, #"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#] {
            s = s.replacingOccurrences(of: dead, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|blockquote|tr|section)>|<br\s*/?>"#,
                                   with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Tidy: collapse runs of spaces, keep paragraph breaks.
        s = s.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*\n\s*"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var s = s
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
                     "&mdash;": ", ", "&ndash;": "-", "&hellip;": "…"]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        guard let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return s }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let all = Range(m.range, in: s), let hexR = Range(m.range(at: 1), in: s),
                  let numR = Range(m.range(at: 2), in: s),
                  let n = UInt32(s[numR], radix: s[hexR].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(n) else { continue }
            s.replaceSubrange(all, with: String(Character(scalar)))
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }
}
