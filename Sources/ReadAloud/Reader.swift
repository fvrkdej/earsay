// Reader: a window that shows the book while she reads it.
//
// - The book's own words (not the tidied text she speaks), set like a page.
// - The paragraph she's reading is highlighted and kept in view as she goes.
//   Turn "Follow" off to read ahead without being pulled back.
// - Click a paragraph to jump there. Pick a chapter from the title at the top.
// - With this window in front: Space pauses, Left and Right go 10 seconds.
// It shows one chapter at a time, so even a long book stays light.
import AppKit
import SwiftUI
import ReadAloudCore

struct ReaderParagraph: Identifiable, Equatable {
    let id: Int          // paragraph number in the whole read
    let text: String
}

final class ReaderModel: ObservableObject {
    @Published var title = ""
    @Published var chapterTitle = ""
    @Published var chapters: [String] = []
    @Published var chapter = 0
    @Published var paragraphs: [ReaderParagraph] = []
    @Published var current = -1
    @Published var follow = true
    @Published var paused = false
    var onTap: (Int) -> Void = { _ in }
    var onChapter: (Int) -> Void = { _ in }
    var onPause: () -> Void = {}
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.paragraphs) { p in
                            paragraph(p)
                                .id(p.id)
                        }
                    }
                    .frame(maxWidth: 660)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.current) { _, now in
                    guard model.follow else { return }
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(now, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
                .onChange(of: model.paragraphs) { _, _ in
                    proxy.scrollTo(model.current, anchor: UnitPoint(x: 0.5, y: 0.3))
                }
                .onChange(of: model.follow) { _, on in
                    if on { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(model.current, anchor: UnitPoint(x: 0.5, y: 0.3)) } }
                }
                .onAppear { proxy.scrollTo(model.current, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.onPause(); return .handled }
        .onKeyPress(.leftArrow) { model.onBack(); return .handled }
        .onKeyPress(.rightArrow) { model.onForward(); return .handled }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if model.chapters.count > 1 {
                Menu {
                    ForEach(Array(model.chapters.enumerated()), id: \.offset) { i, name in
                        Button { model.onChapter(i) } label: {
                            if i == model.chapter { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    Text(model.chapterTitle.isEmpty ? "Chapters" : model.chapterTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                Text("\(model.chapter + 1) of \(model.chapters.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("Follow", isOn: $model.follow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .help("Keep the paragraph she's reading in view")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func paragraph(_ p: ReaderParagraph) -> some View {
        let isCurrent = p.id == model.current
        return Text(p.text)
            .font(.system(size: 17, design: .serif))
            .lineSpacing(6)
            .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.82))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.13 : 0))
            )
            .contentShape(Rectangle())
            .onTapGesture { model.onTap(p.id) }
            .animation(.easeOut(duration: 0.25), value: isCurrent)
    }
}

@MainActor
final class Reader: NSObject, NSWindowDelegate {
    let model = ReaderModel()
    private var window: NSWindow?
    private var shownChapter = -2
    private var shownCount = -1
    var isOpen: Bool { window?.isVisible ?? false }
    /// Remembered between launches: if you had the reader open, it opens with the next book.
    static var wantsOpen: Bool {
        get { UserDefaults.standard.bool(forKey: "readerOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "readerOpen") }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ReaderView(model: model))
            w.title = model.title.isEmpty ? "Earsay" : model.title
            w.setFrameAutosaveName("ReaderWindow")       // remembers where you put it
            if w.frame.origin == .zero { w.center() }
            w.delegate = self
            window = w
        }
        Self.wantsOpen = true
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle() { isOpen ? close() : show() }

    func close() {
        window?.orderOut(nil)
        Self.wantsOpen = false
    }

    func windowWillClose(_ notification: Notification) { Self.wantsOpen = false }

    /// Called on every new sentence: move the highlight, and swap the page when the chapter changes.
    func update(speaker: Speaker, title: String) {
        if model.title != title { model.title = title; window?.title = title }
        let sentences = speaker.allSentences
        let i = speaker.playingIndex
        guard i < sentences.count else { return }
        let chapter = speaker.chapterIndex ?? -1
        let paras = speaker.paragraphs
        if chapter != shownChapter || (chapter == -1 && paras.count != shownCount) {
            shownChapter = chapter
            shownCount = paras.count
            var range = 0..<paras.count
            if chapter >= 0 {
                let starts = speaker.chapterStarts
                let first = sentences[starts[chapter]].paragraph
                let last = chapter + 1 < starts.count ? sentences[starts[chapter + 1]].paragraph : paras.count
                range = first..<max(first + 1, last)
            }
            model.paragraphs = range.map { ReaderParagraph(id: $0, text: paras[$0]) }
            model.chapters = speaker.chapterTitles()
            model.chapter = max(chapter, 0)
            model.chapterTitle = chapter >= 0 && chapter < model.chapters.count ? model.chapters[chapter] : ""
        }
        model.current = sentences[i].paragraph
        model.paused = speaker.paused
    }

    /// A new read started: forget the old page.
    func reset() {
        shownChapter = -2
        shownCount = -1
    }
}
