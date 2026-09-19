import AppKit

@main
struct MeterStress {
    static func main() {
        _ = NSApplication.shared
        let meter = MeterView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        for frame in 0..<20_000 {
            autoreleasepool {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                meter.update([Float(frame % 100) / 100, 0.5, 0.02], active: frame % 101 != 0)
                meter.cameraCue = [CameraCue.idle, .active, .unknown][frame % 3]
                meter.draw(meter.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if CommandLine.arguments.count > 1 {
            try! rep.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS: 20,000 meter frames across active/paused states")
    }
}
