// Pill: the floating bar that shows what's being read.
//
// It's an NSPanel (a lightweight window) set up so it:
// - never takes focus: you keep typing in whatever app you're in,
// - floats above other windows, on every desktop, and over full-screen apps,
// - can be dragged anywhere by its background,
// - fades out a moment after the read ends.
import AppKit
import SwiftUI

final class PillModel: ObservableObject {
    @Published var text = ""
    @Published var index = 0
    @Published var total = 0
    @Published var playing = false
    @Published var paused = false
    @Published var rate: Float = 1.0
    @Published var caption = ""
    @Published var bookMode = false         // Apple Books: show page buttons too
    @Published var hasChapters = false      // a file with chapters: show chapter buttons
    @Published var placeOffScreen = false   // the paragraph she's on is out of view: show "Find my place"
    @Published var mini = false             // the small player
    var onPrevChapter: () -> Void = {}
    var onNextChapter: () -> Void = {}
    var onChapterList: () -> Void = {}
    var onReader: () -> Void = {}             // "42%  ·  1 h 10 min left" on long reads
    // What the buttons do (set by the app).
    var onBack: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onSkip: () -> Void = {}
    var onPrevPage: () -> Void = {}
    var onNextPage: () -> Void = {}
    var onSpeed: () -> Void = {}
    var onFindPlace: () -> Void = {}
    var onSpeedMenu: () -> Void = {}          // the speed button: open the list of speeds
    var onClose: () -> Void = {}
}

// One round icon button for the pill.
struct PillButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// "Find my place": a target icon in the accent colour (grey controls around it, so it reads as
// something to act on). Dips while pressed, and gives one gentle pulse when it appears.
struct FindPlaceButton: View {
    let action: () -> Void
    @State private var pulse = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "scope")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(PressDip())
        .foregroundStyle(Color.accentColor)
        .scaleEffect(pulse ? 1.3 : 1)
        .help("Find my place")
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.15)) { pulse = true }
            withAnimation(.easeInOut(duration: 0.35).delay(0.4)) { pulse = false }
        }
    }
}

// Looks pressed while held: a little smaller and fainter.
struct PressDip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// How loud she is (kept apart from PillModel so 40 updates a second only redraw the bars).
final class LevelModel: ObservableObject {
    @Published var level: Float = 0
}

