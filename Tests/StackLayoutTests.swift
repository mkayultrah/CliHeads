import Foundation

@main
struct StackLayoutTests {
    static func main() {
        let displays = [
            MagneticDisplay(id: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1020)),
            MagneticDisplay(id: "B", frame: CGRect(x: 1920, y: -150, width: 2560, height: 1440),
                            visibleFrame: CGRect(x: 1920, y: -150, width: 2560, height: 1410))
        ]
        let size = CGSize(width: 66, height: 66)
        func expect(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), "FAIL: \(name)")
            print("PASS: \(name)")
        }
        let aRight = CGPoint(x: 1920 - 66 + 8, y: 450)
        let bLeft = CGPoint(x: 1920 - 8, y: 450)
        let a = BubbleStackLayout.key(for: aRight, size: size, displays: displays)
        let b = BubbleStackLayout.key(for: bLeft, size: size, displays: displays)
        expect(a == BubbleStackKey(displayID: "A", side: .right), "primary monitor right-edge stack")
        expect(b == BubbleStackKey(displayID: "B", side: .left), "second monitor inner-edge stack")
        expect(a != b, "separate independent groups at a screen seam")
        let fan = BubbleStackLayout.fanPositions(anchor: bLeft, count: 12,
                              size: size, display: displays[1], side: .left)
        expect(fan.count == 12, "all twelve bubbles can fan out")
        let unique = Set(fan.map { "\(Int($0.x)):\(Int($0.y))" })
        expect(unique.count == fan.count, "fanned heads are not on top of each other")
        expect(fan.allSatisfy { $0.x >= displays[1].visibleFrame.minX - 8 &&
            $0.x <= displays[1].visibleFrame.maxX - size.width + 8 }, "bubble x within screen")
        expect(fan.allSatisfy { $0.y >= displays[1].visibleFrame.minY &&
            $0.y + size.height <= displays[1].visibleFrame.maxY }, "bubble y within screen")
        expect(BubbleStackLayout.fanPositions(anchor: bLeft, count: 0,
                    size: size, display: displays[1], side: .left).isEmpty, "empty group")

        let leftTray = BubbleStackLayout.trayPositions(anchor: bLeft, count: 5,
                            size: size, display: displays[1], side: .left)
        expect(leftTray.count == 5, "tray includes four heads plus grey cog")
        expect(leftTray[1].x > leftTray[0].x, "left-edge tray opens inward")
        expect(leftTray.allSatisfy { displays[1].visibleFrame.contains(
            CGPoint(x: $0.x + size.width / 2, y: $0.y + size.height / 2)) },
            "second monitor tray stays on that monitor")
        let rightTray = BubbleStackLayout.trayPositions(anchor: aRight, count: 3,
                            size: size, display: displays[0], side: .right)
        expect(rightTray[1].x < rightTray[0].x, "right-edge tray opens inward")
        let compactDisplay = MagneticDisplay(id: "C", frame: CGRect(x: -720, y: 0, width: 720, height: 540),
                                             visibleFrame: CGRect(x: -720, y: 24, width: 720, height: 500))
        let wrapped = BubbleStackLayout.trayPositions(anchor: CGPoint(x: -715, y: 42), count: 15,
                       size: size, display: compactDisplay, side: .left)
        expect(Set(wrapped.map { "\(Int($0.x)):\(Int($0.y))" }).count == wrapped.count,
               "compact monitor tray wraps without overlapping heads")
        expect(wrapped.allSatisfy { compactDisplay.visibleFrame.contains(
            CGPoint(x: $0.x + size.width / 2, y: $0.y + size.height / 2)) },
               "wrapped tray stays within negative-coordinate display")
        expect(BubbleStackLayout.trayPositions(anchor: aRight, count: 0,
               size: size, display: displays[0], side: .right).isEmpty,
               "empty tray")

        // The POS spring (230.2/22) is slightly underdamped: a few percent of
        // overshoot is the intended bounce, but it must stay small.
        var spring = MagneticSpringPoint(origin: CGPoint(x: 200, y: 300),
                                        velocity: CGPoint(x: 480, y: -300),
                                        destination: CGPoint(x: 1862, y: 300))
        var largestX = spring.origin.x
        for _ in 0..<220 {
            spring.step(elapsed: 1.0 / 120)
            largestX = max(largestX, spring.origin.x)
        }
        expect(spring.atRest, "POS spring reaches rest")
        expect(largestX <= 1862 + 0.05 * (1862 - 200), "POS spring overshoot stays under 5% of travel")
        print("All stack layout and spring damping tests passed")
    }
}
