// A tiny log at ~/.local/share/read-aloud/app.log so we can see timings and errors.
import Foundation

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/read-aloud/app.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        // A fresh Mac has no folder yet: make it, or nothing would ever be logged.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func secs(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }
}