/// Five bars that move with her voice. Each bar has its own share of the loudness, so they
/// don't all jump together.
struct LevelBars: View {
    @ObservedObject var level: LevelModel
    var height: CGFloat = 22
    private static let shape: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .frame(width: 3, height: max(4, height * min(1, CGFloat(level.level) * Self.shape[i] * 1.4 + 0.12)))
            }
        }
        .frame(width: 24, height: height)
        .foregroundStyle(Color.accentColor)
        .animation(.spring(response: 0.12, dampingFraction: 0.7), value: level.level)
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    var level: LevelModel

    var body: some View {
        if model.mini { mini } else { full }
    }

    // The small player: bars, 10 s back, play/pause, 10 s forward, stop.
    private var mini: some View {
        HStack(spacing: 6) {
            LevelBars(level: level).padding(.trailing, 4)
            PillButton(symbol: "gobackward.10", help: "Back about 10 seconds", action: model.onBack)
            PillButton(symbol: model.paused ? "play.fill" : "pause.fill", help: "Pause or carry on", action: model.onPlayPause)
            PillButton(symbol: "goforward.10", help: "Forward about 10 seconds", action: model.onSkip)
            PillButton(symbol: "xmark", help: "Stop", action: model.onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: Pill.miniWidth)
    }

    private var full: some View {
        HStack(alignment: .center, spacing: 14) {
            LevelBars(level: level)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    ProgressView(value: Double(min(model.index + 1, max(model.total, 1))),
                                 total: Double(max(model.total, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                    if !model.caption.isEmpty {
                        if model.hasChapters {
                            // Click to pick a chapter from the list.
                            Button(action: model.onChapterList) {
                                HStack(spacing: 4) {
                                    Text(model.caption)
                                    Image(systemName: "list.bullet").font(.system(size: 10, weight: .semibold))
                                }
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Pick a chapter")
                            .fixedSize()
                        } else {
                            Text(model.caption)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }
            HStack(spacing: 2) {
                if model.bookMode {
                    PillButton(symbol: "backward.end.fill", help: "Previous page (Control+Option+Shift+Left)", action: model.onPrevPage)
                } else if model.hasChapters {
                    PillButton(symbol: "backward.end.fill", help: "Previous chapter (Control+Option+Shift+Up)", action: model.onPrevChapter)
                }
                PillButton(symbol: "gobackward.10", help: "Back about 10 seconds (Control+Option+Left)", action: model.onBack)
                PillButton(symbol: model.paused ? "play.fill" : "pause.fill",
                           help: "Pause or carry on (Control+Option+Space)", action: model.onPlayPause)
                PillButton(symbol: "goforward.10", help: "Forward about 10 seconds (Control+Option+Right)", action: model.onSkip)
                if model.bookMode {
                    PillButton(symbol: "forward.end.fill", help: "Next page (Control+Option+Shift+Right)", action: model.onNextPage)
                } else if model.hasChapters {
                    PillButton(symbol: "forward.end.fill", help: "Next chapter (Control+Option+Shift+Down)", action: model.onNextChapter)
                }
                if model.placeOffScreen {
                    FindPlaceButton(action: model.onFindPlace)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                Button(action: model.onSpeedMenu) {
                    Text(Self.rateLabel(model.rate))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: 44, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Speed (Control+Option+Up and Down)")
                PillButton(symbol: "book", help: "Show the book (reader window)", action: model.onReader)
                PillButton(symbol: "xmark", help: "Stop (Control+Option+R)", action: model.onClose)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: Pill.width)
    }

    static func rateLabel(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))x" : String(format: "%gx", r)
    }
}

// Lets a click on a button work straight away, even though the pill never takes focus.
final class ClickThroughHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A panel that can never become the key or main window, so it never steals focus.
final class NonFocusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Pill {
    static let width: CGFloat = 700
    static let miniWidth: CGFloat = 230
    let model = PillModel()
    let level = LevelModel()
    private let panel: NonFocusPanel
    private let host: ClickThroughHost<PillView>
    private var hideWork: DispatchWorkItem?
    private var placed = false

    init() {
        panel = NonFocusPanel(contentRect: NSRect(x: 0, y: 0, width: Pill.width, height: 70),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.level = .statusBar                    // above normal windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        // Frosted background with rounded corners.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        // Round the corners with a mask, not a layer corner radius: the window then takes
        // the rounded shape, so no square white corners show after it's dragged (15 Nov).
        blur.maskImage = Pill.roundedMask(radius: 18)

        host = ClickThroughHost(rootView: PillView(model: model, level: level))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        panel.alphaValue = 0
    }

    func show(sentence: String, index: Int, total: Int) {
        hideWork?.cancel()
        model.text = sentence
        model.index = index
        model.total = total
        model.playing = true
        model.paused = false
        resizeToFit(for: sentence)
        if !placed { placeAtBottomCentre(); placed = true }
        // Check what macOS actually shows, not only what AppKit believes: on 18 Nov the pill
        // stayed "visible" and fully opaque to AppKit while the window server had it off
        // screen, so it never came back. Being off screen counts as hidden.
        let onScreen = panel.isVisible && panel.occlusionState.contains(.visible)
        if !onScreen || panel.alphaValue < 1 {
            if index == 0 || !onScreen {
                Log.write("pill: show (visible \(panel.isVisible), on screen \(onScreen), alpha \(String(format: "%.2f", panel.alphaValue)))")
            }
            panel.orderFrontRegardless()            // show without activating our app
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
    }

    /// Switch between the full and the small player.
    func setMini(_ on: Bool) {
        model.mini = on
        if panel.isVisible { resizeToFit(for: model.text) }
    }

    // Read finished: fade out after a moment.
    func finish() {
        model.playing = false
        hideLater(after: 1.5)
    }

    // Stopped: go away now.
    func hide() {
        model.playing = false
        hideLater(after: 0)
    }

    private func hideLater(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: {
                // A new read may have started during the fade: then keep it.
                if self.model.playing { self.panel.alphaValue = 1 } else { self.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // Measure a separate, off-screen copy of the view. Asking the on-screen one for its
    // size while SwiftUI is updating it crashed the app (15 Nov).
    private func resizeToFit(for text: String) {
        let probe = PillModel()
        probe.text = text
        probe.total = 1
        probe.mini = model.mini
        let size = NSHostingView(rootView: PillView(model: probe, level: LevelModel())).fittingSize
        var frame = panel.frame
        let newHeight = max(model.mini ? 44 : 56, size.height)
        let newWidth = model.mini ? Pill.miniWidth : Pill.width
        frame.origin.y += frame.height - newHeight      // grow downward from the top edge
        frame.origin.x += (frame.width - newWidth) / 2  // keep it centred where it is
        frame.size = NSSize(width: newWidth, height: newHeight)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // A stretchable rounded-rectangle image used as the frosted background's mask.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // First time: bottom centre of the screen the mouse is on, above the Dock.
    private func placeAtBottomCentre() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 28))
    }
}
