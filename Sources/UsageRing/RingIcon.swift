import AppKit

/// Draws the menu bar ring. Uses dynamic system colors inside a deferred
/// drawing handler so the track adapts to light/dark menu bars at render time.
enum RingIcon {
    private static let side: CGFloat = 18
    private static let lineWidth: CGFloat = 3

    static func ring(fraction: Double, color: NSColor) -> NSImage {
        let clamped = min(max(fraction, 0), 1)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawTrack(in: rect)
            guard clamped > 0.004 else { return true }
            let arc = NSBezierPath()
            arc.lineCapStyle = .round
            arc.appendArc(
                withCenter: NSPoint(x: rect.midX, y: rect.midY),
                radius: radius(in: rect),
                startAngle: 90,
                endAngle: 90 - clamped * 360,
                clockwise: true)
            arc.lineWidth = lineWidth
            color.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Gray ring with a center dot — shown when there's no data yet or
    /// credentials need attention (the panel explains the details).
    static func attention() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawTrack(in: rect)
            let dotRadius: CGFloat = 2.5
            let dot = NSBezierPath(ovalIn: NSRect(
                x: rect.midX - dotRadius, y: rect.midY - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2))
            NSColor.systemOrange.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func radius(in rect: NSRect) -> CGFloat {
        (rect.width - lineWidth) / 2 - 1
    }

    private static func drawTrack(in rect: NSRect) {
        let track = NSBezierPath()
        track.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: radius(in: rect),
            startAngle: 0,
            endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
    }
}
