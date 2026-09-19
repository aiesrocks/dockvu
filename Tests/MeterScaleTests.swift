import AppKit

@main
struct MeterScaleTests {
    static func amplitude(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    static func assertClose(_ actual: Float, _ expected: Float, at decibels: Float) {
        precondition(abs(actual - expected) < 0.000_02,
                     "\(decibels) dBFS: expected \(expected), got \(actual)")
    }

    static func litSegments(at decibels: Float) -> Int {
        let height = MeterView.height(for: amplitude(decibels))
        return (0..<18).filter { height > Float($0) / 18 }.count
    }

    static func main() {
        let expectedHeights: [(Float, Float)] = [
            (-42, 0),
            (-40, 2.0 / 33.0 * 13.0 / 18.0),
            (-30, 12.0 / 33.0 * 13.0 / 18.0),
            (-18, 24.0 / 33.0 * 13.0 / 18.0),
            (-12, 30.0 / 33.0 * 13.0 / 18.0),
            (-9, 13.0 / 18.0),
            (-6, 13.0 / 18.0 + 3.0 / 8.0 * 3.0 / 18.0),
            (-3, 13.0 / 18.0 + 6.0 / 8.0 * 3.0 / 18.0),
            (-1, 16.0 / 18.0),
            (0, 1),
        ]
        for (decibels, expected) in expectedHeights {
            assertClose(MeterView.height(for: amplitude(decibels)), expected, at: decibels)
        }

        let expectedSegments: [(Float, Int)] = [
            (-42, 0), (-40, 1), (-30, 5), (-18, 10), (-12, 12),
            (-9, 13), (-6, 15), (-3, 16), (-1, 16), (0, 18),
        ]
        for (decibels, expected) in expectedSegments {
            let actual = litSegments(at: decibels)
            precondition(actual == expected,
                         "\(decibels) dBFS: expected \(expected) lit segments, got \(actual)")
        }

        precondition(litSegments(at: -9.001) == 13)
        precondition(litSegments(at: -8.999) == 14,
                     "first yellow segment should light immediately above -9 dBFS")
        precondition(litSegments(at: -1.001) == 16)
        precondition(litSegments(at: -0.999) == 17,
                     "first red segment should light immediately above -1 dBFS")

        precondition(MeterView.height(for: 0) == 0)
        precondition(MeterView.height(for: -1) == 0)
        precondition(MeterView.height(for: -.infinity) == 0)
        precondition(MeterView.height(for: .infinity) == 0)
        precondition(MeterView.height(for: .nan) == 0)
        precondition(MeterView.height(for: 2) == 1)
        precondition(MeterView.height(for: amplitude(-42.01)) == 0)
        print("PASS: meter scale heights, color boundaries, floor, and clamping")
    }
}
