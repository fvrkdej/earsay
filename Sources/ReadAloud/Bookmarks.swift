// Bookmarks: remember where you stopped in a file, so you can carry on later.
//
// Stores ONLY the file's location and a sentence number (in the app's settings,
// ~/Library/Preferences/io.autimized.readaloud.plist). Never the text, never audio.
// Highlighted text and screen reads are never remembered. Finishing a file clears it.
import Foundation

enum Bookmarks {
    private static let store = UserDefaults.standard
    private static let key = "positions"            // path -> [sentence index, sentence count]

    static var last: String? {
        get { store.string(forKey: "lastFile") }
        set { store.set(newValue, forKey: "lastFile") }
    }

    static func save(_ path: String, index: Int, total: Int) {
        var all = store.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        all[path] = [index, total]
        store.set(all, forKey: key)
    }

    static func position(_ path: String) -> Int? {
        (store.dictionary(forKey: key) as? [String: [Int]])?[path]?.first
    }

    static func percent(_ path: String) -> Int? {
        guard let p = (store.dictionary(forKey: key) as? [String: [Int]])?[path], p.count == 2,
              p[0] > 0, p[1] > 0 else { return nil }
        return Int(Double(p[0]) / Double(p[1]) * 100)
    }

    // The library: when each file was last opened, and which ones you finished.
    // Still only paths, dates and numbers.
    static func opened(_ path: String) {
        var all = store.dictionary(forKey: "opened") as? [String: Double] ?? [:]
        all[path] = Date().timeIntervalSince1970
        store.set(all, forKey: "opened")
        var done = Set(store.stringArray(forKey: "finished") ?? [])
        done.remove(path)
        store.set(Array(done), forKey: "finished")
    }

    static func finished(_ path: String) {
        var done = Set(store.stringArray(forKey: "finished") ?? [])
        done.insert(path)
        store.set(Array(done), forKey: "finished")
    }

    static func isFinished(_ path: String) -> Bool { (store.stringArray(forKey: "finished") ?? []).contains(path) }

    /// Remove from the library (forgets the place too). The file itself is untouched.
    static func forget(_ path: String) {
        clear(path)
        var all = store.dictionary(forKey: "opened") as? [String: Double] ?? [:]
        all[path] = nil
        store.set(all, forKey: "opened")
    }

    /// Files you've opened, most recent first (only ones that still exist).
    static var library: [String] {
        let opened = store.dictionary(forKey: "opened") as? [String: Double] ?? [:]
        let placed = Set((store.dictionary(forKey: key) as? [String: [Int]] ?? [:]).keys)
        let paths = Set(opened.keys).union(placed)
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
            .sorted { (opened[$0] ?? 0) > (opened[$1] ?? 0) }
    }

    static func clear(_ path: String) {
        var all = store.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        all[path] = nil
        store.set(all, forKey: key)
    }
}
