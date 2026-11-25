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
