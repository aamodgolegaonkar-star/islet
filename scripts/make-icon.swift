// Draws Islet's app icon (an original design: a glass island pill with a music note on a
// purple-to-pink squircle) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824 pt squircle centred in 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.33, green: 0.18, blue: 0.72, alpha: 1),
                        NSColor(red: 0.86, green: 0.25, blue: 0.52, alpha: 1),
                        NSColor(red: 0.98, green: 0.55, blue: 0.36, alpha: 1)])!
        .draw(in: squircle, angle: -60)
    // Soft glow behind the island.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), .clear])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 180 * s, y: 430 * s, width: 664 * s, height: 420 * s)), relativeCenterPosition: .zero)
    NSGraphicsContext.current?.restoreGraphicsState()
    // The island: a dark glassy pill with a bright rim.
    let pill = NSRect(x: 232 * s, y: 560 * s, width: 560 * s, height: 150 * s)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: 75 * s, yRadius: 75 * s)
    NSColor(white: 0.04, alpha: 0.82).setFill()
    pillPath.fill()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    pillPath.lineWidth = 5 * s
    pillPath.stroke()
    // Album tile and equalizer bars inside the pill.
    let art = NSBezierPath(roundedRect: NSRect(x: 270 * s, y: 590 * s, width: 90 * s, height: 90 * s), xRadius: 22 * s, yRadius: 22 * s)
    NSGradient(colors: [NSColor(red: 1, green: 0.42, blue: 0.5, alpha: 1), NSColor(red: 1, green: 0.7, blue: 0.3, alpha: 1)])!
        .draw(in: art, angle: -90)
    for (i, h) in [46.0, 82, 60, 30].enumerated() {
        let bar = NSRect(x: (640 + Double(i) * 30) * s, y: (635 - h / 2) * s, width: 18 * s, height: h * s)
        NSColor(red: 1, green: 0.62, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 9 * s, yRadius: 9 * s).fill()
    }
    // A big music note below.
    let config = NSImage.SymbolConfiguration(pointSize: 300 * s, weight: .semibold)
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: note.size, flipped: false) { rect in
            note.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: 512 * s - w / 2, y: 300 * s - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appending(path: "Islet-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appending(path: name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
