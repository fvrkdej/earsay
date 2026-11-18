// OCRProbe: developer tool. Reads an image the way the app reads the screen.
// Usage: OCRProbe image.png [x y]     (x y = a click, in image pixels)
import AppKit
import ReadAloudCore

let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("can't open image"); exit(1)
}
let t = Date()
let lines = try ScreenOCR.lines(in: img)
print(String(format: "%d lines in %.2fs\n", lines.count, Date().timeIntervalSince(t)))
if a.contains("--match") {
    let page = OCRLayout.text(from: lines)
    let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")
    let t2 = Date()
    if let f = BookMatcher.find(pageText: page, windowTitle: "", folder: folder), let raw = BookMatcher.rawText(f.path) {
        print(String(format: "MATCH in %.2fs: %@", Date().timeIntervalSince(t2), (f.path as NSString).lastPathComponent))
        print("file text there: " + String(raw.dropFirst(f.offset).prefix(160)).replacingOccurrences(of: "\n", with: " "))
    } else { print("no match") }
    print("page starts:     " + String(page.prefix(160)).replacingOccurrences(of: "\n", with: " "))
    exit(0)
}
if a.count >= 4, let x = Double(a[2]), let y = Double(a[3]) {
    print(OCRLayout.text(from: lines, startingAt: x, y) ?? "(nothing)")
} else {
    print(OCRLayout.text(from: lines))
}
if a.contains("--boxes") { for l in lines { print(String(format: "x%5.0f y%5.0f w%5.0f h%4.0f  %@", l.x, l.y, l.w, l.h, l.text)) } }
