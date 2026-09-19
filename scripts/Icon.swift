import AppKit

@main
struct IconGenerator {
    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let view = MeterView(frame: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                view.levels = [0.05, 0.71, 0.25]
                view.active = true
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
