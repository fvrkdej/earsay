// Speaker: turns text into sound with the Azelma voice.
//
// How a read works:
// 1. The voice model loads once at launch, then makes one silent word to warm up
//    the AI chip, so the first read you hear starts instantly.
// 2. The text is split into safe sentences (TextPrep). Each sentence is streamed:
//    the voice sends audio back in small pieces as it makes them, and each piece
//    is queued on the Mac's audio player straight away.
// 3. We stay only about 30 seconds ahead of what you're hearing, so even a whole
//    book never piles up in memory or runs the chip flat out.
// 4. If the audio output changes (AirPods connect or disconnect), macOS stops the
//    audio engine; we restart it and carry on from the sentence you were on.
// 5. While reading, the Mac is kept from idle sleep; the moment we stop, it's released.
import AVFoundation
import FluidAudio
import ReadAloudCore

@MainActor
final class Speaker {
    // A var so it can be let go when idle (the model holds about 400 MB) and loaded again.
    private var voice = PocketTtsManager(defaultVoice: Speaker.voiceName)
    /// The voice to use (changed in Settings). Read once at launch and on every change.
    nonisolated(unsafe) static var voiceName = UserDefaults.standard.string(forKey: "voice") ?? "azelma"
    /// How loud she is right now, 0 to 1, about 20 times a second (the pill and menu bar icon move with it).
    var onLevel: ((Float) -> Void)?
    private var voiceLoaded = false

    // The Mac's audio system: an engine with one player plugged into the speakers.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // Changes speed without changing her pitch (sits between the player and the speakers).
    private let timePitch = AVAudioUnitTimePitch()
    private static let sampleRate = 24_000.0          // the voice makes 24,000 samples a second, mono
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Stay at most this many seconds of audio ahead of what you're hearing.
    private let lookAhead = 30.0

    // The current read.
    private var sentences: [Sentence] = []
    private(set) var playingIndex = 0               // sentence you're hearing now (or just heard)
    private var generating = false
    private var piecesStillToPlay = 0
    private var secondsQueued = 0.0                 // made but not yet heard
    private var readID = 0                          // bumps on every new read or stop; old pieces are ignored
    private var job: Task<Void, Never>?
    private var awake: NSObjectProtocol?            // keeps the Mac from idle sleep while reading
    private var firstAudioLogged = false
    private var reading = false                     // a read is in progress (playing or paused)
    private(set) var paused = false
    private(set) var rate: Float = 1.0
    private var sentenceStartedAt = Date()
    // For jumping by seconds: where each sentence starts on the player's timeline (samples),
    // and how long each sentence turned out to be once made (seconds).
    private var scheduledSamples = 0
    private var timelineStart: [Int: Int] = [:]
    private var pendingSamples: [Int: Int] = [:]
    private var durations: [Int: Double] = [:]
    static let rates: [Float] = [0.75, 0.9, 1.0, 1.1, 1.2, 1.25, 1.5, 1.75, 2.0]

    var isSpeaking: Bool { generating || piecesStillToPlay > 0 }
    /// Seconds of audio made but not heard yet.
    var secondsAhead: Double { secondsQueued / Double(rate) }

