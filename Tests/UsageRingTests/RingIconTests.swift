import XCTest
import AppKit
@testable import UsageRing

/// Rendering smoke tests — the ring must actually produce pixels when drawn,
/// since a silent all-transparent image would look like a "missing" menu bar icon.
final class RingIconTests: XCTestCase {
    private func rasterize(_ image: NSImage, side: Int = 36) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func opaquePixelCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }

    func testRingAtHalfRendersMorePixelsThanEmpty() throws {
        let empty = opaquePixelCount(try rasterize(RingIcon.ring(fraction: 0, color: .systemGreen)))
        let half = opaquePixelCount(try rasterize(RingIcon.ring(fraction: 0.5, color: .systemYellow)))
        let full = opaquePixelCount(try rasterize(RingIcon.ring(fraction: 1, color: .systemRed)))
        XCTAssertGreaterThan(empty, 40, "track alone should render")
        XCTAssertGreaterThan(half, empty, "progress arc adds pixels on top of the track")
        XCTAssertGreaterThanOrEqual(full, half)
    }

    func testAttentionIconRendersCenterDot() throws {
        let rep = try rasterize(RingIcon.attention())
        let center = try XCTUnwrap(rep.colorAt(x: 18, y: 18))
        XCTAssertGreaterThan(center.alphaComponent, 0.5, "center dot must be visible")
    }

    func testFractionIsClampedWithoutCrashing() throws {
        _ = try rasterize(RingIcon.ring(fraction: -3, color: .systemGreen))
        _ = try rasterize(RingIcon.ring(fraction: 42, color: .systemRed))
    }
}
