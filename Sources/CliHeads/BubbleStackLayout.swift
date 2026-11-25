import Foundation
import CoreGraphics

// Pure screen geometry so stack/fan-out behaviour can be tested without AppKit.
struct BubbleStackKey: Hashable {
    let displayID: String
    let side: MagneticSide
}

enum BubbleStackLayout {
    static func key(for anchor: CGPoint, size: CGSize,
                    displays: [MagneticDisplay]) -> BubbleStackKey? {
        let center = CGPoint(x: anchor.x + size.width / 2,
                             y: anchor.y + size.height / 2)
        guard let screen = MagneticSnapEngine.display(at: center, in: displays) else { return nil }
        return BubbleStackKey(displayID: screen.id,
                              side: center.x < screen.visibleFrame.midX ? .left : .right)
    }
}

extension BubbleStackLayout {
    /// Messenger layout when a stack is opened: every head lines up along the
    /// top of its display, starting at the edge the stack was docked on.
    /// The final slot is the options cog.
    static let rowPitch: CGFloat = 70

    static func rowPositions(count: Int, size: CGSize,
                             display: MagneticDisplay, side: MagneticSide) -> [CGPoint] {
        guard count > 0 else { return [] }
        let visible = display.visibleFrame
        let margin: CGFloat = 8
        let pitch = rowPitch                 // 68-71pt centre to centre
        let gap = pitch - size.width
        let slots = max(1, Int((visible.width - margin * 2 + gap) / pitch))
        let y = visible.maxY - size.height - 6
        return (0..<count).map { index in
            let slot = CGFloat(min(index, slots - 1))
            let x = side == .right
                ? visible.maxX - margin - size.width - slot * pitch
                : visible.minX + margin + slot * pitch
            return CGPoint(x: x, y: y)
        }
    }

    /// The conversation hangs directly below the row, flush with its edge.
    static func chatOrigin(rowY: CGFloat, chatSize: CGSize,
                           display: MagneticDisplay, side: MagneticSide) -> CGPoint {
        let visible = display.visibleFrame
        let margin: CGFloat = 13
        let x = side == .right ? visible.maxX - margin - chatSize.width : visible.minX + margin
        let y = max(visible.minY + 8, rowY + 1 - chatSize.height)
        return CGPoint(x: x, y: y)
    }

    /// Each head behind the front one sits 5pt further toward the screen edge,
    /// with no vertical offset.
    static func stackPeekOffset(depth: Int, side: MagneticSide) -> CGPoint {
        CGPoint(x: (side == .right ? 1 : -1) * CGFloat(depth) * 5, y: 0)
    }
}
