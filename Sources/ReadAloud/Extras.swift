// Extras: the things that make it feel like a real player.
// - MediaControls: the keyboard's play/pause key, AirPods taps, and the Now Playing panel
//   in Control Center drive her, like Music or a podcast app. Only claimed while reading.
// - LoginItem: open Earsay when the Mac starts.
import AppKit
import MediaPlayer
import ServiceManagement
import CoreAudio
import ReadAloudCore

@MainActor
final class MediaControls {
    var onToggle: () -> Void = {}
    var onPlay: () -> Void = {}
    var onPause: () -> Void = {}
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    private var on = false
    private var targets: [(MPRemoteCommand, Any)] = []

    /// Claim the media keys (call when a read starts). macOS sends them to whichever app
    /// says it's playing, so Music gets them back once we let go.
    func enable() {
        guard !on else { return }
        on = true
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ f: @escaping () -> Void) {
            cmd.isEnabled = true
            let t = cmd.addTarget { _ in DispatchQueue.main.async { f() }; return .success }
            targets.append((cmd, t))
        }
        add(c.togglePlayPauseCommand) { [weak self] in self?.onToggle() }
        add(c.playCommand) { [weak self] in self?.onPlay() }
        add(c.pauseCommand) { [weak self] in self?.onPause() }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.preferredIntervals = [10]
        add(c.skipBackwardCommand) { [weak self] in self?.onBack() }
        add(c.skipForwardCommand) { [weak self] in self?.onForward() }
        // AirPods double and triple taps, and the keyboard's next/previous keys.
        add(c.nextTrackCommand) { [weak self] in self?.onForward() }
        add(c.previousTrackCommand) { [weak self] in self?.onBack() }
        Log.write("media keys on")
    }

    /// What Control Center shows: the title, the chapter, playing or paused.
    func update(title: String, chapter: String?, paused: Bool, rate: Float) {
        guard on else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Earsay",
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let chapter, !chapter.isEmpty { info[MPMediaItemPropertyAlbumTitle] = chapter }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = paused ? .paused : .playing
    }

    func disable() {
        guard on else { return }
        on = false
        for (cmd, t) in targets { cmd.removeTarget(t) }
        targets = []
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        Log.write("media keys off")
    }
}

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("open at login: \(on ? "on" : "off")")
        } catch {
            Log.write("open at login: couldn't change: \(error)")
        }
    }

    /// The first launch turns it on once (Deji asked for it, 17 Nov). After that his choice stands.
    static func setUpOnce() {
        let key = "loginItemSetUp"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}

/// Drop a file on the menu bar icon to read it. Clicks pass through to the icon.
final class DropView: NSView {
    var onFile: (String) -> Void = { _ in }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go to the button
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { file(sender) == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let path = file(sender) else { return false }
        onFile(path)
        return true
    }
    private func file(_ s: NSDraggingInfo) -> String? {
        guard let url = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return nil }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let ext = url.pathExtension.lowercased()
        return (ReadAloudCore.BookText.fileTypes.contains(ext) || (isFolder.boolValue && ext == "epub")) ? url.path : nil
    }
}

// MARK: - Updates

/// Once a day, look at the public releases page on GitHub. If there's a newer version, the menu
/// says so and links to the download. Nothing is sent but the request itself; no account.
enum Updates {
    /// Where releases are published, as "owner/name". Empty until the repository exists.
    /// A fork changes this one line to point its users at its own releases.
    static let repo = "fvrkdej/earsay"
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func check(repo: String = Updates.repo, _ found: @escaping @MainActor (String, URL) -> Void) {
        guard !repo.isEmpty, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard newer(version, than: current) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { found(version, page) } }
        }.resume()
    }

    /// "1.10" is newer than "1.9"; "1.2" is the same as "1.2.0".
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - Microphone

/// Is any app using the microphone right now (a call, a voice note, dictation)?
enum Microphone {
    static func inUse() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
