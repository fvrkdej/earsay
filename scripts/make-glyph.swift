// Draws the waveform layer for the Icon Composer icon: white on transparent, exactly
// 1024 x 1024 pixels (drawn into a fixed-size bitmap, so a Retina screen can't double it).
// Run: swift scripts/make-glyph.swift Resources/AppIcon.icon/Assets/wave.png
import AppKit
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let pointSize = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "440")!)
let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let wave = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = wave.size
    wave.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
