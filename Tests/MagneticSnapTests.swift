import Foundation

func assertNear(_ actual: CGFloat, _ expected: CGFloat, _ message: String, tolerance: CGFloat = 0.5) {
    precondition(abs(actual - expected) <= tolerance, "FAIL \(message): \(actual) != \(expected)")
    print("PASS \(message)")
}
func verify(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), "FAIL \(message)")
    print("PASS \(message)")
}

@main
struct MagneticSnapTests {
    static func main() {
        let displays = [
            MagneticDisplay(id: "primary", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1026)),
            MagneticDisplay(id: "right", frame: CGRect(x: 1920, y: -160, width: 2560, height: 1440),
                            visibleFrame: CGRect(x: 1920, y: -160, width: 2560, height: 1416)),
            MagneticDisplay(id: "left", frame: CGRect(x: -1440, y: 110, width: 1440, height: 900),
                            visibleFrame: CGRect(x: -1440, y: 110, width: 1440, height: 878))
        ]
        let size = CGSize(width: 66, height: 66)
        func target(_ origin: CGPoint, _ pointer: CGPoint, _ velocity: CGPoint = .zero) -> MagneticTarget {
            MagneticSnapEngine.target(for: origin, bubbleSize: size, releasePointer: pointer,
                                      velocity: velocity, displays: displays)!
        }

        // At display seams the release pointer, NOT original panel intersection,
        // selects the display. Each external screen has its own magnetic sides.
        let r = target(CGPoint(x: 1900, y: 540), CGPoint(x: 2000, y: 530))
        verify(r.displayID == "right", "Seam crossing snaps to right-hand monitor")
        verify(r.side == .left, "Right-hand monitor's left inner edge is a magnet")
        assertNear(r.origin.x, 1920 + 8, "Inner edge x coordinate")

        let l = target(CGPoint(x: -1300, y: 600), CGPoint(x: -1280, y: 620))
        verify(l.displayID == "left", "Negative-coordinate monitor selected")
        assertNear(l.origin.x, -1440 + 8, "Leftmost monitor snaps independently")

        let far = target(CGPoint(x: 4300, y: 200), CGPoint(x: 4400, y: 200))
        verify(far.side == .right, "Right edge selected on second monitor")
        assertNear(far.origin.x, 4480 - 66 - 8, "Right monitor outer edge")

        let fling = target(CGPoint(x: 100, y: 500), CGPoint(x: 140, y: 520), CGPoint(x: 6000, y: 0))
        verify(fling.side == .right, "Fast rightward flick crosses primary monitor")
        assertNear(fling.origin.x, 1920 - 66 - 8, "Fling reaches right edge")

        let noFling = target(CGPoint(x: 100, y: 500), CGPoint(x: 140, y: 520), CGPoint(x: 50, y: 0))
        verify(noFling.side == .left, "Slow release stays at nearer edge")

        let below = target(CGPoint(x: 2000, y: -1000), CGPoint(x: 2001, y: -1000), CGPoint(x: 0, y: -2200))
        assertNear(below.origin.y, -160, "Visible-frame lower boundary on second screen")
        let above = target(CGPoint(x: 2000, y: 2000), CGPoint(x: 2020, y: 2000), CGPoint(x: 0, y: 3000))
        assertNear(above.origin.y, 1256 - 66, "Visible-frame upper boundary on second screen")

        let recovered = MagneticSnapEngine.recoveryTarget(for: CGPoint(x: 9000, y: 300),
                                                          bubbleSize: size, displays: displays)!
        verify(recovered.displayID == "right", "Unplugged display recovers onto nearest connected screen")
        assertNear(recovered.origin.x, 4480 - 66 - 8, "Recovered bubble anchored to visible edge")

        // No docked head (or its two stack peeks) may be clipped by the screen edge.
        for docked in [r, l, far, fling, recovered] {
            let screen = displays.first { $0.id == docked.displayID }!.visibleFrame
            let circleMin = docked.origin.x + 5 - (docked.side == .left ? 10 : 0)
            let circleMax = docked.origin.x + size.width - 5 + (docked.side == .right ? 10 : 0)
            verify(circleMin >= screen.minX && circleMax <= screen.maxX, "Docked head fully on screen (\(docked.displayID) \(docked.side))")
        }

        // Drop outside all displays chooses closest display, not NSScreen.main.
        let gap = MagneticSnapEngine.display(at: CGPoint(x: 500, y: 1400), in: displays)
        verify(gap?.id == "primary", "Pointer in display gap selects nearest monitor")

        var spring = MagneticSpringPoint(origin: CGPoint(x: 500, y: 450),
                                         velocity: CGPoint(x: 1400, y: -180),
                                         destination: CGPoint(x: 1854, y: 440))
        let first = spring.origin.x
        spring.step(elapsed: 1.0 / 120)
        verify(spring.origin.x > first, "Release momentum is integrated into spring")
        for _ in 0..<240 { spring.step(elapsed: 1.0 / 120) }
        verify(spring.atRest, "Spring settles to rest without perpetual idle work")
        assertNear(spring.origin.x, 1854, "Spring converges to magnetic destination")
        assertNear(spring.origin.y, 440, "Vertical spring converges")
        print("All magnetic snap tests passed")
    }
}
