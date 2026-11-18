// Library: "Continue listening". Every book and file you've opened, with its cover and how
// far you got. Click one to carry on. Covers come from the file itself (an EPUB's cover
// image, a PDF's first page), never from the internet.
import AppKit
import PDFKit
import SwiftUI

struct LibraryItem: Identifiable {
    let path: String
    var id: String { path }
    var title: String
    var percent: Int?
    var finished: Bool
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [LibraryItem] = []
    @Published var covers: [String: NSImage] = [:]
    @Published var titles: [String: String] = [:]       // the title stored inside the book
    var onOpen: (String) -> Void = { _ in }
    var onAdd: () -> Void = {}

    func refresh() {
        items = Bookmarks.library.map {
            LibraryItem(path: $0, title: AppDelegate.niceName($0), percent: Bookmarks.percent($0),
                        finished: Bookmarks.isFinished($0))
        }
        for item in items where covers[item.path] == nil {
            let path = item.path
            Task.detached(priority: .utility) {
                let img = Covers.image(for: path)
                let title = Covers.title(for: path)
                await MainActor.run { self.covers[path] = img; if let title { self.titles[path] = title } }
            }
        }
    }

    func forget(_ path: String) {
        Bookmarks.forget(path)
        refresh()
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 22)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Continue listening").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { model.onAdd() } label: { Label("Open a file", systemImage: "plus") }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Books and files you open will show up here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(model.items) { item in card(item) }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { model.refresh() }
    }

    private func card(_ item: LibraryItem) -> some View {
        Button { model.onOpen(item.path) } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(item)
                    .frame(width: 150, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                Text(model.titles[item.path] ?? item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .frame(width: 150, alignment: .leading)
                if item.finished {
                    Text("Finished").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: Double(item.percent ?? 0), total: 100)
                        .progressViewStyle(.linear).controlSize(.mini).frame(width: 150)
                    Text(item.percent.map { "\($0)%" } ?? "Not started").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Button("Remove from the library") { model.forget(item.path) }
        }
        .help(item.path)
    }

    @ViewBuilder private func cover(_ item: LibraryItem) -> some View {
        if let img = model.covers[item.path] {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            // No cover: a plain card with the title.
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                Text(item.title).font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(.white).multilineTextAlignment(.center).padding(14)
            }
        }
    }
}

enum Covers {
    /// The title stored inside the book (an EPUB's dc:title, a PDF's Title), or nil.
    static func title(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        var t: String?
        if ext == "pdf" {
            t = PDFDocument(url: URL(fileURLWithPath: path))?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        } else if ext == "epub", let opf = epubPackage(path) {
            if let r = opf.range(of: #"<dc:title[^>]*>[^<]+</dc:title>"#, options: .regularExpression) {
                let tag = String(opf[r])
                if let a = tag.firstIndex(of: ">"), let b = tag.range(of: "</")?.lowerBound {
                    t = String(tag[tag.index(after: a)..<b])
                }
            }
        }
        let clean = t?.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean?.count ?? 0) > 1 ? clean : nil
    }

    static func epubPackage(_ path: String) -> String? {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        func text(_ inner: String) -> String? {
            if isFolder.boolValue { return try? String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(inner), encoding: .utf8) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", path, inner]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }
        guard let c = text("META-INF/container.xml"),
              let r = c.range(of: #"full-path="[^"]*""#, options: .regularExpression) else { return nil }
        return text(String(c[r].dropFirst(11).dropLast()))
    }

    /// The book's own cover, or nil.
    static func image(for path: String) -> NSImage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "epub": return epubCover(path)
        case "pdf":
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: 300, height: 420), for: .mediaBox)
        default: return nil
        }
    }

    // An EPUB names its cover in its package file: an item marked "cover-image" (EPUB 3),
    // or <meta name="cover" content="id"> (EPUB 2).
    static func epubCover(_ path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        func data(_ inner: String) -> Data? {
            if isFolder.boolValue { return try? Data(contentsOf: url.appendingPathComponent(inner)) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", path, inner]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d.isEmpty ? nil : d
        }
        func text(_ inner: String) -> String? { data(inner).map { String(decoding: $0, as: UTF8.self) } }
        func attr(_ name: String, _ tag: String) -> String? {
            guard let r = tag.range(of: name + #"="[^"]*""#, options: .regularExpression) else { return nil }
            return String(tag[r].dropFirst(name.count + 2).dropLast())
        }
        func tags(_ name: String, _ s: String) -> [String] {
            var out: [String] = []
            var rest = s[...]
            while let r = rest.range(of: "<" + name + #"\b[^>]*>"#, options: .regularExpression) {
                out.append(String(rest[r])); rest = rest[r.upperBound...]
            }
            return out
        }
        guard let container = text("META-INF/container.xml"),
              let opfPath = attr("full-path", container), let opf = text(opfPath) else { return nil }
        let base = (opfPath as NSString).deletingLastPathComponent
        let items = tags("item", opf)
        var href = items.first { (attr("properties", $0) ?? "").contains("cover-image") }.flatMap { attr("href", $0) }
        if href == nil, let meta = tags("meta", opf).first(where: { attr("name", $0) == "cover" }),
           let id = attr("content", meta) {
            href = items.first { attr("id", $0) == id }.flatMap { attr("href", $0) }
        }
        if href == nil {   // last try: an image whose name says cover
            href = items.first { ($0.lowercased().contains("cover")) && (attr("media-type", $0) ?? "").hasPrefix("image/") }
                .flatMap { attr("href", $0) }
        }
        guard let h = href?.removingPercentEncoding ?? href else { return nil }
        let inner = base.isEmpty ? h : base + "/" + h
        return data(inner).flatMap { NSImage(data: $0) }
    }
}
