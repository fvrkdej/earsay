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
// --paragraphs out.png: draw the highlight boxes the Books highlight would use on a copy of the image.
// The boxes go through the same pixel to screen-point conversion as the app (pretend window at 100,50, 2x),
// then back to pixels to draw, so a wrong conversion shows up as misplaced boxes.
if let i = a.firstIndex(of: "--paragraphs"), i + 1 < a.count {
    let frame = CGRect(x: 100, y: 50, width: Double(img.width) / 2, height: Double(img.height) / 2), scale: CGFloat = 2
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let accent = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    // Same title bar and page number filter as BookReader.readPageOnce.
    let h = Double(img.height)
    let kept = lines.filter { l in !(l.text.split(separator: " ").count < 8 && (l.y < 0.08 * h || l.y > 0.92 * h)) }
    for (n, p) in OCRLayout.paragraphs(from: kept).enumerated() {
        for r in p.rows.map({ OCRLayout.screenRect(of: $0, frame: frame, scale: scale) }) {
            let px = CGRect(x: (r.minX - frame.minX) * scale, y: Double(img.height) - (r.maxY - frame.minY) * scale,
                            width: r.width * scale, height: r.height * scale).insetBy(dx: -12, dy: -4)
            ctx.setFillColor(accent.copy(alpha: 0.14)!); ctx.setStrokeColor(accent.copy(alpha: 0.55)!); ctx.setLineWidth(3)
            let path = CGPath(roundedRect: px, cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.addPath(path); ctx.fillPath(); ctx.addPath(path); ctx.strokePath()
        }
        print("paragraph \(n + 1): \(p.lines.count) lines, \(p.rows.count) rows: \(p.text.prefix(50))")
    }
    let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[i + 1]))
}
