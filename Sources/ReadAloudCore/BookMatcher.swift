// BookMatcher: is the book open in Apple Books one of your own files? If so, where?
//
// We read a few short stretches of the page on screen and look for them in each of your
// Books files (only ones already on this Mac; nothing is downloaded). Letters only, so
// curly quotes, line breaks and small text-reader slips don't matter. A hit gives the file
// and the spot the page starts at, and the app reads the real file from there: chapters,
// time left, resume. No hit means a bought book: page-turning instead.
// The files' text is kept in memory for the session, so the second time is instant.
import Foundation

public enum BookMatcher {
    public struct Found { public let path: String; public let offset: Int }   // offset: character in the file's text

    private static var cache: [String: (raw: String, letters: [Character], map: [Int])] = [:]
    private static let lock = NSLock()

    public static func find(pageText: String, windowTitle: String, folder: URL) -> Found? {
        let page = letters(of: pageText).letters
        guard page.count >= 80 else { return nil }
        // A few stretches of 40 letters from different parts of the page.
        let probes = [20, page.count / 3, page.count / 2, (page.count * 2) / 3]
            .filter { $0 + 40 <= page.count }
            .map { (start: $0, text: String(page[$0..<$0 + 40])) }

        for path in candidates(in: folder, title: windowTitle) {
            guard let doc = load(path) else { continue }
            let haystack = String(doc.letters)
            for probe in probes {
                guard let r = haystack.range(of: probe.text) else { continue }
                let hit = haystack.distance(from: haystack.startIndex, to: r.lowerBound)
                let pageStart = max(0, hit - probe.start)      // back up to where the page begins
                return Found(path: path, offset: doc.map[min(pageStart, doc.map.count - 1)])
            }
        }
        return nil
    }

    public static func rawText(_ path: String) -> String? { load(path)?.raw }

    /// Which stretch of a known file is on screen: start and end, counted in letters.
    public static func locate(pageText: String, in path: String) -> (start: Int, end: Int)? {
        guard let doc = load(path) else { return nil }
        let page = letters(of: pageText).letters
        guard page.count >= 60 else { return nil }
        let hay = haystack(path, doc)
        for start in [20, page.count / 3, page.count / 2, (page.count * 2) / 3] where start + 40 <= page.count {
            guard let r = hay.range(of: String(page[start..<start + 40])) else { continue }
            let hit = hay.distance(from: hay.startIndex, to: r.lowerBound)
            let s0 = max(0, hit - start)
            return (s0, s0 + page.count)
        }
        return nil
    }

    /// Where a paragraph (as shown in the reader) starts in the file, counted in letters.
    /// Looks near `near` first, since books repeat phrases.
    public static func letterOffset(of paragraph: String, in path: String, near: Int) -> (offset: Int, length: Int)? {
        guard let doc = load(path) else { return nil }
        let p = letters(of: paragraph).letters
        guard p.count >= 12 else { return nil }
        let probe = String(p.prefix(40))
        let hay = haystack(path, doc)
        let from = hay.index(hay.startIndex, offsetBy: max(0, min(near - 30_000, hay.count - 1)))
        let r = hay.range(of: probe, range: from..<hay.endIndex) ?? hay.range(of: probe)
        guard let r else { return nil }
        return (hay.distance(from: hay.startIndex, to: r.lowerBound), p.count)
    }

    private static var hays: [String: String] = [:]
    private static func haystack(_ path: String, _ doc: (raw: String, letters: [Character], map: [Int])) -> String {
        lock.lock(); defer { lock.unlock() }
        if let h = hays[path] { return h }
        let h = String(doc.letters)
        hays[path] = h
        return h
    }

    // Your Books files that are on this Mac, the ones whose name looks like the window title first.
    private static func candidates(in folder: URL, title: String) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])) ?? []
        let local = urls.filter { url in
            guard BookText.fileTypes.contains(url.pathExtension.lowercased()) else { return false }
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            return status == nil || status == .current
        }
        let words = Set(title.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 })
        func score(_ u: URL) -> Int {
            let name = Set(u.deletingPathExtension().lastPathComponent.lowercased().split { !$0.isLetter }.map(String.init))
            return name.intersection(words).count
        }
        return local.sorted { score($0) > score($1) }.map(\.path)
    }

    private static func load(_ path: String) -> (raw: String, letters: [Character], map: [Int])? {
        lock.lock(); if let c = cache[path] { lock.unlock(); return c }; lock.unlock()
        guard let raw = try? BookText.load(URL(fileURLWithPath: path)) else { return nil }
        let l = letters(of: raw)
        let entry = (raw, l.letters, l.map)
        lock.lock(); cache[path] = entry; lock.unlock()
        return entry
    }

    // Lowercase letters only, and for each letter, where it sits in the original text.
    private static func letters(of text: String) -> (letters: [Character], map: [Int]) {
        var out: [Character] = [], map: [Int] = []
        out.reserveCapacity(text.count); map.reserveCapacity(text.count)
        for (i, ch) in text.enumerated() where ch.isLetter {
            out.append(Character(ch.lowercased()))
            map.append(i)
        }
        return (out, map)
    }
}
