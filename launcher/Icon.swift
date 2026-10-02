// Original project artwork. Generate the same cube used by the launcher.
import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 195, yRadius: 195).fill()
        func face(_ points: [(CGFloat, CGFloat)], _ color: NSColor) {
            color.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for (x, y) in points.dropFirst() { path.line(to: NSPoint(x: x, y: y)) }
            path.close(); path.fill()
        }
        face([(512, 785), (770, 636), (512, 487), (254, 636)], NSColor(calibratedRed: 0.31, green: 0.89, blue: 0.43, alpha: 1))
        face([(248, 603), (496, 460), (496, 180), (248, 323)], NSColor(calibratedRed: 0.18, green: 0.79, blue: 0.32, alpha: 1))
        face([(528, 460), (776, 603), (776, 323), (528, 180)], NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.27, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
