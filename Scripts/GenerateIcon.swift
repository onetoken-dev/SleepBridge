// SPDX-License-Identifier: MIT
import AppKit

// Original geometry only. No external artwork or exported SF Symbols is embedded.
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let p = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let background = NSColor(calibratedRed: 0.04, green: 0.20, blue: 0.25, alpha: 1)
        let foreground = NSColor(calibratedRed: 0.35, green: 0.91, blue: 0.82, alpha: 1)
        background.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0.04 * p, y: 0.04 * p, width: 0.92 * p, height: 0.92 * p),
            xRadius: 0.22 * p, yRadius: 0.22 * p
        ).fill()
        foreground.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0.19 * p, y: 0.20 * p, width: 0.51 * p, height: 0.51 * p))
            .fill()
        background.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0.36 * p, y: 0.34 * p, width: 0.46 * p, height: 0.46 * p))
            .fill()
        func drawZ(x: CGFloat, y: CGFloat, width: CGFloat) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: y + width))
            line.line(to: NSPoint(x: x + width, y: y + width))
            line.line(to: NSPoint(x: x, y: y))
            line.line(to: NSPoint(x: x + width, y: y))
            line.lineWidth = max(1, width * 0.14)
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            foreground.setStroke()
            line.stroke()
        }
        drawZ(x: 0.57 * p, y: 0.66 * p, width: 0.14 * p)
        drawZ(x: 0.73 * p, y: 0.53 * p, width: 0.10 * p)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: destination + "/icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
