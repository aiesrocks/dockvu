import AppKit

enum CameraCue {
    case idle, active, unknown
}

/// Shared rendering for the Dock tile and the larger inspector.
final class MeterView: NSView {
    var levels: [Float] = [0, 0, 0] { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }
    var cameraCue: CameraCue = .idle { didSet { needsDisplay = true } }
    var peaks: [Float] = [0, 0, 0]
    private var peakDates = [Date.distantPast, Date.distantPast, Date.distantPast]

    override var isOpaque: Bool { false }

    func update(_ next: [Float], active: Bool) {
        self.active = active
        let now = Date()
        for index in 0..<3 {
            let value = Self.height(for: next[index])
            if value >= peaks[index] || now.timeIntervalSince(peakDates[index]) > 1.0 {
                peaks[index] = value
                peakDates[index] = now
            }
        }
        levels = next
    }

    /// A display scale that keeps background noise compact while preserving detail
    /// around the yellow and red boundaries.
    static func height(for amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let decibels = 20 * log10(amplitude)
        if decibels <= -42 { return 0 }
        if decibels <= -9 {
            return (decibels + 42) / 33 * (13.0 / 18.0)
        }
        if decibels <= -1 {
            return 13.0 / 18.0 + (decibels + 9) / 8 * (3.0 / 18.0)
        }
        return min(1, 16.0 / 18.0 + (decibels + 1) * (2.0 / 18.0))
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        ctx.scaleBy(x: side / 128, y: side / 128)

        let plate = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 118, height: 118), xRadius: 25, yRadius: 25)
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        plate.fill()
        NSColor(calibratedWhite: 0.26, alpha: 1).setStroke()
        plate.lineWidth = 1
        plate.stroke()
        drawCameraCue()

        for column in 0..<3 {
            let x: CGFloat = [22, 57, 87][column]
            let value = Self.height(for: levels[column])
            for segment in 0..<18 {
                let fraction = Float(segment + 1) / 18
                let color: NSColor = fraction > 0.90
                    ? NSColor(red: 1, green: 0.24, blue: 0.24, alpha: 1)
                    : fraction > 0.73
                        ? NSColor(red: 1, green: 0.79, blue: 0.13, alpha: 1)
                        : NSColor(red: 0.24, green: 0.91, blue: 0.42, alpha: 1)
                let lit = active && value > Float(segment) / 18
                color.withAlphaComponent(lit ? 1 : 0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 29 + CGFloat(segment) * 4.4, width: 19, height: 3.1), xRadius: 0.8, yRadius: 0.8).fill()
            }
            if active && peaks[column] > 0.015 {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSRect(x: x, y: 29 + CGFloat(peaks[column]) * 77, width: 19, height: 1.3).fill()
            }
            drawLabel(column, x: x)
        }
        NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
        NSRect(x: 48, y: 30, width: 1, height: 77).fill()
        ctx.restoreGState()
    }

    private func drawCameraCue() {
        let color: NSColor
        switch cameraCue {
        case .active: color = NSColor(red: 1, green: 0.16, blue: 0.16, alpha: 1)
        case .unknown: color = NSColor(red: 1, green: 0.72, blue: 0.16, alpha: 1)
        case .idle: color = NSColor(calibratedWhite: 0.32, alpha: 1)
        }
        if cameraCue == .active {
            color.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: 58, y: 108.5, width: 12, height: 12)).fill()
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 110.5, width: 8, height: 8)).fill()
    }

    /// Fixed vector lettering avoids CoreText font-feature resolution inside the 30 Hz
    /// Dock draw loop (which can raise an Objective-C exception on macOS).
    private func drawLabel(_ column: Int, x: CGFloat) {
        let path = NSBezierPath()
        let origin = NSPoint(x: x + (column == 0 ? 3 : 6.5), y: 15)
        func stroke(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: NSPoint(x: origin.x + first.0, y: origin.y + first.1))
            for point in points.dropFirst() {
                path.line(to: NSPoint(x: origin.x + point.0, y: origin.y + point.1))
            }
        }
        switch column {
        case 0: // IN
            stroke([(0, 0), (4, 0)])
            stroke([(2, 0), (2, 7)])
            stroke([(0, 7), (4, 7)])
            stroke([(7, 0), (7, 7), (12, 0), (12, 7)])
        case 1: // L
            stroke([(0, 7), (0, 0), (6, 0)])
        default: // R
            stroke([(0, 0), (0, 7), (4, 7), (6, 5.5), (6, 4.5), (4, 3), (0, 3)])
            stroke([(3, 3), (6, 0)])
        }
        NSColor(calibratedWhite: active ? 0.83 : 0.42, alpha: 1).setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }
}
