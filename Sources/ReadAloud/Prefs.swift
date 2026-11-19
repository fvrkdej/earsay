// Prefs: the settings, the Settings window, and the first-launch Welcome window.
import AppKit
import Carbon
import SwiftUI
import ReadAloudCore

/// Everything you can change, kept in the app's settings (UserDefaults).
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    /// All voices that come with the voice engine (all downloaded with the model).
    static let voices = ["azelma", "alba", "anna", "bill_boerst", "caro_davy", "charles", "cosette",
                         "daan", "eponine", "estelle", "eve", "fantine", "george", "giovanni", "jane",
                         "javert", "jean", "juergen", "lola", "marius", "mary", "michael", "paul",
                         "peter_yearsley", "rafael", "stuart_bell", "vera"]
    static func voiceName(_ id: String) -> String {
        id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    @Published var voice: String { didSet { d.set(voice, forKey: "voice"); onVoice(voice) } }
    @Published var defaultRate: Float { didSet { d.set(defaultRate, forKey: "defaultRate") } }
    @Published var miniPill: Bool { didSet { d.set(miniPill, forKey: "miniPill"); onLook() } }
    /// Soft highlight on the paragraph she's reading, in the app you clicked in.
    @Published var highlightOnScreen: Bool { didSet { d.set(highlightOnScreen, forKey: "highlightOnScreen"); onLook() } }
    /// Scroll that app so the paragraph she's reading stays in view.
    @Published var scrollAlong: Bool { didSet { d.set(scrollAlong, forKey: "scrollAlong") } }
    /// The main shortcut (default Control+Option+R).
    @Published var keyCode: Int { didSet { d.set(keyCode, forKey: "keyCode"); onShortcut() } }
    @Published var keyMods: Int { didSet { d.set(keyMods, forKey: "keyMods"); onShortcut() } }
    /// Words she should say differently, each [word, say it as]. Applied everywhere she reads.
    @Published var pronunciations: [[String]] { didSet { d.set(pronunciations, forKey: "pronunciations"); Prefs.apply(pronunciations) } }
    /// Pause when the microphone turns on during a read (a call, a voice note).
    @Published var pauseForCalls: Bool { didSet { d.set(pauseForCalls, forKey: "pauseForCalls") } }
    var welcomeDone: Bool {
        get { d.bool(forKey: "welcomeDone") }
        set { d.set(newValue, forKey: "welcomeDone") }
    }

    var onVoice: (String) -> Void = { _ in }
    var onShortcut: () -> Void = {}
    var onLook: () -> Void = {}

    private init() {
        voice = d.string(forKey: "voice") ?? "azelma"
        let saved = d.object(forKey: "defaultRate") as? Float ?? 1.0
        defaultRate = Speaker.rates.contains(saved) ? saved : 1.0     // a speed no longer on the list: normal
        miniPill = d.bool(forKey: "miniPill")
        highlightOnScreen = d.object(forKey: "highlightOnScreen") as? Bool ?? true
        scrollAlong = d.object(forKey: "scrollAlong") as? Bool ?? true
        keyCode = d.object(forKey: "keyCode") as? Int ?? kVK_ANSI_R
        keyMods = d.object(forKey: "keyMods") as? Int ?? (controlKey | optionKey)
        pronunciations = d.array(forKey: "pronunciations") as? [[String]] ?? []
        pauseForCalls = d.object(forKey: "pauseForCalls") as? Bool ?? true
        Prefs.apply(pronunciations)
    }

    static func apply(_ list: [[String]]) {
        TextPrep.sayAs = list.compactMap { row in
            guard row.count == 2 else { return nil }
            return (row[0].trimmingCharacters(in: .whitespaces), row[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// "⌃⌥R" style label for a shortcut.
    static func shortcutLabel(code: Int, mods: Int) -> String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + keyName(code)
    }

    static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                      kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10"]
        if let s = special[code] { return s }
        // Ask the keyboard layout what character this key types.
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }

    /// Cocoa modifier flags -> Carbon modifiers (what RegisterEventHotKey wants).
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        return m
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var preview: (String) -> Void
    /// Say some text in a given voice (for trying pronunciations).
    var hear: (String, String) -> Void = { _, _ in }
    @State private var hearIn = Prefs.shared.voice
    @State private var recording = false
    @State private var monitor: Any?
    @State private var loginOn = LoginItem.isOn

    var body: some View {
        Form {
            Section("Voice") {
                Picker("Voice", selection: $prefs.voice) {
                    ForEach(Prefs.voices, id: \.self) { Text(Prefs.voiceName($0)).tag($0) }
                }
                HStack {
                    Text("Hear a sample").foregroundStyle(.secondary)
                    Spacer()
                    Button("Play") { preview(prefs.voice) }
                }
                Picker("Starting speed", selection: $prefs.defaultRate) {
                    ForEach(Speaker.rates, id: \.self) { Text(PillView.rateLabel($0)).tag($0) }
                }
            }
            Section("Shortcut") {
                HStack {
                    Text("Read, or stop")
                    Spacer()
                    Button(recording ? "Press the new keys..." : Prefs.shortcutLabel(code: prefs.keyCode, mods: prefs.keyMods)) {
                        recording ? stopRecording() : startRecording()
                    }
                    .frame(minWidth: 150)
                }
                Text("Use at least two of Control, Option, Shift and Command, plus a key. While she reads, Control+Option with Space and the arrow keys stay the controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("While she reads") {
                Toggle("Highlight the paragraph in the app you clicked in", isOn: $prefs.highlightOnScreen)
                Toggle("Scroll that app to keep up with her", isOn: $prefs.scrollAlong)
                    .disabled(!prefs.highlightOnScreen)
                Toggle("Small player (just the controls)", isOn: $prefs.miniPill)
                Toggle("Pause when a call starts (the microphone turns on)", isOn: $prefs.pauseForCalls)
            }
            Section {
                ForEach(prefs.pronunciations.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        TextField("Word", text: field(i, 0), prompt: Text("Word"))
                            .labelsHidden().frame(width: 100)
                        TextField("Say it as", text: field(i, 1), prompt: Text("Say it as"))
                            .labelsHidden()
                        Button("Before") { say(i, fixed: false) }
                            .help("Hear the word as written")
                        Button("After") { say(i, fixed: true) }
                            .help("Hear it the way you wrote it")
                        Button { prefs.pronunciations.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove")
                    }
                }
                HStack {
                    Button("Add a word") { prefs.pronunciations.append(["", ""]) }
                    Spacer()
                    Picker("Hear in", selection: $hearIn) {
                        ForEach(Prefs.voices, id: \.self) { Text(Prefs.voiceName($0)).tag($0) }
                    }
                    .frame(width: 170)
                }
            } header: {
                Text("Pronunciations")
            } footer: {
                Text("Write a word the way it sounds, for example SQL as sequel, or a name spelled out the way you say it. Press Before and After to compare. It applies everywhere she reads, and to audiobooks.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Open Earsay when the Mac starts", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in LoginItem.set(on) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onDisappear { stopRecording() }
    }

    private func field(_ i: Int, _ k: Int) -> Binding<String> {
        Binding(get: { i < prefs.pronunciations.count ? prefs.pronunciations[i][k] : "" },
                set: { v in if i < prefs.pronunciations.count { prefs.pronunciations[i][k] = v } })
    }

    private func say(_ i: Int, fixed: Bool) {
        guard i < prefs.pronunciations.count else { return }
        let word = prefs.pronunciations[i][0].trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        // Inside a short sentence: a word on its own makes this voice stumble (she said
        // "Dayji" as "Day-day-ji" alone, 18 Nov), and in a sentence is how she'll meet it.
        hear("Here it is, " + (fixed ? "" : TextPrep.asWritten) + word + ", in a sentence.", hearIn)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            let mods = Prefs.carbonMods(e.modifierFlags)
            let count = [controlKey, optionKey, shiftKey, cmdKey].filter { mods & $0 != 0 }.count
            guard count >= 2 else { NSSound.beep(); return nil }
            prefs.keyMods = mods
            prefs.keyCode = Int(e.keyCode)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Welcome (first launch)

struct WelcomeView: View {
    var tryIt: (String) -> Void
    var done: () -> Void
    var startStep = 0
    @State private var step = 0
    @State private var access = Selection.hasPermission(prompt: false)
    @State private var screen = ScreenText.hasPermission
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let sample = "Hello. I'm a voice that lives on your Mac. Highlight any text, press the shortcut, and I'll read it to you. Nothing you read ever leaves this computer."

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: permissions
                default: tryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Done" : "Continue") { step == 2 ? done() : (step += 1) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 440)
        .onAppear { step = startStep }
        .onReceive(tick) { _ in
            access = Selection.hasPermission(prompt: false)
            screen = ScreenText.hasPermission
        }
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Earsay").font(.system(size: 26, weight: .semibold))
            Text("A natural voice that reads anything on your Mac to you: highlighted text, a paragraph you click, whole books. It all happens on this Mac. No account, nothing sent anywhere.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two permissions").font(.system(size: 20, weight: .semibold))
            permissionRow(on: access, title: "Accessibility",
                          why: "To see the text you highlight, and the text of the app you click in.") {
                _ = Selection.hasPermission(prompt: true)
            }
            permissionRow(on: screen, title: "Screen Recording",
                          why: "Only for apps that won't share their text, and for Apple Books. Nothing is recorded or saved.") {
                ScreenText.askPermission()
            }
            Text("macOS may ask you to reopen Earsay after turning one on.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(on: Bool, title: String, why: String, ask: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20)).foregroundStyle(on ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !on { Button("Allow", action: ask) }
        }
    }

    private var tryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it").font(.system(size: 20, weight: .semibold))
            Text(Self.sample)
                .font(.system(size: 15, design: .serif)).lineSpacing(4)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            Button { tryIt(Self.sample) } label: { Label("Read this to me", systemImage: "play.fill") }
            Text("Anywhere on your Mac: highlight text and press \(Prefs.shortcutLabel(code: Prefs.shared.keyCode, mods: Prefs.shared.keyMods)). With nothing highlighted, the same keys let you click a paragraph to read from there. Press them again to stop.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Opens a SwiftUI view in a plain window, once; later calls bring it forward.
@MainActor
final class SimpleWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let make: () -> AnyView
    private let size: NSSize
    private let resizable: Bool
    /// Called when the window closes, by its red button or by code.
    var onClose: () -> Void = {}

    init(title: String, size: NSSize, resizable: Bool = false, make: @escaping () -> AnyView) {
        self.title = title; self.size = size; self.make = make; self.resizable = resizable
    }

    func show() {
        if window == nil {
            var style: NSWindow.StyleMask = [.titled, .closable]
            if resizable { style.insert(.resizable); style.insert(.miniaturizable) }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = title
            w.contentView = NSHostingView(rootView: make())
            w.center()
            w.setFrameAutosaveName(title)
            w.delegate = self
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
    var isOpen: Bool { window?.isVisible ?? false }
    func windowWillClose(_ notification: Notification) { onClose() }
}
