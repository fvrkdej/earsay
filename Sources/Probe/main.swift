// Probe: a developer tool, not part of the app.
// Usage: Probe <text file> [--prep] [--phonon] [--text-only] [out.wav]
//   --prep       run the app's TextPrep (sentences, cleaning) first
//   --phonon     also run FluidAudio's own text cleaner (Gradium's Phonon normalizer)
//   --text-only  print the text that would be spoken, make no audio
//   --say W=S    a pronunciation, as in Settings (repeatable): --say "Deji=Day-jee"
//   --check-lines  (no file needed) test that the highlight's line numbering matches the voice's
//   out.wav      save the audio so we can listen to it or transcribe it
import AVFoundation
import FluidAudio
import Foundation
import ReadAloudCore

let args = CommandLine.arguments
// Test: for nested lists (a one-word parent like "Audio:"), flat lists, tables and plain paragraphs,
// the number of spoken lines TextPrep.document makes must equal TextPrep.lineGroups.
if args.contains("--check-lines") {
    let cases = [
        "Reusable tools:\n\nAudio:\nrecord your voice on the laptop at the same time and line it up by sound wave\nclean the noise out of the recording\nVideo:\ncut the screen recording to the narration\nPublish the finished film as a single file.",
        "First item in the list\nSecond item in the list\nThird item in the list",
        "Dish, Price, Vegetarian?\nPasta, 12, yes\nSteak, 30, no\n\nA plain paragraph with several words in it. And a second sentence.",
        "Alpha:\n---\nBeta item has words\nGamma:",
    ]
    var failed = 0
    for (n, c) in cases.enumerated() {
        let doc = TextPrep.document(from: c)
        let paras = c.components(separatedBy: "\n\n").filter { !TextPrep.lineGroups($0).isEmpty }
        var ok = paras.count == doc.paragraphs.count
        for (pi, para) in paras.enumerated() {
            let spoken = doc.sentences.filter { $0.paragraph == pi && $0.endsLine }.count
            let mine = TextPrep.lineGroups(para).count
            print("case \(n + 1), paragraph \(pi + 1): raw lines \(para.components(separatedBy: "\n").count), spoken lines \(spoken), mapped \(mine)")
            if spoken != mine { ok = false }
        }
        if !ok { failed += 1; print("  MISMATCH") }
    }
    print(failed == 0 ? "all line counts match" : "\(failed) case(s) mismatched")
    exit(failed == 0 ? 0 : 1)
}
let text = try BookText.load(URL(fileURLWithPath: args[1]))   // txt, md, pdf, epub, docx
let out = args.dropFirst(2).first { $0.hasSuffix(".wav") }
TextPrep.sayAs = args.indices.compactMap { i -> (word: String, say: String)? in
    guard args[i] == "--say", i + 1 < args.count else { return nil }
    let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}

var sentences: [String]
var pauses: [Double] = []          // silence after each sentence, as the app adds it
if args.contains("--prep") {
    let prepared = TextPrep.sentences(from: text)
    sentences = prepared.map(\.text)
    pauses = prepared.map { $0.endsParagraph ? 0.3 : ($0.endsLine ? 0.2 : ($0.text.hasSuffix("…") ? 0.08 : 0)) }
} else if args.contains("--phonon") {
    sentences = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
} else {
    sentences = [text]
}
if args.contains("--phonon") {
    sentences = sentences.map { PhononTextNormalizer.normalize($0) }
}
if args.contains("--text-only") {
    for s in sentences { print(s) }
    exit(0)
}

// Stream sentence by sentence, exactly as the app does: FluidAudio's own cleaner on top of
// ours, and the same pauses after paragraphs, lines and "…" pieces.
let voice = PocketTtsManager(defaultVoice: "azelma")
try await voice.initialize()
var all: [Float] = []
let started = Date()
for (i, s) in sentences.enumerated() {
    print(String(format: "sentence %d at %.2fs: %@", i + 1, Double(all.count) / 24_000, s))
    do {
        let said = pauses.isEmpty ? s : PhononTextNormalizer.normalize(s)
        for try await f in try await voice.synthesizeStreaming(text: said) { all += f.samples }
    } catch { print("  FAILED: \(error)") }
    if i < pauses.count, pauses[i] > 0 { all += [Float](repeating: 0, count: Int(pauses[i] * 24_000)) }
}
print(String(format: "total audio %.1fs, made in %.1fs", Double(all.count) / 24_000, Date().timeIntervalSince(started)))

if let out {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count))!
    buf.frameLength = buf.frameCapacity
    all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: format.settings)
    try file.write(from: buf)
}
