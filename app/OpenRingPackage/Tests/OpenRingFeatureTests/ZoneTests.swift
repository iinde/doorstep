import Testing
import CoreGraphics
@testable import OpenRingFeature

@Suite struct ZoneTests {
    // A path: the bottom-middle of the picture (top-left origin).
    let path = [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5), CGPoint(x: 0.9, y: 1.0), CGPoint(x: 0.1, y: 1.0)]

    @Test func pointsInsideAndOutside() {
        #expect(ZoneStore.inside(CGPoint(x: 0.5, y: 0.8), path))
        #expect(!ZoneStore.inside(CGPoint(x: 0.5, y: 0.2), path))      // the street, top of picture
        #expect(!ZoneStore.inside(CGPoint(x: 0.05, y: 0.6), path))
    }
}
