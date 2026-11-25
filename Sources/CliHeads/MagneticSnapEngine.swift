import Foundation
import CoreGraphics

// Independent of AppKit so the multi-display geometry and spring integration
// can be tested on their own. Coordinates are macOS global screen points.
struct MagneticDisplay {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
}

enum MagneticSide: String, Hashable {
    case left, right
}

struct MagneticTarget {
    let origin: CGPoint
    let displayID: String
    let side: MagneticSide
}

/// Spring constants (mass 1), tuned to feel like Messenger.
enum Springs {
    struct Spec {
        let stiffness: Double
        let damping: Double
    }
    static let pos = Spec(stiffness: 230.2, damping: 22)
    static let follow = Spec(stiffness: 881.8, damping: 46)
    static let scale = Spec(stiffness: 809.4, damping: 22)
    static let magnetIn = Spec(stiffness: 809.4, damping: 28)
    static let magnetOut = Spec(stiffness: 447.4, damping: 22)
    static let targetScale = Spec(stiffness: 628.4, damping: 28)
    static let panelOpen = Spec(stiffness: 628.4, damping: 37)
    static let panelClose = Spec(stiffness: 320.7, damping: 26.5)
    /// Position rest threshold in points.
    static let restDistance: Double = 0.3
}

enum MagneticSnapEngine {
    // A docked head sits fully on screen: the 56pt circle (5pt padding in the
    // 66pt panel) ends up 13pt from the edge, so up to two 5pt stack peeks
    // still show instead of being clipped by the display.
    static let edgeInset: CGFloat = 8
    /// Fling projection time (seconds of release velocity carried forward).
    static let projectionTime: CGFloat = 0.17

    /// Screen selection is based on the pointer's release position, not the
    /// first intersecting bubble frame: otherwise a bubble crossing a monitor
    /// seam can snap back to the monitor it started on.
    static func display(at pointer: CGPoint, in displays: [MagneticDisplay]) -> MagneticDisplay? {
        if let exact = displays.first(where: { $0.frame.contains(pointer) }) { return exact }
        return displays.min {
            distanceSquared(to: $0.frame, from: pointer) < distanceSquared(to: $1.frame, from: pointer)
        }
    }

    /// Fling projection: the head coasts for `projectionTime` along its release
    /// velocity (x clamped to a quarter-travel past each edge), the side is
    /// chosen by the midpoint, and y follows the fling line within the visible frame.
    static func target(
        for origin: CGPoint,
        bubbleSize: CGSize,
        releasePointer: CGPoint,
        velocity: CGPoint,
        displays: [MagneticDisplay]
    ) -> MagneticTarget? {
        guard let screen = display(at: releasePointer, in: displays) else { return nil }
        let visible = screen.visibleFrame
        let travel = visible.width - bubbleSize.width
        let margin = 0.25 * travel
        let localX = origin.x - visible.minX
        let projX = clamped(localX + velocity.x * projectionTime, -margin, visible.width + margin)
        let projY: CGFloat
        if abs(velocity.x) > 1 {
            projY = origin.y + (projX - localX) * velocity.y / velocity.x
        } else {
            projY = origin.y + velocity.y * projectionTime
        }
        let side: MagneticSide = projX >= travel / 2 ? .right : .left
        let x = side == .left
            ? visible.minX + edgeInset
            : visible.maxX - bubbleSize.width - edgeInset
        let y = containedOrigin(projY,
                                min: visible.minY,
                                max: visible.maxY - bubbleSize.height,
                                fallback: visible.midY - bubbleSize.height / 2)
        return MagneticTarget(origin: CGPoint(x: x, y: y), displayID: screen.id, side: side)
    }

