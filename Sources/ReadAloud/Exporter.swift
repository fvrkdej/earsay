// Exporter: turn a book or file into an audiobook you can put on your phone.
//
// - Same voice, same tidying and pauses as reading aloud.
// - Made in the background with its own copy of the voice, at low priority. Whenever you're
//   listening to something, the export waits, so your reading never stutters.
// - Writes AAC audio as it goes (never the whole book in memory). If ffmpeg is installed it
//   then adds chapter marks and saves an .m4b (Apple Books and podcast apps show chapters);
//   otherwise you get an .m4a without chapters.
// - Saved to ~/Music/Earsay/, then shown in Finder.
import AVFoundation
import AppKit
import FluidAudio
import ReadAloudCore

@MainActor
final class Exporter {
    private(set) var running = false
    var reveal = true                    // show the file in Finder when done
    private var cancelled = false
    /// Progress for the menu ("Exporting Pride and Prejudice: 12%"), nil when done.
    var onProgress: (String?) -> Void = { _ in }
    /// True while you're listening to something: the export waits.
    var isBusy: () -> Bool = { false }

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Earsay")

    func cancel() { cancelled = true }

    func export(path: String) {
        guard !running else { return }
        running = true
        cancelled = false
        let title = AppDelegate.niceName(path)
        Task { @MainActor in
            defer { running = false; onProgress(nil) }
            do {
                onProgress("Preparing \(title)...")
                let text = try await Task.detached(priority: .utility) { try BookText.load(URL(fileURLWithPath: path)) }.value
                let (sentences, starts, _, names) = await Task.detached(priority: .utility) { Speaker.prepareChapters(text) }.value
                guard !sentences.isEmpty else { NSSound(named: "Tink")?.play(); return }
                let from = Speaker.firstRealSentence(sentences, chapters: starts, names: names)
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("readaloud-export-\(UUID().uuidString).m4a")
                let t = Date()
                let chapterTimes = try await make(sentences: sentences, from: from, starts: starts, to: tmp, title: title)
                guard !cancelled else { try? FileManager.default.removeItem(at: tmp); Log.write("export: cancelled"); return }
                let titles = (0..<starts.count).map { k in k < names.count && !names[k].isEmpty ? names[k] : "Chapter \(k + 1)" }
                let out = try finish(tmp, title: title, chapters: zip(chapterTimes, titles).map { ($0.0, $0.1) })
                Log.write("export: done in \(Log.secs(since: t)), \(out.pathExtension)")
                NSSound(named: "Glass")?.play()
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            } catch {
                Log.write("export: failed: \(error)")
                NSSound(named: "Tink")?.play()
            }
        }
    }

    // Make the audio, sentence by sentence. Returns each chapter's start in seconds.
    private func make(sentences: [Sentence], from: Int, starts: [Int], to url: URL, title: String) async throws -> [Double] {
        let rate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let voice = PocketTtsManager(defaultVoice: Speaker.voiceName)
        try await voice.initialize()
        var written = 0
        var chapterTimes: [Double] = []
        let wanted = starts.filter { $0 >= from }
        func write(_ samples: [Float]) throws {
            guard !samples.isEmpty else { return }
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buf.frameLength = buf.frameCapacity
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try file.write(from: buf)
            written += samples.count
        }
        let total = sentences.count - from
        for i in from..<sentences.count {
            if cancelled { break }
            while isBusy() && !cancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }   // you're listening: wait
            if wanted.contains(i) { chapterTimes.append(Double(written) / rate) }
            var samples: [Float] = []
            do {
                for try await frame in try await voice.synthesizeStreaming(text: PhononTextNormalizer.normalize(sentences[i].text)) {
                    samples += frame.samples
                }
            } catch {
                Log.write("export: skipped a sentence: \(error)")
            }
            try write(samples)
            let pause = sentences[i].endsParagraph ? 0.3 : (sentences[i].endsLine ? 0.2 : (sentences[i].text.hasSuffix("…") ? 0.08 : 0))
            if pause > 0 { try write([Float](repeating: 0, count: Int(pause * rate))) }
            let done = i - from + 1
            if done % 10 == 0 || done == total {
                let pct = Int(Double(done) / Double(total) * 100)
                onProgress("Exporting \(title): \(pct)%" + (isBusy() ? " (paused while you listen)" : ""))
            }
            await Task.yield()
        }
        if wanted.isEmpty { chapterTimes = [0] }
        return chapterTimes
    }

    // Add chapter marks with ffmpeg if it's here (.m4b); otherwise keep the .m4a.
    private func finish(_ tmp: URL, title: String, chapters: [(Double, String)]) throws -> URL {
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let fm = FileManager.default
        func free(_ ext: String) -> URL {
            var u = Self.folder.appendingPathComponent("\(safe).\(ext)")
            var n = 2
            while fm.fileExists(atPath: u.path) { u = Self.folder.appendingPathComponent("\(safe) \(n).\(ext)"); n += 1 }
            return u
        }
        if let ffmpeg = Self.ffmpeg, chapters.count > 1 {
            let duration = (try? AVAudioFile(forReading: tmp)).map { Double($0.length) / 24_000 } ?? 0
            var meta = ";FFMETADATA1\ntitle=\(Self.escape(title))\nartist=Earsay\ngenre=Audiobook\n"
            for (k, (start, name)) in chapters.enumerated() {
                let end = k + 1 < chapters.count ? chapters[k + 1].0 : duration
                meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(start * 1000))\nEND=\(Int(end * 1000))\ntitle=\(Self.escape(name))\n"
            }
            let metaURL = tmp.deletingPathExtension().appendingPathExtension("txt")
            try meta.write(to: metaURL, atomically: true, encoding: .utf8)
            let out = free("m4b")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-v", "error", "-i", tmp.path, "-i", metaURL.path, "-map", "0:a", "-map_metadata", "1",
                           "-map_chapters", "1", "-c", "copy", "-f", "mp4", out.path]
            try p.run()
            p.waitUntilExit()
            try? fm.removeItem(at: metaURL)
            if p.terminationStatus == 0 { try? fm.removeItem(at: tmp); return out }
            Log.write("export: ffmpeg couldn't add chapters, keeping the plain file")
        }
        let out = free("m4a")
        try fm.moveItem(at: tmp, to: out)
        return out
    }

    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", NSHomeDirectory() + "/.local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s { if "=;#\\\n".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }
}