    /// Called on the main thread when a new sentence starts playing: (sentence, index, total).
    var onSentence: ((Sentence, Int, Int) -> Void)?
    /// Called when a read ends by itself (not when stopped).
    var onFinished: (() -> Void)?
    /// Book mode: more text will be added as pages turn, so don't end at the last sentence.
    var expectingMore = false
    /// Called once each time everything given so far has been queued (time to add the next page).
    var onNeedMore: (() -> Void)?
    // Which sentence each queued piece of audio belongs to, oldest first.
    private var queuedSentences: [Int] = []
    private var announced = -1

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        // Listen to what's going to the speakers, to know how loud she is.
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            let level = Self.loudness(buf)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLevel?(level) } }
        }
        // Audio output changed (AirPods in or out, speakers switched).
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.outputChanged() }
    }

    var isLoaded: Bool { voiceLoaded }
    /// Paused or playing: a read is in progress.
    var inProgress: Bool { reading || isSpeaking }

    /// Let the voice model go to free memory. The next read loads it again (about 2 s).
    func unloadVoice() {
        guard voiceLoaded, !inProgress else { return }
        voice = PocketTtsManager(defaultVoice: Self.voiceName)
        voiceLoaded = false
        Log.write("voice unloaded (idle)")
    }

    /// Output volume, 0 to 1 (the sleep timer fades her out).
    /// Debug: play everything at zero volume, so a test read makes no sound. Separate from
    /// `volume`, which the sleep timer fades.
    var testSilent: Bool {
        get { player.volume == 0 }
        set { player.volume = newValue ? 0 : 1 }
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func loadVoiceIfNeeded() async throws {
        guard !voiceLoaded else { return }
        let t = Date()
        try await voice.initialize()
        voiceLoaded = true
        Log.write("voice loaded in \(Log.secs(since: t))")
        // Warm-up: the first real generation triggers a one-off setup on the AI chip
        // (about 6 s). Do it now, silently, so the first read you hear is instant.
        let w = Date()
        for try await _ in try await voice.synthesizeStreaming(text: "Ready.") {}
        Log.write("warm-up done in \(Log.secs(since: w))")
    }

    // MARK: - Reading

    /// Start reading this text from the beginning. Call from the main thread.
    func speak(_ text: String, from index: Int = 0, more: Bool = false, skipFrontMatter: Bool = false) {
        stop()
        expectingMore = more
        chapterStarts = []
        chapterNames = []
        let myPrep = readID
        let t = Date()
        Task { @MainActor in
            // Cleaning a whole book takes seconds; do it off the main thread, in parallel.
            let (s, chapters, shown, names) = await Task.detached(priority: .userInitiated) { Self.prepareChapters(text) }.value
            guard myPrep == readID else { return }          // stopped while preparing
            durations = [:]
            chapterStarts = chapters
            chapterNames = names
            paragraphs = shown
            var from = index < s.count ? index : 0
            if skipFrontMatter && from == 0 { from = Self.firstRealSentence(s, chapters: chapters, names: names) }
            Log.write("reading \(s.count) sentences in \(max(chapters.count, 1)) chapters, prepared in \(Log.secs(since: t))"
                      + (from > 0 ? ", from sentence \(from + 1)" : ""))
            start(s, from: from)
        }
    }

    nonisolated static func prepare(_ text: String) -> [Sentence] { prepareChapters(text).0 }

    var sentenceCount: Int { sentences.count }

    /// Add more text to the read in progress (the next page of a book).
    func append(_ text: String) {
        let doc = TextPrep.document(from: text)
        let offset = paragraphs.count
        sentences += doc.sentences.map { var s = $0; s.paragraph += offset; return s }
        paragraphs += doc.paragraphs
    }

    // MARK: - For the reader window

    /// The original paragraphs of the current read, as shown in the reader window.
    private(set) var paragraphs: [String] = []
    var allSentences: [Sentence] { sentences }

    /// Jump to the first sentence of a paragraph (a click in the reader window).
    func goToParagraph(_ p: Int) {
        guard let i = sentences.firstIndex(where: { $0.paragraph == p }) else { return }
        Log.write("reader: jump to paragraph \(p + 1)")
        start(sentences, from: i)
    }

    // MARK: - Chapters

    /// Where each chapter starts (sentence numbers). Empty or one entry = no chapters known.
    private(set) var chapterStarts: [Int] = []
    /// Chapter names from the book's own table of contents ("" where it has none).
    private(set) var chapterNames: [String] = []

    /// The chapter you're in (0-based), or nil if the text has no chapters.
    var chapterIndex: Int? {
        guard chapterStarts.count > 1 else { return nil }
        return chapterStarts.lastIndex { $0 <= playingIndex } ?? 0
    }

    /// Next chapter (+1), or previous (-1). Going back from more than a couple of sentences
    /// into a chapter goes to its start first, like a music player. False if there's nowhere to go.
    @discardableResult
    func jumpChapter(by step: Int) -> Bool {
        guard isSpeaking, let cur = chapterIndex else { return false }
        let target = step > 0 ? cur + 1 : (playingIndex - chapterStarts[cur] > 2 ? cur : cur - 1)
        guard target >= 0, target < chapterStarts.count else { return false }
        Log.write("chapter \(cur + 1) to \(target + 1) of \(chapterStarts.count)")
        start(sentences, from: chapterStarts[target])
        return true
    }

    /// Where an audiobook would start: the first chapter that opens with Preface, Foreword,
    /// Prologue, Introduction, Chapter or Part (skipping cover, copyright, contents). With no
    /// such heading, the first run of three full-length sentences (real prose, not lists).
    nonisolated static func firstRealSentence(_ s: [Sentence], chapters: [Int], names: [String] = []) -> Int {
        let opener = #"^(preface|foreword|prologue|introduction|chapter|part|1\b)"#
        for (k, c) in chapters.enumerated() where c < s.count {
            let name = k < names.count ? names[k] : ""
            let head = name + " " + s[c..<min(c + 2, s.count)].map(\.text).joined(separator: " ")
            if name.range(of: opener, options: [.regularExpression, .caseInsensitive]) != nil
                || head.trimmingCharacters(in: .whitespaces).range(of: opener, options: [.regularExpression, .caseInsensitive]) != nil { return c }
        }
        let limit = min(s.count, 3000)
        for i in 0..<max(0, limit - 2) where (i..<i + 3).allSatisfy({ s[$0].text.split(separator: " ").count >= 12 }) {
            return i
        }
        return 0
    }

    /// A name for each chapter: its first sentence, shortened.
    func chapterTitles() -> [String] {
        chapterStarts.enumerated().map { k, i in
            if k < chapterNames.count, !chapterNames[k].isEmpty { return chapterNames[k] }
            var t = i < sentences.count ? sentences[i].text : ""
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
            return t.count > 60 ? String(t.prefix(57)) + "..." : t
        }
    }

    func goToChapter(_ n: Int) {
        guard isSpeaking, n >= 0, n < chapterStarts.count else { return }
        Log.write("chapter list: to chapter \(n + 1)")
        start(sentences, from: chapterStarts[n])
    }

    // Split on the chapter marks, prepare each chapter (in parallel), note where each starts.
    /// Sentences, where each chapter starts, and the original paragraphs. Chapters (or, with
    /// no chapters, slices of a long text) are prepared in parallel and joined back in order.
    nonisolated static func prepareChapters(_ text: String) -> ([Sentence], [Int], [String], [String]) {
        var chunks = text.components(separatedBy: BookText.chapterMark)
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
        let hasChapters = chunks.count > 1
        if !hasChapters && text.count > 20_000 {
            // One long text: cut at paragraph breaks into a slice per core.
            let paras = text.components(separatedBy: "\n\n")
            let n = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let per = (paras.count + n - 1) / n
            chunks = stride(from: 0, to: paras.count, by: per).map {
                paras[$0..<min($0 + per, paras.count)].joined(separator: "\n\n")
            }
        }
        // A chapter may start with its name from the table of contents: "Name\u{1F}".
        var titles = [String](repeating: "", count: chunks.count)
        for (k, c) in chunks.enumerated() {
            if let end = c.range(of: BookText.titleEnd) {
                titles[k] = String(c[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                chunks[k] = String(c[end.upperBound...])
            }
        }
        var names: [String] = []
        var results = [(sentences: [Sentence], paragraphs: [String])](repeating: ([], []), count: chunks.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
            let r = TextPrep.document(from: chunks[i])
            lock.lock(); results[i] = r; lock.unlock()
        }
        var starts: [Int] = [], all: [Sentence] = [], shown: [String] = []
        for (k, r) in results.enumerated() where !r.sentences.isEmpty {
            starts.append(all.count)
            names.append(titles[k])
            let offset = shown.count
            all += r.sentences.map { var s = $0; s.paragraph += offset; return s }
            shown += r.paragraphs
        }
        return (all, hasChapters ? starts : [], shown, hasChapters ? names : [])
    }

    /// Roughly how long is left, at the current speed.
    func secondsLeft() -> Double {
        guard playingIndex < sentences.count else { return 0 }
        let rest = (playingIndex..<sentences.count).reduce(0.0) { $0 + length($1) }
        return rest / Double(rate)
    }

    /// Stop talking now and throw away anything queued.
    func stop() {
        reading = false
        paused = false
        expectingMore = false
        readID += 1
        job?.cancel()
        job = nil
        generating = false
        piecesStillToPlay = 0
        secondsQueued = 0
        queuedSentences = []
        announced = -1
        player.stop()
        releaseSleep()
    }

    private func start(_ newSentences: [Sentence], from index: Int, paused startPaused: Bool = false) {
        let more = expectingMore
        stop()
        expectingMore = more
        sentences = newSentences
        playingIndex = index
        readID += 1
        firstAudioLogged = false
        let myRead = readID
        generating = true
        reading = true
        paused = startPaused
        scheduledSamples = 0
        timelineStart = [:]
        pendingSamples = [:]
        if !paused { holdSleep() }

        job = Task { @MainActor in
            do {
                try await loadVoiceIfNeeded()
                if !engine.isRunning { try engine.start() }
                if !paused { player.play() }
                let t = Date()
                var i = index
                var askedForMore = false
                while true {
                    if myRead != readID || Task.isCancelled { throw CancellationError() }   // stopped
                    if i >= sentences.count {
                        // Book mode: wait for the next page instead of ending.
                        guard expectingMore else { break }
                        if !askedForMore { askedForMore = true; onNeedMore?() }
                        try await Task.sleep(nanoseconds: 200_000_000)
                        if myRead != readID { throw CancellationError() }
                        continue
                    }
                    askedForMore = false
                    // Don't race ahead: wait while 30 s or more is already queued.
                    while secondsQueued > lookAhead {
                        try await Task.sleep(nanoseconds: 200_000_000)
                        if myRead != readID { throw CancellationError() }
                    }
                    pendingSamples[i] = 0
                    try await say(sentences[i].text, sentence: i, read: myRead, started: t)
                    if sentences[i].endsParagraph { queue(silence(seconds: 0.3), sentence: i, read: myRead) }
                    else if sentences[i].endsLine { queue(silence(seconds: 0.2), sentence: i, read: myRead) }
                    else if sentences[i].text.hasSuffix("…") { queue(silence(seconds: 0.08), sentence: i, read: myRead) }
                    durations[i] = Double(pendingSamples[i] ?? 0) / Self.sampleRate
                    i += 1
                }
                Log.write("whole text made in \(Log.secs(since: t))")
            } catch is CancellationError {
                // stopped by the user or restarted after an output change
            } catch {
                Log.write("speak failed: \(error)")
            }
            if myRead == readID {
                generating = false
                finishIfDone()
            }
        }
    }

    // Say one sentence. If the voice fails on it, try again in two halves;
    // if a half still fails, skip that half and keep going.
    private func say(_ text: String, sentence: Int, read: Int, started: Date, retry: Bool = true) async throws {
        do {
            // Our cleaning (TextPrep) ran already; FluidAudio's own cleaner (Gradium's Phonon
            // normalizer) adds temperatures, big numbers and the rest on top.
            for try await frame in try await voice.synthesizeStreaming(text: PhononTextNormalizer.normalize(text)) {
                if Task.isCancelled || read != readID { throw CancellationError() }
                if !firstAudioLogged { Log.write("first audio after \(Log.secs(since: started))"); firstAudioLogged = true }
                queue(frame.samples, sentence: sentence, read: read)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let words = text.split(separator: " ")
            guard retry, words.count > 3 else {
                Log.write("skipped a piece of \(words.count) words: \(error)")
                return
            }
            Log.write("sentence of \(words.count) words failed, retrying in halves: \(error)")
            let mid = words.count / 2
            try await say(words[..<mid].joined(separator: " ") + "…", sentence: sentence, read: read, started: started, retry: false)
            try await say(words[mid...].joined(separator: " "), sentence: sentence, read: read, started: started, retry: false)
        }
    }

    // MARK: - Audio queue

    private func queue(_ samples: [Float], sentence: Int, read: Int) {
        guard read == readID else { return }        // from a read that has been stopped
        let seconds = Double(samples.count) / Self.sampleRate
        if timelineStart[sentence] == nil { timelineStart[sentence] = scheduledSamples }
        scheduledSamples += samples.count
        pendingSamples[sentence, default: 0] += samples.count
        queuedSentences.append(sentence)
        if queuedSentences.count == 1 { announce(sentence) }   // nothing ahead of it: it plays now
        piecesStillToPlay += 1
        secondsQueued += seconds
        player.scheduleBuffer(buffer(from: samples), completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, read == self.readID else { return }
                self.piecesStillToPlay -= 1
                self.secondsQueued -= seconds
                if !self.queuedSentences.isEmpty { self.queuedSentences.removeFirst() }
                if let next = self.queuedSentences.first { self.announce(next) }
                self.finishIfDone()
            }
        }
    }

    // A sentence has started playing: tell the pill.
    private func announce(_ index: Int) {
        guard index != announced, index < sentences.count else { return }
        announced = index
        playingIndex = index
        sentenceStartedAt = Date()
        // For measuring: how far into the sentence the player's clock already was when we said
        // "it started" (wall-clock ms: the player's time runs at the speed setting).
        Log.write("sync: sentence \(index) at \(rate)x, announced \(Int(secondsIntoCurrent() / Double(rate) * 1000)) ms after it began")
        onSentence?(sentences[index], index, sentences.count)
    }

    // Everything made and everything heard: the read is over.
    private func finishIfDone() {
        guard !generating, piecesStillToPlay == 0, reading else { return }
        reading = false
        Log.write("read finished")
        releaseSleep()
        onFinished?()
    }

    // MARK: - Output changes (AirPods in or out)

    private func outputChanged() {
        guard isSpeaking else { return }
        let resumeAt = playingIndex
        Log.write("audio output changed; carrying on from sentence \(resumeAt + 1)")
        // The engine was stopped by macOS and its queue emptied. Restart from the
        // start of the sentence you were on.
        start(sentences, from: resumeAt, paused: paused)
    }

    // MARK: - Controls

    /// Pause or carry on. Returns the new paused state.
    @discardableResult
    func togglePause() -> Bool {
        guard isSpeaking else { return false }
        paused.toggle()
        if paused { player.pause(); releaseSleep() } else { player.play(); holdSleep() }
        Log.write(paused ? "paused" : "resumed")
        return paused
    }

    func back() { jump(by: -10) }
    func skip() { jump(by: 10) }

    /// Jump about this many seconds back (negative) or forward, landing on the sentence
    /// start nearest that point, so she never starts mid-word. Always moves at least one
    /// sentence when the nearest start would be the one you're already in.
    func jump(by seconds: Double) {
        guard isSpeaking, !sentences.isEmpty else { return }
        let cur = playingIndex
        let into = max(0, min(secondsIntoCurrent(), length(cur)))
        var best = cur
        if seconds < 0 {
            var bestGap = abs(-into - seconds)
            var t = -into, i = cur                         // t = when sentence i started, relative to now
            while i > 0 && t > seconds {
                i -= 1; t -= length(i)
                if abs(t - seconds) < bestGap { best = i; bestGap = abs(t - seconds) }
            }
            if best == cur && into < 2 { best = max(0, cur - 1) }
        } else {
            var i = cur + 1, t = length(cur) - into        // t = when sentence i will start
            best = i
            var bestGap = abs(t - seconds)
            while i < sentences.count && t < seconds {
                t += length(i); i += 1
                if abs(t - seconds) < bestGap { best = i; bestGap = abs(t - seconds) }
            }
        }
        if best >= sentences.count && expectingMore { best = sentences.count }   // book mode: next page
        else if best >= sentences.count { stop(); onFinished?(); return }
        Log.write("jump \(Int(seconds)) s: sentence \(cur + 1) to \(best + 1)")
        start(sentences, from: best, paused: false)
    }

    // How long a sentence lasts: measured once made, otherwise guessed from its words.
    private func length(_ i: Int) -> Double {
        guard i >= 0, i < sentences.count else { return 0 }
        return durations[i] ?? Double(sentences[i].text.split(separator: " ").count) / 2.7
    }

    // How far into the current sentence you are, from the player's own clock.
    private func secondsIntoCurrent() -> Double {
        guard let start = timelineStart[playingIndex],
              let now = player.lastRenderTime,
              let t = player.playerTime(forNodeTime: now) else { return 0 }
        return Double(Int(t.sampleTime) - start) / Self.sampleRate
    }

    /// Step the speed up (+1) or down (-1). Wraps round when cycling from the pill.
    func changeRate(by step: Int, wrap: Bool = false) {
        let all = Self.rates
        let i = all.firstIndex(of: rate) ?? all.firstIndex(of: 1.0) ?? 0
        var n = i + step
        if wrap { n = (n + all.count) % all.count } else { n = min(max(n, 0), all.count - 1) }
        rate = all[n]
        timePitch.rate = rate
        Log.write("speed \(rate)x")
    }

    // MARK: - Sleep

    private func holdSleep() {
        guard awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Reading aloud")
    }

    private func releaseSleep() {
        if let a = awake { ProcessInfo.processInfo.endActivity(a) }
        awake = nil
    }

    // MARK: - Helpers

    /// Change voice. The next sentence uses it.
    func setVoice(_ name: String) {
        Self.voiceName = name
        let v = voice
        Task { await v.setDefaultVoice(name) }
        Log.write("voice: \(name)")
    }

    func setRate(_ r: Float) {
        rate = r
        timePitch.rate = r
    }

    // Root-mean-square of a buffer, scaled so normal speech fills most of 0...1.
    nonisolated static func loudness(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(buf.frameLength)).squareRoot()
        return min(1, rms * 6)
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Self.sampleRate))
    }

    // Copy the voice's numbers into the format the audio player wants.
    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = buf.frameCapacity
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        return buf
    }
}
