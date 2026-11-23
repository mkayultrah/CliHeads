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

    /// Fans out along the same edge, then into additional columns if there are
    /// too many sessions for the display height. Handles negative coordinates.
    static func fanPositions(anchor: CGPoint, count: Int, size: CGSize,
                             display: MagneticDisplay, side: MagneticSide) -> [CGPoint] {
        guard count > 0 else { return [] }
        let available = display.visibleFrame
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        let pitchY = size.height + gap
        let pitchX = size.width + gap
        let safeHeight = max(size.height, available.height - 2 * margin)
        let maxRows = max(1, Int((safeHeight + gap) / pitchY))
        let minY = available.minY + margin
        let maxY = max(minY, available.maxY - margin - size.height)
        let minX = available.minX + MagneticSnapEngine.edgeInset
        let maxX = max(minX, available.maxX - size.width - MagneticSnapEngine.edgeInset)
        var positions: [CGPoint] = []
        for index in 0..<count {
            let column = index / maxRows
            let row = index % maxRows
            let rowsInColumn = min(maxRows, count - column * maxRows)
            let desiredStartY = anchor.y - CGFloat(rowsInColumn - 1) * pitchY / 2
            let startY = max(minY, min(desiredStartY, maxY - CGFloat(rowsInColumn - 1) * pitchY))
            let x = anchor.x + (side == .right ? -1 : 1) * CGFloat(column) * pitchX
            positions.append(CGPoint(x: max(minX, min(x, maxX)), y: startY + CGFloat(row) * pitchY))
        }
        return positions
    }
}

extension BubbleStackLayout {
    /// Messenger-style horizontal row, starting from the docked head and moving
    /// into its monitor. The final position is reserved for the options cog.
    /// Wraps into additional rows rather than drawing off the neighbouring display.
    static func trayPositions(anchor: CGPoint, count: Int, size: CGSize,
                              display: MagneticDisplay, side: MagneticSide) -> [CGPoint] {
        guard count > 0 else { return [] }
        let visible = display.visibleFrame
        let gap: CGFloat = 10
        let pitch = size.width + gap
        let margin: CGFloat = 14
        let columns = max(1, Int((visible.width - margin * 2 + gap) / pitch))
        let maxX = visible.maxX - margin - size.width
        let minX = visible.minX + margin
        // Some dock positions tuck slightly off-screen. Pull the row's base
        // fully inside the display before placing neighbouring chats.
        let startX = side == .right ? maxX : minX
        let rows = Int(ceil(Double(count) / Double(columns)))
        let lowestStart = visible.minY + margin + CGFloat(max(0, rows - 1)) * pitch
        let highestStart = visible.maxY - size.height - margin
        // Centre a multi-row tray around its docked head, rather than
        // treating the first row as the entire tray's visual centre.
        let preferredTop = anchor.y + CGFloat(max(0, rows - 1)) * pitch / 2
        let startY = max(min(lowestStart, highestStart),
                         min(preferredTop, highestStart))
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            let x = startX + (side == .right ? -1 : 1) * CGFloat(column) * pitch
            let desiredY = startY - CGFloat(row) * pitch
            let y = max(visible.minY + margin,
                        min(desiredY, visible.maxY - size.height - margin))
            return CGPoint(x: max(minX, min(x, maxX)), y: y)
        }
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
        let pitch = rowPitch                 // spec: 68-71pt centre to centre
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
