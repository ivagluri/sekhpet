import Foundation

/// Moves the pet through the desktop: sideways by moving the window (reported
/// through `onMove`), and into or out of the screen through the actor's depth.
/// Two kinds of motion:
/// - travel: an in-place locomotion clip carried along at its stride speed, so
///   the feet don't slide;
/// - root: a clip's authored root path (sidesteps, somersault), scaled down and
///   applied sideways only; the depth band is too shallow for its forward/back part.
@MainActor
final class PetMotion {
    private enum Active {
        case travel(direction: Double, distance: Double, depthFrom: Double, depthTo: Double, speed: Double, covered: Double)
        case root(travel: Catalog.RootTravel, yaw: Double, started: TimeInterval, lastX: Double)
    }

    /// Host hook: shift the pet sideways by this many metres (at depth scale 1).
    var onMove: ((Double) -> Void)?
    /// Called when a travel reaches its goal or runs out of room.
    var onArrive: (() -> Void)?
    /// Metres from the pet's centre to the left and right screen edges.
    var room: () -> (left: Double, right: Double) = { (.infinity, .infinity) }
    /// How far the playing clip's body reaches from the centre; travel keeps
    /// this much room so none of it crosses a screen edge.
    var margin = 0.0
    /// Pinned pets play travel in place: the window stays put and depth doesn't
    /// change, but travels still take as long as they would have.
    var isPinned = false
    /// Set while standing on a window: trips stay at the current depth, since
    /// stepping back would lift the feet off the window's edge.
    var holdsDepth = false

    private let actor: PetActor
    private var active: Active?
    private var lastUpdate: TimeInterval?

    init(actor: PetActor) {
        self.actor = actor
    }

    var isMoving: Bool { active != nil }

    /// Walks `dx` metres sideways (negative is left), easing depth toward `depthTo`.
    func beginTravel(dx: Double, depthTo: Double, speed: Double) {
        active = .travel(direction: dx < 0 ? -1 : 1, distance: abs(dx), depthFrom: actor.depth,
                         depthTo: depthTo, speed: max(speed, 0.1), covered: 0)
    }

    /// Follows the clip's recorded root path, turned to the body's yaw.
    func beginRoot(_ travel: Catalog.RootTravel, yawDegrees: Double, at now: TimeInterval) {
        guard travel.scale != 0, !travel.samples.isEmpty else {
            cancel()
            return
        }
        active = .root(travel: travel, yaw: yawDegrees * .pi / 180, started: now, lastX: 0)
    }

    func cancel() { active = nil }

    /// Keeps time-based paths in step after a pause.
    func shift(by interval: TimeInterval) {
        if case let .root(travel, yaw, started, lastX) = active {
            active = .root(travel: travel, yaw: yaw, started: started + interval, lastX: lastX)
        }
        lastUpdate = nil
    }

    func update(at now: TimeInterval) {
        defer { lastUpdate = now }
        guard let active, let lastUpdate else { return }
        let dt = min(now - lastUpdate, 0.1)
        switch active {
        case let .travel(direction, distance, depthFrom, depthTo, speed, covered):
            let room = isPinned ? .infinity : (direction < 0 ? room().left : room().right) - margin
            let step = min(speed * dt, distance - covered)
            let scale = PetActor.scale(forDepth: actor.depth)
            guard step > 0, room > step * scale else {
                arrive()
                return
            }
            if !isPinned {
                let progress = (covered + step) / distance
                actor.setDepth(depthFrom + (depthTo - depthFrom) * progress, over: 0)
                onMove?(direction * step * scale)
            }
            self.active = .travel(direction: direction, distance: distance, depthFrom: depthFrom,
                                  depthTo: depthTo, speed: speed, covered: covered + step)
        case let .root(travel, yaw, started, lastX):
            let position = Self.sample(travel, at: now - started)
            // Model space to world: rotate (x, z) by the body's yaw about Y; keep the sideways part.
            let x: Double = (position.x * cos(yaw) + position.z * sin(yaw)) * travel.scale
            let dx = x - lastX
            let room = (dx < 0 ? room().left : room().right) - margin
            let scale = PetActor.scale(forDepth: actor.depth)
            if !isPinned, abs(dx) * scale < room { onMove?(dx * scale) }
            let finished = (now - started) * travel.fps >= Double(travel.samples.count - 1)
            self.active = finished ? nil : .root(travel: travel, yaw: yaw, started: started, lastX: x)
        }
    }

    /// The world heading of a travel, as a yaw the body should face.
    func headingDegrees(dx: Double, depthTo: Double) -> Double {
        let dz = -(depthTo - actor.depth) * PetActor.depthZ
        return atan2(dx, dz) * 180 / .pi
    }

    /// Sideways metres a root-travel clip would cover at the given yaw.
    static func sidewaysTravel(_ travel: Catalog.RootTravel, yawDegrees: Double) -> Double {
        let yaw = yawDegrees * .pi / 180
        return (travel.end[0] * cos(yaw) + travel.end[1] * sin(yaw)) * travel.scale
    }

    private func arrive() {
        active = nil
        onArrive?()
    }

    private static func sample(_ travel: Catalog.RootTravel, at time: TimeInterval) -> (x: Double, z: Double) {
        let position = max(0, time * travel.fps)
        let index = min(Int(position), travel.samples.count - 1)
        let next = min(index + 1, travel.samples.count - 1)
        let t = position - Double(index)
        let a = travel.samples[index], b = travel.samples[next]
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    }
}
