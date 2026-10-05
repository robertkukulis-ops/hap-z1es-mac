// Draws the HAP app icon at every size macOS needs and builds AppIcon.icns.
// Run: swift App/Icon/make-icon.swift   (from the project folder)
import AppKit

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = size * 0.1
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: size * 0.18, yRadius: size * 0.18)
        NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.24, alpha: 1),
                            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1)])!
            .draw(in: tile, angle: -90)
        // Record grooves.
        let center = NSPoint(x: rect.midX, y: rect.midY - size * 0.02)
        for (i, r) in stride(from: 0.30, through: 0.14, by: -0.04).enumerated() {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - size * r, y: center.y - size * r, width: size * r * 2, height: size * r * 2))
            NSColor(calibratedWhite: 1, alpha: i == 0 ? 0.18 : 0.08).setStroke()
            ring.lineWidth = max(1, size * 0.006)
            ring.stroke()
        }
        // Label in the middle, in the player's warm gold.
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.1, y: center.y - size * 0.1, width: size * 0.2, height: size * 0.2))
        NSColor(calibratedRed: 0.85, green: 0.68, blue: 0.36, alpha: 1).setFill()
        dot.fill()
        let hole = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.018, y: center.y - size * 0.018, width: size * 0.036, height: size * 0.036))
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1).setFill()
        hole.fill()
        // "HAP" at the bottom.
        if size >= 64 {
            let text = NSAttributedString(string: "HAP", attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.1, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.85),
                .kern: size * 0.012])
            let t = text.size()
            text.draw(at: NSPoint(x: rect.midX - t.width / 2, y: inset + size * 0.045))
        }
        return true
    }
}

let folder = URL(fileURLWithPath: "App/Icon/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let image = draw(size: px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
print("iconset written")
