// Earsay: entry point.
// Highlight text anywhere, press Control+Option+R, Azelma reads it. Press again to stop.
// Nothing highlighted? The same key brings up a crosshair: click a paragraph to read from
// there, or drag a box to read what's inside it (read off the screen with Apple's Vision).
// While she reads (and only then): Control+Option plus Space = pause, Left/Right = 10 s,
// Up/Down = speed; add Shift for pages (Left/Right, Apple Books) and chapters (Up/Down).
// The keys are given back when the read ends.
import AppKit
import Carbon
import SwiftUI
import ReadAloudCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let speaker = Speaker()
    let pill = Pill()
    let picker = RegionPicker()
    let statusLine = NSMenuItem(title: "Loading voice...", action: nil, keyEquivalent: "")
    let permissionItem = NSMenuItem(title: "Allow Earsay to see highlighted text...", action: #selector(askPermission), keyEquivalent: "")
    var readKey: HotKey?
    var controlKeys: [HotKey] = []
    // The file being read now, if any (highlighted text and screen reads have none).
    var currentFile: String?
    var fileRequest = 0         // bumps on every file opened and every stop; late arrivals are dropped
    let carryOnItem = NSMenuItem(title: "", action: #selector(carryOn), keyEquivalent: "")
    lazy var books = BookReader(speaker: speaker)
    let reader = Reader()
    let booksSync = BooksSync()
    var readTitle = "Earsay"        // shown on the reader window
    var lastIndex = -1
    let media = MediaControls()
    let highlighter = Highlighter()
    let exporter = Exporter()
    let libraryModel = LibraryModel()
    lazy var libraryWindow = SimpleWindow(title: "Library", size: NSSize(width: 720, height: 560), resizable: true) {
        AnyView(LibraryView(model: self.libraryModel))
    }
    lazy var settingsWindow = SimpleWindow(title: "Earsay Settings", size: NSSize(width: 460, height: 680)) {
        AnyView(SettingsView(preview: { [weak self] v in self?.previewVoice(v) },
                             hear: { [weak self] text, voice in self?.hearWord(text, voice: voice) }))
    }
    lazy var welcomeWindow = SimpleWindow(title: "Welcome to Earsay", size: NSSize(width: 520, height: 440)) {
        AnyView(WelcomeView(tryIt: { [weak self] t in self?.readText(t, title: "Welcome") },
                            done: { [weak self] in self?.welcomeFinished() }))
    }
    let exportItem = NSMenuItem(title: "", action: #selector(cancelExport), keyEquivalent: "")
    let updateItem = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
    var updatePage: URL?
    var restoreVoice: String?           // after hearing a pronunciation in another voice
    var micWasOn = false                // for pausing when a call starts
    var iconStep = -1
    var finishingWelcome = false
    var afterWelcome: NSRunningApplication?   // the app you were in when the shortcut opened the welcome                   // the menu bar bars, so the image is only redrawn when it changes
    let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    // Sleep timer: stop at a time (fading out over the last few seconds), or at the end of
    // the chapter you're in.
    let sleepMenu = NSMenu()
    var sleepAt: Date?
    var sleepAfterChapter: Int?
    var sleepTicker: Timer?
    var lastActive = Date()             // for letting the voice go after a long idle spell
    static let idleUnload: TimeInterval = 15 * 60
    // Books you added yourself (PDFs, EPUBs) sync here. Store-bought books are locked and aren't.
    static let booksFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")


    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform",
                                           accessibilityDescription: "Earsay")

        let menu = NSMenu()
        menu.addItem(statusLine)
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        let read = NSMenuItem(title: "Read highlighted text  (Control+Option+R)", action: #selector(readPressed), keyEquivalent: "")
        read.target = self
        menu.addItem(read)
        let screen = NSMenuItem(title: "Read from the screen...", action: #selector(pickFromScreen), keyEquivalent: "")
        screen.target = self
        menu.addItem(screen)
        menu.addItem(.separator())
        let booksApp = NSMenuItem(title: "Open Apple Books", action: #selector(openAppleBooks), keyEquivalent: "")
        booksApp.target = self
        booksApp.toolTip = "Pick a book, go to your page, press Control+Option+R and click where to start"
        menu.addItem(booksApp)
        let library = NSMenuItem(title: "Library...", action: #selector(showLibrary), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)
        let open = NSMenuItem(title: "Open a file...", action: #selector(openFile), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        carryOnItem.target = self
        menu.addItem(carryOnItem)
        let readerItem = NSMenuItem(title: "Show the reader window", action: #selector(toggleReader), keyEquivalent: "")
        readerItem.target = self
        menu.addItem(readerItem)
        let sleepItem = NSMenuItem(title: "Sleep timer", action: nil, keyEquivalent: "")
        for (title, tag) in [("Off", 0), ("15 minutes", 15), ("30 minutes", 30), ("45 minutes", 45),
                             ("1 hour", 60), ("End of this chapter", -1)] {
            let i = NSMenuItem(title: title, action: #selector(sleepPicked(_:)), keyEquivalent: "")
            i.target = self
            i.tag = tag
            sleepMenu.addItem(i)
        }
        sleepItem.submenu = sleepMenu
        menu.addItem(sleepItem)
        let export = NSMenuItem(title: "Export as an audiobook...", action: #selector(exportBook), keyEquivalent: "")
        export.target = self
        menu.addItem(export)
        exportItem.target = self
        exportItem.isHidden = true
        menu.addItem(exportItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let welcome = NSMenuItem(title: "Welcome guide", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Quit Earsay",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        refreshPermissionItem()

        // The pill follows the speaker: show each sentence as it starts, fade at the end.
        speaker.onSentence = { [weak self] sentence, index, total in
            guard let self else { return }
            // A jump backwards or a fresh read: the reader must rebuild its page.
            if index < self.lastIndex - 1 || index == 0 { self.reader.reset() }
            self.lastIndex = index
            self.pill.show(sentence: sentence.text, index: index, total: total)
            self.reader.update(speaker: self.speaker, title: self.readTitle)
            if self.booksSync.active { self.followInBooks(index) }
            if self.highlighter.active { self.followOnScreen(index) }
            self.pill.model.paused = self.speaker.paused
            self.pill.model.rate = self.speaker.rate
            self.pill.model.bookMode = self.books.active
            self.pill.model.hasChapters = !self.books.active && self.speaker.chapterIndex != nil
            self.pill.model.caption = self.caption(index: index, total: total)
            if let file = self.currentFile { Bookmarks.save(file, index: index, total: total) }
            self.controlsOn()
            self.lastActive = Date()
            if self.statusLine.title != "Ready (Azelma)" && self.speaker.isLoaded { self.statusLine.title = "Ready (Azelma)" }
            self.media.enable()
            self.updateNowPlaying()
            // Sleep timer set to the end of a chapter: a new chapter has started, so stop.
            if let ch = self.sleepAfterChapter, let now = self.speaker.chapterIndex, now != ch {
                Log.write("sleep timer: end of chapter, stopping")
                self.clearSleep()
                self.stopReading()
            }
        }
        speaker.onFinished = { [weak self] in
            guard let self else { return }
            if let file = self.currentFile { Bookmarks.clear(file); Bookmarks.finished(file) }   // finished: next time starts fresh
            self.highlighter.end()
            self.setIcon(level: nil)
            self.currentFile = nil
            self.books.end()
            self.booksSync.end()
            self.pill.finish()
            self.restoreVoiceIfNeeded()
            self.controlsOff()
            self.media.disable()
            self.lastActive = Date()
            if self.sleepAfterChapter != nil { self.clearSleep() }   // the read ended first
        }
        pill.model.onBack = { [weak self] in self?.speaker.back() }
        pill.model.onSkip = { [weak self] in self?.speaker.skip() }
        pill.model.onPlayPause = { [weak self] in self?.pauseToggle() }
        pill.model.onSpeed = { [weak self] in self?.speed(1, wrap: true) }
        highlighter.onOffScreen = { [weak self] off in withAnimation(.easeOut(duration: 0.25)) { self?.pill.model.placeOffScreen = off } }
        pill.model.onFindPlace = { [weak self] in self?.highlighter.scrollToPlace() }
        pill.model.onSpeedMenu = { [weak self] in self?.speedMenu() }
        pill.model.onPrevChapter = { [weak self] in self?.chapter(-1) }
        pill.model.onNextChapter = { [weak self] in self?.chapter(1) }
        pill.model.onChapterList = { [weak self] in self?.showChapterList() }
        pill.model.onPrevPage = { [weak self] in self?.page(-1) }
        pill.model.onNextPage = { [weak self] in self?.page(1) }
        books.onStatus = { [weak self] text in self?.pill.model.text = text }
        books.highlighter = highlighter
        pill.model.onReader = { [weak self] in self?.toggleReader() }
        reader.model.onTap = { [weak self] p in self?.speaker.goToParagraph(p) }
        reader.model.onChapter = { [weak self] c in self?.speaker.goToChapter(c) }
        reader.model.onPause = { [weak self] in self?.pauseToggle() }
        reader.model.onBack = { [weak self] in self?.speaker.back() }
        reader.model.onForward = { [weak self] in self?.speaker.skip() }
        pill.model.onClose = { [weak self] in Log.write("pill: stop"); self?.stopReading() }
        media.onToggle = { [weak self] in self?.pauseToggle() }
        media.onPlay = { [weak self] in if self?.speaker.paused == true { self?.pauseToggle() } }
        media.onPause = { [weak self] in if self?.speaker.paused == false { self?.pauseToggle() } }
        media.onBack = { [weak self] in self?.speaker.back() }
        media.onForward = { [weak self] in self?.speaker.skip() }
        LoginItem.setUpOnce()
        applyPrefs()
        speaker.onLevel = { [weak self] l in
            guard let self, self.speaker.inProgress else { return }
            self.pill.level.level = self.speaker.paused ? 0 : l
            self.setIcon(level: self.speaker.paused ? 0 : l)
        }
        libraryModel.onOpen = { [weak self] path in self?.libraryWindow.close(); self?.read(file: path, resume: true) }
        libraryModel.onAdd = { [weak self] in self?.libraryWindow.close(); self?.openFile() }
        exporter.isBusy = { [weak self] in self?.speaker.inProgress ?? false }
        exporter.onProgress = { [weak self] text in
            self?.exportItem.title = (text ?? "") + "   (click to stop)"
            self?.exportItem.isHidden = text == nil
        }
        if let button = statusItem.button {
            let drop = DropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onFile = { [weak self] path in self?.read(file: path, resume: true) }
            button.addSubview(drop)
        }
        // First use: the welcome comes first. It opens once by itself at the very first launch;
        // until it's been seen through (Done or closed), the shortcut opens it too, and Done then
        // carries on with what you pressed the shortcut for (Deji, 17 Nov).
        welcomeWindow.onClose = { [weak self] in self?.welcomeFinished() }
        if !Prefs.shared.welcomeDone && !UserDefaults.standard.bool(forKey: "welcomeAutoShown") {
            UserDefaults.standard.set(true, forKey: "welcomeAutoShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.welcomeWindow.show() }
        }
        // Once a minute: let the voice go after 15 idle minutes, to give the memory back.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.speaker.inProgress, self.speaker.isLoaded,
                      Date().timeIntervalSince(self.lastActive) > Self.idleUnload else { return }
                self.speaker.unloadVoice()
                self.statusLine.title = "Ready (Azelma, resting)"
            }
        }

        // A call starts (the microphone turns on) while she reads: pause. Only a change counts,
        // so an app that keeps the microphone open all the time doesn't stop every read.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.speaker.inProgress else { self?.micWasOn = false; return }
                let on = Microphone.inUse()
                if on, !self.micWasOn, Prefs.shared.pauseForCalls, !self.speaker.paused {
                    Log.write("paused: the microphone turned on")
                    self.pauseToggle()
                }
                self.micWasOn = on
            }
        }
        // New version? Check now and once a day.
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdate() }
        }

        Log.write("app started; accessibility permission: \(Selection.hasPermission(prompt: false))")
        registerReadKey()

        // Hand-off: other programs on this Mac (the read-aloud command, Claude) can ask
        // the app to read a file by posting a system-wide message with the file's path.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.readfile"), object: nil, queue: .main
        ) { [weak self] note in
            guard let path = note.object as? String else { return }
            Log.write("hand-off: a file")
            self?.read(file: path, resume: false, remember: false)   // sent by Claude: not your reading
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.stop"), object: nil, queue: .main
        ) { [weak self] _ in self?.stopReading() }
        // Developer commands below save screen text and screenshots to local files, so they
        // are off unless switched on: defaults write io.autimized.readaloud debugCommands -bool true
        if UserDefaults.standard.bool(forKey: "debugCommands") {
        Log.write("debug commands on")
        // Debug only: write an app's accessibility tree to a local file (never sent anywhere).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.axdump"), object: nil, queue: .main
        ) { note in
            guard let id = note.object as? String else { return }
            AXText.dump(bundleID: id, to: NSHomeDirectory() + "/.local/share/read-aloud/axdump.txt")
        }
        // Debug only: let the voice go now, as if 15 idle minutes had passed.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.unload"), object: nil, queue: .main
        ) { [weak self] _ in self?.speaker.unloadVoice() }
        // Debug only: show the on-screen highlight without reading ("bundleID|exact sentence|paragraph|line").
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.hltest"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let parts = (note.object as? String)?.components(separatedBy: "|"), parts.count == 4,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: parts[0]).first,
                  let el = AXText.find(pid: app.processIdentifier, phrase: parts[1]), let f = AXText.frame(el),
                  let read = AXText.read(from: el, point: CGPoint(x: f.midX, y: f.midY), pid: app.processIdentifier) else {
                Log.write("hltest: not found"); return
            }
            self.highlighter.begin(read, window: ScreenText.window(at: CGPoint(x: f.midX, y: f.midY))?.id)
            self.highlighter.follow(paragraph: Int(parts[2]) ?? 0, line: Int(parts[3]) ?? 0)
            Log.write("hltest: \(read.paragraphs.count) paragraphs")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.hlend"), object: nil, queue: .main
        ) { [weak self] _ in self?.highlighter.end() }
        // Debug only: open or close a window ("library", "settings", "welcome", "close"), or export a file.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.window"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            switch note.object as? String {
            case "library": self.showLibrary()
            case "settings": self.showSettings()
            case "welcome": self.showWelcome()
            default: self.libraryWindow.close(); self.settingsWindow.close(); self.welcomeWindow.close()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.export"), object: nil, queue: .main
        ) { [weak self] note in
            if let path = note.object as? String { self?.exporter.reveal = false; self?.exporter.export(path: path) }
        }
        // Debug only: draw a window or the pill into ~/.local/share/read-aloud/render-<name>.png,
        // off screen (nothing appears). Names: library, settings, welcome0/1/2, pill, mini.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.render"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, var name = note.object as? String else { return }
            self.libraryModel.refresh()
            let pm = PillModel()
            pm.text = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."
            pm.index = 40; pm.total = 100; pm.hasChapters = true; pm.caption = "Chapter 1 of 61  ·  40%  ·  6 h 12 min left"
            pm.mini = name == "mini"
            let lv = LevelModel(); lv.level = 0.6
            // "pill|<text>|<caption>|<index>|<total>|<level>|<file name>": any sentence, for demo videos.
            if name.hasPrefix("pill|") {
                let p = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                pm.text = p.count > 1 ? p[1] : pm.text
                pm.caption = p.count > 2 ? p[2] : ""
                pm.hasChapters = false
                pm.index = p.count > 3 ? Int(p[3]) ?? 0 : 0
                pm.total = p.count > 4 ? Int(p[4]) ?? 1 : 1
                lv.level = p.count > 5 ? Float(p[5]) ?? 0.6 : 0.6
                name = p.count > 6 ? p[6] : "pill-custom"
            }
            let view: AnyView
            switch name {
            case "library": view = AnyView(LibraryView(model: self.libraryModel).frame(width: 720, height: 560))
            case "settings": view = AnyView(SettingsView(preview: { _ in }))
            case "welcome0", "welcome1", "welcome2": view = AnyView(WelcomeView(tryIt: { _ in }, done: {}, startStep: Int(String(name.last!))!))
            default: view = AnyView(PillView(model: pm, level: lv).background(Color(nsColor: .windowBackgroundColor)))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.appearance = NSApp.effectiveAppearance
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/.local/share/read-aloud/render-\(name).png"))
                Log.write("render: \(name)")
            }
        }
        // Debug only: screenshot of the main screen to ~/.local/share/read-aloud/shot.png (local only).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.shot"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard let f = NSScreen.screens.first?.frame,
                      let (img, _, _) = try? await ScreenText.capture(CGRect(x: 0, y: 0, width: f.width, height: f.height), includeOurs: true) else {
                    Log.write("shot: failed"); return
                }
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/.local/share/read-aloud/shot.png"))
                Log.write("shot: saved")
            }
        }
        // Debug only: test switches. "silent on|off" plays at zero volume; "sleep <seconds>" or
        // "sleep chapter" starts a short sleep timer; "hear <voice>|<text>" is the pronunciation
        // preview; "update <owner/repo>" runs the update check against another repository.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.test"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let parts = (note.object as? String)?.split(separator: " ", maxSplits: 1).map(String.init),
                  let cmd = parts.first else { return }
            let arg = parts.count > 1 ? parts[1] : ""
            Log.write("test: \(cmd) \(cmd == "hear" ? "" : arg)")
            switch cmd {
            case "silent": self.speaker.testSilent = arg == "on"
            case "sleep":
                self.clearSleep()
                if arg == "chapter", let ch = self.speaker.chapterIndex {
                    self.sleepAfterChapter = ch; Log.write("sleep timer: end of chapter \(ch + 1)")
                } else if let secs = Double(arg) {
                    self.sleepAt = Date().addingTimeInterval(secs)
                    self.sleepTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.sleepTick() }
                    }
                }
            case "hear":
                let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                if p.count == 2 { self.hearWord(p[1], voice: p[0]) }
            case "update":
                Updates.check(repo: arg) { [weak self] version, page in
                    Log.write("update available: \(version)")
                    self?.updatePage = page
                    self?.updateItem.title = "Update available: version \(version)"
                    self?.updateItem.isHidden = false
                }
            default: break
            }
        }
        // Debug only: pretend to click on a phrase ("bundleID|phrase", or "bundleID|phrase|real" to
        // use the screen's own hit test at that spot) and save what she'd read, the way a real
        // click does it, including the check against the screen. First line says how it started.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.autimized.readaloud.axtest"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let parts = (note.object as? String)?.components(separatedBy: "|"), parts.count >= 2,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: parts[0]).first else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                var out = "(nothing)"
                if parts[1] == "@auto" { out = await self.autoTest(pid: pid, count: Int(parts.count > 2 ? parts[2] : "") ?? 12) }
                else if let el = AXText.find(pid: pid, phrase: parts[1]), let f = AXText.frame(el) {
                    let pt = CGPoint(x: f.midX, y: f.midY)
                    let win = ScreenText.window(at: pt)
                    let hint = win.map { w in Task { await self.screenHint(click: pt, window: w.frame) } }
                    let h = await hint?.value ?? []
                    let r = parts.count > 2 ? AXText.read(at: pt, pid: pid, hint: h) : AXText.read(from: el, point: pt, pid: pid, hint: h)
                    let how = r?.start.map { "trusted=\($0.trusted) moved=\($0.moved) hintWords=\($0.hintWords)" } ?? "no start info"
                    out = "clicked at \(Int(pt.x)),\(Int(pt.y)) \(how)\n\n" + (r?.text ?? "(no text at that point)")
                } else { out = "phrase not found" }
                try? out.write(toFile: NSHomeDirectory() + "/.local/share/read-aloud/axtest.txt", atomically: true, encoding: .utf8)
                Log.write("axtest: done")
            }
        }
        }

        Task {
            do {
                try await speaker.loadVoiceIfNeeded()
                await MainActor.run { self.statusLine.title = "Ready (Azelma)" }
                // Warm up the screen reader too: Vision's first read sets itself up (up to a
                // minute the very first time). Do it now on a tiny picture, out of sight.
                let w = Date()
                if let img = Self.warmUpImage() {
                    _ = try? await Task.detached(priority: .utility) { try ScreenOCR.lines(in: img) }.value
                }
                Log.write("screen reader warmed up in \(Log.secs(since: w))")
            } catch {
                Log.write("voice failed to load: \(error)")
                await MainActor.run { self.statusLine.title = "Voice failed to load" }
            }
        }
    }

    // Show the "Allow..." menu item only while the permission is missing.
    func refreshPermissionItem() {
        permissionItem.isHidden = Selection.hasPermission(prompt: false)
    }

    @objc func askPermission() {
        _ = Selection.hasPermission(prompt: true)
    }

    // One key does both: talking -> stop; quiet -> read the highlighted text.
    @objc func readPressed() {
        if picker.isActive { picker.cancel(); return }
        // Not through the welcome yet: show it first, and carry on after Done.
        if !Prefs.shared.welcomeDone || welcomeWindow.isOpen {
            afterWelcome = NSWorkspace.shared.frontmostApplication
            Log.write("shortcut: welcome first")
            welcomeWindow.show()
            return
        }
        if speaker.isSpeaking {
            Log.write("shortcut: stop")
            stopReading()
            return
        }
        guard Selection.hasPermission(prompt: true) else {
            Log.write("shortcut: no accessibility permission yet")
            refreshPermissionItem()
            return
        }
        refreshPermissionItem()
        Task { @MainActor in
            guard let (text, how) = await Selection.grab() else {
                // Apple Books in front: start at the top of your page, no crosshair needed.
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BookReader.booksBundleID {
                    Log.write("shortcut: Apple Books in front, finding your place")
                    await startFromBooks()
                    return
                }
                Log.write("shortcut: nothing highlighted, opening the crosshair")
                pickFromScreen()
                return
            }
            // Log only the size, never the text itself.
            Log.write("shortcut: read \(text.count) characters (via \(how))")
            booksSync.end()
            highlighter.end()
            currentFile = nil
            readTitle = "Highlighted text"
            speaker.speak(text)
        }
    }


    // MARK: - Reading from the screen

    @objc func pickFromScreen() {
        if speaker.isSpeaking { stopReading() }
        guard ScreenText.hasPermission else {
            Log.write("screen: no Screen Recording permission yet, asking")
            ScreenText.askPermission()
            NSSound(named: "Tink")?.play()
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            AXText.wake(pid: front.processIdentifier)    // so its text is ready by the click
        }
        // The crosshair brings this app forward (it needs the keyboard for Esc), which would
        // pull our own windows (welcome, settings, library, reader) up under the dim, where
        // they can't be used (17 Nov). Tuck them away while you pick, then put them back
        // behind, where they were.
        let tucked = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        tucked.forEach { $0.orderOut(nil) }
        picker.pick { [weak self] area in
            tucked.forEach { $0.orderBack(nil) }
            guard let self, let area else { Log.write("screen: cancelled"); return }
            Task { @MainActor in await self.readScreen(area) }
        }
    }

    func readScreen(_ area: NSRect) async {
        // AppKit measures from the bottom of the main screen; the capture side from the top.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let isClick = area.width == 0
        let click = CGPoint(x: area.minX, y: top - area.minY)
        let target: CGRect
        if isClick {
            guard let window = ScreenText.window(at: click) else {
                Log.write("screen: no window under the click"); NSSound(named: "Tink")?.play(); return
            }
            // A click in Apple Books: hands-free book mode (reads, turns the page, carries on).
            if BookReader.isBooks(pid: window.pid) {
                currentFile = nil
                readTitle = "Apple Books"
                await books.begin(window: window.id, pid: window.pid, click: click)
                return
            }
            // First ask the app itself for its text (whole message, even the part scrolled out
            // of view, no buttons). Only if it gives nothing, read the pixels.
            AXText.wake(pid: window.pid)
            // The app's tree can still hold the tab you just left (or not be built yet for the
            // new one). Take its text only if it matches what is on screen at the click;
            // otherwise give it a moment, ask again once, and failing that read the picture.
            var ax: AXText.Read?
            var how = "no text"
            for attempt in 0...1 {
                let hint = await screenHint(click: click, window: window.frame)
                if let r = AXText.read(at: click, pid: window.pid, hint: hint) {
                    if r.start?.trusted ?? true {
                        ax = r
                        how = r.start == nil ? "text view" : (r.start!.moved ? "moved by screen match" : "geometry")
                        break
                    }
                    how = "mismatch"
                } else { how = "no text" }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            }
            if let ax {
                Log.write("screen: click, start by \(how), read the app's own text (\(ax.text.count) characters, \(ax.paragraphs.count) paragraphs to follow)")
                currentFile = nil
                readTitle = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "Screen"
                speaker.speak(ax.text)
                highlighter.begin(ax, window: window.id)
                return
            }
            Log.write("screen: app text \(how == "mismatch" ? "start not confirmed by the screen" : "not usable"), picture read")
            highlighter.end()
            target = window.frame
        } else {
            target = CGRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height)
        }
        do {
            let t = Date()
            let (image, got, scale) = try await ScreenText.capture(target)
            let lines = try await Task.detached(priority: .userInitiated) { try ScreenOCR.lines(in: image) }.value
            let text = isClick
                ? OCRLayout.text(from: lines, startingAt: (click.x - got.minX) * scale, (click.y - got.minY) * scale)
                : OCRLayout.text(from: lines)
            // Log only sizes, never the text.
            Log.write("screen: \(isClick ? "click" : "box"), \(lines.count) lines read in \(Log.secs(since: t))")
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound(named: "Tink")?.play(); return
            }
            currentFile = nil
            speaker.speak(text)
        } catch {
            Log.write("screen: failed: \(error)")
            NSSound(named: "Tink")?.play()
        }
    }

    // What the screen shows at the click: OCR a narrow strip of the window (about 18 pt
    // either side), take the line nearest the click (one holding the click's column wins),
    // and return its distinctive words. Empty if there's nothing to go on. AXText uses it to
    // find the block she should start at. Never logged.
    func screenHint(click: CGPoint, window: CGRect) async -> Set<String> {
        guard ScreenText.hasPermission else { return [] }
        let strip = CGRect(x: window.minX, y: click.y - 18, width: window.width, height: 36).intersection(window)
        guard !strip.isNull,
              let (image, got, scale) = try? await ScreenText.capture(strip),
              let lines = try? await Task.detached(priority: .userInitiated, operation: { try ScreenOCR.lines(in: image) }).value
        else { return [] }
        func miss(_ l: OCRLine) -> CGFloat {
            let midY = got.minY + CGFloat(l.y + l.h / 2) / scale
            let x0 = got.minX + CGFloat(l.x) / scale, x1 = got.minX + CGFloat(l.x + l.w) / scale
            return abs(midY - click.y) + (click.x >= x0 - 6 && click.x <= x1 + 6 ? 0 : 100)
        }
        guard let line = lines.min(by: { miss($0) < miss($1) }) else { return [] }
        return AXText.distinctiveWords(line.text)
    }

    // Debug only (axtest "bundleID|@auto|N"): click N visible pieces of text in the app's front
    // window with the real hit test, the old way and the new way, and say whether each read
    // starts in the paragraph that holds the piece. Writes counts and the first 5 words only.
    func autoTest(pid: pid_t, count: Int) async -> String {
        guard let w = ScreenText.frontWindow(of: pid) else { return "no visible window" }
        var found: [(el: AXUIElement, v: String, f: CGRect)] = []
        func walk(_ e: AXUIElement, _ d: Int) {
            guard d < 60 else { return }
            if AXText.role(e) == "AXStaticText", let v = AXText.attr(e, kAXValueAttribute) as? String, v.count >= 25,
               let f = AXText.frame(e), f.width > 40, f.height > 5, f.height < 120,
               w.frame.insetBy(dx: 30, dy: 60).contains(CGPoint(x: f.midX, y: f.midY)) { found.append((e, v, f)) }
            for c in AXText.children(e) { walk(c, d + 1) }
        }
        if let win = AXText.attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) { walk(win as! AXUIElement, 0) }
        found.sort { $0.f.midY < $1.f.midY }
        guard !found.isEmpty else { return "no visible text found" }
        let step = max(1, found.count / max(count, 1))
        var lines = ["\(found.count) visible pieces, testing every \(step)th"]
        var oldOK = [0, 0, 0], newOK = [0, 0, 0], n = 0
        let names = ["middle", "bottom-left", "left margin"]
        for i in stride(from: 0, to: found.count, by: step) {
            let c = found[i]
            n += 1
            for k in 0..<3 {
                let pt = [CGPoint(x: c.f.midX, y: c.f.midY), CGPoint(x: c.f.minX + 6, y: c.f.maxY - 3),
                          CGPoint(x: c.f.minX - 14, y: c.f.midY)][k]
                let hint = await screenHint(click: pt, window: w.frame)
                func start(_ r: AXText.Read?) -> (ok: Bool, five: String) {
                    guard let r else { return (false, "(none)") }
                    let first = r.text.components(separatedBy: "\n\n").first ?? ""
                    return (first.contains(String(c.v.prefix(30))), r.text.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " "))
                }
                let o = start(AXText.read(at: pt, pid: pid, hint: [], legacy: true))
                let rn = AXText.read(at: pt, pid: pid, hint: hint)
                let nw = start(rn)
                if o.ok { oldOK[k] += 1 }; if nw.ok { newOK[k] += 1 }
                let how = rn?.start.map { $0.trusted ? ($0.moved ? "moved by screen" : "geometry") : "UNTRUSTED" } ?? "text view"
                if !o.ok || !nw.ok { lines.append("y=\(Int(c.f.midY)) \(names[k]) hint=\(hint.count) | before: \(o.ok ? "ok" : "WRONG") [\(o.five)] | after: \(nw.ok ? "ok" : "WRONG") [\(nw.five)] \(how)") }
            }
        }
        for k in 0..<3 { lines.append("\(names[k]): before \(oldOK[k])/\(n) right, after \(newOK[k])/\(n) right") }
        return lines.joined(separator: "\n")
    }

    static func warmUpImage() -> CGImage? {
        let image = NSImage(size: NSSize(width: 240, height: 60), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            ("Ready to read" as NSString).draw(at: NSPoint(x: 10, y: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Apple Books

    /// Your own book open in Books: read the real file from this page (full audiobook).
    /// A bought book: read off the screen and turn the pages.
    func startFromBooks() async {
        guard ScreenText.hasPermission else {
            Log.write("screen: no Screen Recording permission yet, asking")
            ScreenText.askPermission(); NSSound(named: "Tink")?.play(); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let w = ScreenText.frontWindow(of: app.processIdentifier) else { pickFromScreen(); return }
        let t = Date()
        guard let page = await books.peek(window: w.id) else { NSSound(named: "Tink")?.play(); return }
        let folder = Self.booksFolder
        let found = await Task.detached(priority: .userInitiated) {
            BookMatcher.find(pageText: page, windowTitle: w.title, folder: folder)
        }.value
        if let found, let raw = BookMatcher.rawText(found.path) {
            let prefix = String(raw.prefix(found.offset))
            let before = await Task.detached(priority: .userInitiated) { Speaker.prepareChapters(prefix).0.count }.value
            Log.write("books: it's one of your files, found the page in \(Log.secs(since: t))")
            read(file: found.path, resume: false, startAt: max(0, before - 1))
            booksSync.begin(window: w.id, pid: app.processIdentifier, path: found.path, pageText: page)
        } else {
            Log.write("books: not one of your files (a bought book?), turning pages instead")
            currentFile = nil
            readTitle = "Apple Books"
            await books.begin(window: w.id, pid: app.processIdentifier, click: nil)
        }
    }

    // MARK: - Files and books

    @objc func openFile() {
        booksSync.end()
        let previous = NSWorkspace.shared.frontmostApplication
        let panel = NSOpenPanel()
        // Books keeps EPUBs as folders, so folders must be pickable; the delegate below allows
        // only the ones we can read (files of our types, and folders ending in .epub).
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = pickerFilter
        panel.allowsMultipleSelection = false
        panel.message = "Pick something for Azelma to read"
        if FileManager.default.fileExists(atPath: Self.booksFolder.path) { panel.directoryURL = Self.booksFolder }
        NSApp.activate()
        let answer = panel.runModal()
        previous?.activate()
        guard answer == .OK, let url = panel.url else { return }
        read(file: url.path, resume: true)
    }

    let pickerFilter = OpenFilter()

    @objc func carryOn() {
        if let last = Bookmarks.last { read(file: last, resume: true) }
    }

    @objc func openAppleBooks() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Books.app"))
    }

    /// Read a file. With resume, carry on from where you stopped last time.
    func read(file path: String, resume: Bool, remember: Bool = true, startAt: Int? = nil) {
        if speaker.isSpeaking { stopReading() }
        fileRequest += 1
        let request = fileRequest
        let t = Date()
        Task { @MainActor in
            do {
                try await Self.downloadIfInCloud(URL(fileURLWithPath: path))
                guard request == fileRequest else { Log.write("file: arrived after a stop, ignored"); return }
                let text = try await Task.detached(priority: .userInitiated) {
                    try BookText.load(URL(fileURLWithPath: path))
                }.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Log.write("file: no text found (a scanned PDF has pictures, not text)")
                    NSSound(named: "Tink")?.play(); return
                }
                guard request == fileRequest else { return }
                let from = startAt ?? (resume ? (Bookmarks.position(path) ?? 0) : 0)
                Log.write("file: \((path as NSString).pathExtension), \(text.count) characters, opened in \(Log.secs(since: t))")
                currentFile = remember ? path : nil
                if remember { Bookmarks.last = path; Bookmarks.opened(path) }
                highlighter.end()
                readTitle = Self.niceName(path)
                reader.reset()
                if Reader.wantsOpen { reader.show() }
                speaker.speak(text, from: from, skipFrontMatter: remember && startAt == nil)
            } catch {
                Log.write("file: could not open: \(error)")
                NSSound(named: "Tink")?.play()
            }
        }
    }

    /// A file that lives only in iCloud (not on this Mac yet): fetch it before opening.
    static func downloadIfInCloud(_ url: URL) async throws {
        func status() -> URLUbiquitousItemDownloadingStatus? {
            var u = url
            u.removeAllCachedResourceValues()
            return try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        }
        guard let s = status(), s != .current else { return }        // not iCloud, or already here
        Log.write("file: downloading from iCloud")
        // Reading a file that isn't here makes macOS fetch it from iCloud first.
        let t = Date()
        let fetch = Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .mappedIfSafe).count }
        // Give up after a minute (no connection, or macOS waiting on a permission answer).
        let limit = Task { try await Task.sleep(nanoseconds: 60_000_000_000); fetch.cancel() }
        defer { limit.cancel() }
        while status() != .current {
            if fetch.isCancelled || Date().timeIntervalSince(t) > 60 {
                Log.write("file: iCloud download didn't finish within a minute")
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        Log.write("file: downloaded in \(Log.secs(since: t))")
    }

    // Refresh the "Carry on" items each time the menu opens.
    // Keep Books on the page she's reading: where is this sentence inside its paragraph?
    func followInBooks(_ index: Int) {
        let all = speaker.allSentences
        guard index < all.count else { return }
        let p = all[index].paragraph
        guard p < speaker.paragraphs.count else { return }
        var first = index
        while first > 0 && all[first - 1].paragraph == p { first -= 1 }
        var last = index
        while last + 1 < all.count && all[last + 1].paragraph == p { last += 1 }
        let fraction = Double(index - first) / Double(last - first + 1)
        booksSync.follow(paragraph: speaker.paragraphs[p], paragraphID: p, fraction: fraction)
    }

    @objc func toggleReader() {
        reader.toggle()
        if reader.isOpen && speaker.isSpeaking { reader.reset(); reader.update(speaker: speaker, title: readTitle) }
    }

    // A file name made readable: no extension, no underscores or dashes.
    static func niceName(_ path: String) -> String {
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return name.trimmingCharacters(in: .whitespaces)
    }

    // Show "Carry on" only when you stopped partway through a file.
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = LoginItem.isOn ? .on : .off
        let chapters = speaker.inProgress && speaker.chapterIndex != nil
        for i in sleepMenu.items {
            switch i.tag {
            case 0: i.state = (sleepAt == nil && sleepAfterChapter == nil) ? .on : .off
            case -1: i.state = sleepAfterChapter != nil ? .on : .off; i.isHidden = !chapters
            default: i.state = .off
            }
        }
        if let at = sleepAt { sleepMenu.items.first?.title = "Off  (stops in \(Self.minutesLeft(at)))" }
        else { sleepMenu.items.first?.title = "Off" }
        guard let last = Bookmarks.last, FileManager.default.fileExists(atPath: last),
              let pct = Bookmarks.percent(last) else { carryOnItem.isHidden = true; return }
        var name = (last as NSString).deletingPathExtension.components(separatedBy: "/").last ?? ""
        name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if name.count > 40 { name = String(name.prefix(38)) + "..." }
        carryOnItem.title = "Carry on: \(name)  (\(pct)%)"
        carryOnItem.isHidden = false
    }

    // The small line under the sentence: chapter, how far, time left (reads of 2 minutes or more).
    func caption(index: Int, total: Int) -> String {
        if books.active { return "Apple Books, turning pages for you" }
        var parts: [String] = []
        if let ch = speaker.chapterIndex { parts.append("Chapter \(ch + 1) of \(speaker.chapterStarts.count)") }
        // Shown when the whole read is 2 minutes or more at the current speed; short texts
        // you can see the end of. Measured on the whole read, so it stays on to the end.
        if speaker.secondsTotal() >= 120 { parts.append(Self.timeCaption(index: index, total: total, left: speaker.secondsLeft())) }
        if let at = sleepAt { parts.append("sleep in " + Self.minutesLeft(at)) }
        else if sleepAfterChapter != nil { parts.append("sleep at chapter end") }
        return parts.joined(separator: "  ·  ")
    }

    static func timeCaption(index: Int, total: Int, left: Double) -> String {
        let pct = Int(Double(index) / Double(total) * 100)
        let mins = Int(left / 60)
        let time = mins >= 60 ? "\(mins / 60) h \(mins % 60) min" : (mins >= 1 ? "\(mins) min" : "under a minute")
        return "\(pct)%  ·  \(time) left"
    }

    @objc func toggleLogin() { LoginItem.set(!LoginItem.isOn) }

    // MARK: - Settings, library, export, welcome

    func applyPrefs() {
        let p = Prefs.shared
        speaker.setRate(p.defaultRate)
        pill.setMini(p.miniPill)
        if Speaker.voiceName != p.voice { speaker.setVoice(p.voice) }
        p.onVoice = { [weak self] v in self?.speaker.setVoice(v) }
        p.onShortcut = { [weak self] in self?.registerReadKey() }
        p.onLook = { [weak self] in
            guard let self else { return }
            self.pill.setMini(Prefs.shared.miniPill)
            if self.speaker.inProgress { self.followOnScreen(self.speaker.playingIndex) }
        }
    }

    func registerReadKey() {
        readKey?.unregister()
        let p = Prefs.shared
        readKey = HotKey(id: 1, keyCode: p.keyCode, modifiers: p.keyMods) { [weak self] in self?.readPressed() }
        let label = Prefs.shortcutLabel(code: p.keyCode, mods: p.keyMods)
        statusItem.menu?.items.first { $0.action == #selector(readPressed) }?.title = "Read highlighted text  (\(label))"
        Log.write("shortcut: \(label)")
    }

    @objc func showSettings() { settingsWindow.show() }
    @objc func showWelcome() { welcomeWindow.show() }
    func welcomeFinished() {
        guard !finishingWelcome else { return }        // closing the window calls this again
        finishingWelcome = true
        defer { finishingWelcome = false }
        Prefs.shared.welcomeDone = true
        if welcomeWindow.isOpen { welcomeWindow.close() }
        // Came from the shortcut: go back to that app and carry on (crosshair or highlighted text).
        if let app = afterWelcome, app.processIdentifier != getpid() {
            afterWelcome = nil
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.readPressed() }
        }
    }
    @objc func showLibrary() { libraryModel.refresh(); libraryWindow.show() }

    func previewVoice(_ v: String) {
        readText("Hi, I'm \(Prefs.voiceName(v)). This is how I'd sound reading your books, articles and messages to you.", title: "Voice sample")
    }

    /// Say a word from Settings > Pronunciations, in the voice picked there. Your own voice
    /// comes back when it's done.
    func hearWord(_ text: String, voice: String) {
        if speaker.inProgress { stopReading() }
        if voice != Speaker.voiceName {
            restoreVoice = Speaker.voiceName
            speaker.setVoice(voice)
        }
        readText(text, title: "Pronunciation")
    }

    func restoreVoiceIfNeeded() {
        guard let v = restoreVoice else { return }
        restoreVoice = nil
        speaker.setVoice(v)
    }

    func checkForUpdate() {
        Updates.check { [weak self] version, page in
            guard let self else { return }
            Log.write("update available: \(version)")
            self.updatePage = page
            self.updateItem.title = "Update available: version \(version)"
            self.updateItem.isHidden = false
        }
    }

    @objc func openUpdate() {
        if let page = updatePage { NSWorkspace.shared.open(page) }
    }

    /// Read some text that isn't from a file or the screen (a sample, the welcome).
    func readText(_ text: String, title: String) {
        if speaker.isSpeaking { stopReading() }
        booksSync.end()
        highlighter.end()
        currentFile = nil
        readTitle = title
        speaker.speak(text)
    }

    @objc func exportBook() {
        guard !exporter.running else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = pickerFilter
        panel.message = "Pick a book or file to turn into an audiobook"
        panel.prompt = "Export"
        if let last = Bookmarks.last { panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent() }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Log.write("export: started")
        exporter.export(path: url.path)
    }

    @objc func cancelExport() { exporter.cancel() }

    // The highlight follows her: which paragraph, and which line inside it (list items and
    // table rows are lines; each line's last sentence is marked endsLine).
    func followOnScreen(_ index: Int) {
        let all = speaker.allSentences
        guard index < all.count else { return }
        let p = all[index].paragraph
        var first = index
        while first > 0 && all[first - 1].paragraph == p { first -= 1 }
        let line = all[first..<index].filter { $0.endsLine }.count
        highlighter.follow(paragraph: p, line: line)
    }

    // The menu bar icon: five bars that move with her voice while she reads.
    func setIcon(level: Float?) {
        guard let button = statusItem.button else { return }
        let step = level.map { Int(($0 * 6).rounded()) } ?? -1
        guard step != iconStep else { return }
        iconStep = step
        if level == nil {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Earsay")
            return
        }
        let l = CGFloat(step) / 6
        let shape: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.5]
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.black.setFill()
            for (i, k) in shape.enumerated() {
                let h = max(3, min(14, 14 * (l * k * 1.4 + 0.15)))
                let x = 2 + CGFloat(i) * 3.2
                NSBezierPath(roundedRect: NSRect(x: x, y: (r.height - h) / 2, width: 2, height: h), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        img.isTemplate = true
        button.image = img
    }

    // MARK: - Sleep timer

    @objc func sleepPicked(_ sender: NSMenuItem) {
        clearSleep()
        if sender.tag > 0 {
            sleepAt = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
            Log.write("sleep timer: \(sender.tag) min")
            sleepTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepTick() }
            }
        } else if sender.tag == -1, let ch = speaker.chapterIndex {
            sleepAfterChapter = ch
            Log.write("sleep timer: end of chapter \(ch + 1)")
        }
        updateCaption()
    }

    // Every second: fade her out over the last 8 seconds, then stop. Your place is kept.
    func sleepTick() {
        guard let at = sleepAt else { return }
        let left = at.timeIntervalSinceNow
        if left <= 0 {
            Log.write("sleep timer: time's up, stopping")
            clearSleep()
            if speaker.inProgress { stopReading() }
            return
        }
        if left < 8 && speaker.inProgress {
            if speaker.volume >= 1 { Log.write("sleep timer: fading out") }
            speaker.volume = Float(left / 8)
        }
        if Int(left) % 30 == 0 { updateCaption() }
    }

    func clearSleep() {
        sleepTicker?.invalidate()
        sleepTicker = nil
        sleepAt = nil
        sleepAfterChapter = nil
        speaker.volume = 1
        updateCaption()
    }

    static func minutesLeft(_ at: Date) -> String {
        let m = Int(ceil(at.timeIntervalSinceNow / 60))
        return m <= 1 ? "under a minute" : "\(m) min"
    }

    func updateCaption() {
        guard speaker.inProgress else { return }
        pill.model.caption = caption(index: speaker.playingIndex, total: speaker.sentenceCount)
    }

    func updateNowPlaying() {
        let ch = speaker.chapterIndex.flatMap { i -> String? in
            let t = speaker.chapterTitles(); return i < t.count ? t[i] : nil
        }
        media.update(title: readTitle, chapter: ch, paused: speaker.paused, rate: speaker.rate)
    }

    func stopReading() {
        Log.write("stop")
        fileRequest += 1
        books.end()
        booksSync.end()
        speaker.stop()
        pill.hide()
        controlsOff()
        media.disable()
        highlighter.end()
        setIcon(level: nil)
        restoreVoiceIfNeeded()
        lastActive = Date()
    }

    func pauseToggle() {
        pill.model.paused = speaker.togglePause()
        lastActive = Date()
        updateNowPlaying()
    }

    // Pages: only in Apple Books mode.
    func page(_ step: Int) {
        if books.active { books.jumpPage(by: step) } else { NSSound(named: "Tink")?.play() }
    }

    // Chapters: in Apple Books by flipping to the next heading; in files from the chapter list.
    func chapter(_ step: Int) {
        if books.active { books.jumpChapter(by: step) }
        else if !speaker.jumpChapter(by: step) { NSSound(named: "Tink")?.play() }
    }

    // A pop-up list of chapters by name at the pointer; the current one is ticked.
    func showChapterList() {
        let titles = speaker.chapterTitles()
        guard !titles.isEmpty else { return }
        let menu = NSMenu()
        let current = speaker.chapterIndex ?? -1
        for (i, title) in titles.enumerated() {
            let item = NSMenuItem(title: "\(i + 1).  \(title)", action: #selector(chapterPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: max(current, 0)), at: NSEvent.mouseLocation, in: nil)
    }

    @objc func chapterPicked(_ sender: NSMenuItem) {
        speaker.goToChapter(sender.tag)
    }

    // The pill's speed button: a list of every speed, a tick on the current one. A plain NSMenu
    // popped at the mouse (the pill never takes focus, so this opens without stealing it).
    func speedMenu() {
        let menu = NSMenu()
        var current: NSMenuItem?
        for r in Speaker.rates {
            let item = NSMenuItem(title: PillView.rateLabel(r), action: #selector(pickSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: r)
            if r == speaker.rate { item.state = .on; current = item }
            menu.addItem(item)
        }
        menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func pickSpeed(_ item: NSMenuItem) {
        guard let r = (item.representedObject as? NSNumber)?.floatValue else { return }
        speaker.setRate(r)
        pill.model.rate = speaker.rate
        Log.write("speed \(speaker.rate)x")
        updateNowPlaying()
    }

    func speed(_ step: Int, wrap: Bool = false) {
        speaker.changeRate(by: step, wrap: wrap)
        pill.model.rate = speaker.rate
        updateNowPlaying()
    }

    // Claim the control keys only while reading, so other apps keep them otherwise.
    func controlsOn() {
        guard controlKeys.isEmpty else { return }
        Log.write("controls on")
        let mods = controlKey | optionKey
        controlKeys = [
            HotKey(id: 2, keyCode: kVK_Space, modifiers: mods) { [weak self] in self?.pauseToggle() },
            HotKey(id: 3, keyCode: kVK_LeftArrow, modifiers: mods) { [weak self] in self?.speaker.back() },
            HotKey(id: 4, keyCode: kVK_RightArrow, modifiers: mods) { [weak self] in self?.speaker.skip() },
            HotKey(id: 5, keyCode: kVK_UpArrow, modifiers: mods) { [weak self] in self?.speed(1) },
            HotKey(id: 6, keyCode: kVK_DownArrow, modifiers: mods) { [weak self] in self?.speed(-1) },
            HotKey(id: 7, keyCode: kVK_LeftArrow, modifiers: mods | shiftKey) { [weak self] in self?.page(-1) },
            HotKey(id: 8, keyCode: kVK_RightArrow, modifiers: mods | shiftKey) { [weak self] in self?.page(1) },
            HotKey(id: 9, keyCode: kVK_UpArrow, modifiers: mods | shiftKey) { [weak self] in self?.chapter(-1) },
            HotKey(id: 10, keyCode: kVK_DownArrow, modifiers: mods | shiftKey) { [weak self] in self?.chapter(1) },
        ]
    }

    func controlsOff() {
        if !controlKeys.isEmpty { Log.write("controls off") }
        controlKeys.forEach { $0.unregister() }
        controlKeys = []
    }
}

// Decides which files the "Open a file" window lets you pick.
final class OpenFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if isFolder.boolValue { return true }                 // folders open to browse; .epub folders pick
        return BookText.fileTypes.contains(ext)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if isFolder.boolValue && url.pathExtension.lowercased() != "epub" {
            throw CocoaError(.fileReadUnsupportedScheme)       // a plain folder isn't a book
        }
    }
}

// Start-up runs on the main thread; tell the compiler so.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