    /// Used when an external display is unplugged, rearranged or resized and
    /// when restoring a saved position. Never return an off-screen bubble.
    static func recoveryTarget(
        for origin: CGPoint,
        bubbleSize: CGSize,
        displays: [MagneticDisplay]
    ) -> MagneticTarget? {
        let center = CGPoint(x: origin.x + bubbleSize.width / 2, y: origin.y + bubbleSize.height / 2)
        return target(for: origin, bubbleSize: bubbleSize, releasePointer: center,
                      velocity: .zero, displays: displays)
    }

    private static func distanceSquared(to rect: CGRect, from point: CGPoint) -> CGFloat {
        let nearestX = clamped(point.x, rect.minX, rect.maxX)
        let nearestY = clamped(point.y, rect.minY, rect.maxY)
        let dx = point.x - nearestX, dy = point.y - nearestY
        return dx * dx + dy * dy
    }

    private static func containedOrigin(_ origin: CGFloat, min lower: CGFloat,
                                        max upper: CGFloat, fallback: CGFloat) -> CGFloat {
        guard lower <= upper else { return fallback }
        return clamped(origin, lower, upper)
    }

    private static func clamped(_ n: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(n, upper))
    }
}

/// RK4 mass-spring-damper. Constants use Rebound's origami tension/friction conversion.
struct MagneticSpringAxis {
    var position: Double
    var velocity: Double
    var target: Double

    var stiffness: Double
    var damping: Double
    var restDistance: Double
    var restSpeed: Double

    init(position: Double, velocity: Double = 0, target: Double,
         spec: Springs.Spec = Springs.pos,
         restDistance: Double = Springs.restDistance, restSpeed: Double = 3) {
        self.position = position
        self.velocity = velocity
        self.target = target
        stiffness = spec.stiffness
        damping = spec.damping
        self.restDistance = restDistance
        self.restSpeed = restSpeed
    }

    /// Bounded sub-stepping keeps integration stable across timer hiccups.
    mutating func advance(_ elapsed: Double) {
        var remaining = Swift.min(Swift.max(elapsed, 0), 1.0 / 20)
        while remaining > 0.000001 {
            let dt = Swift.min(remaining, 1.0 / 120)
            step(dt)
            remaining -= dt
        }
    }

    mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        // x'' = -(k/m)(x-target) - (c/m)x'; unit mass.
        func acceleration(_ x: Double, _ v: Double) -> Double {
            -stiffness * (x - target) - damping * v
        }
        let a = velocity
        let b = acceleration(position, velocity)
        let c = velocity + b * dt / 2
        let d = acceleration(position + a * dt / 2, velocity + b * dt / 2)
        let e = velocity + d * dt / 2
        let f = acceleration(position + c * dt / 2, velocity + d * dt / 2)
        let g = velocity + f * dt
        let h = acceleration(position + e * dt, velocity + f * dt)
        position += dt * (a + 2*c + 2*e + g) / 6
        velocity += dt * (b + 2*d + 2*f + h) / 6
    }

    var atRest: Bool { abs(position - target) < restDistance && abs(velocity) < restSpeed }
}

struct MagneticSpringPoint {
    private(set) var x: MagneticSpringAxis
    private(set) var y: MagneticSpringAxis

    init(origin: CGPoint, velocity: CGPoint, destination: CGPoint,
         spec: Springs.Spec = Springs.pos) {
        x = MagneticSpringAxis(position: Double(origin.x), velocity: Double(velocity.x),
                               target: Double(destination.x), spec: spec)
        y = MagneticSpringAxis(position: Double(origin.y), velocity: Double(velocity.y),
                               target: Double(destination.y), spec: spec)
    }

    /// Moves the target without disturbing position or velocity (chasing springs).
    mutating func retarget(_ destination: CGPoint) {
        x.target = Double(destination.x)
        y.target = Double(destination.y)
    }

    mutating func step(elapsed: Double) {
        x.advance(elapsed)
        y.advance(elapsed)
    }

    var origin: CGPoint { CGPoint(x: x.position, y: y.position) }
    var atRest: Bool { x.atRest && y.atRest }
}
