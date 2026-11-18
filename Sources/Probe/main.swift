// Probe: a developer tool, not part of the app.
// Usage: Probe <text file> [--prep] [--phonon] [--text-only] [out.wav]
//   --prep       run the app's TextPrep (sentences, cleaning) first
//   --phonon     also run FluidAudio's own text cleaner (Gradium's Phonon normalizer)
//   --text-only  print the text that would be spoken, make no audio
//   --say W=S    a pronunciation, as in Settings (repeatable): --say "Deji=Day-jee"
//   out.wav      save the audio so we can listen to it or transcribe it
import AVFoundation
import FluidAudio
import Foundation
import ReadAloudCore

let args = CommandLine.arguments
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
