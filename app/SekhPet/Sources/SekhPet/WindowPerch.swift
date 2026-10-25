import AppKit

/// Standing on other apps' windows, for a pet and for the Pet House alike: lands on the
/// nearest window top or screen bottom, rides the window when it moves, falls when it
/// goes, jumps back when it returns, and comes back from off every screen. It moves
/// `window`; `feet` is where the thing stands, in window coordinates.
@MainActor
final class WindowPerch {
    private let window: NSWindow
    private let feet: () -> NSPoint?
    /// The window's level while not standing on a window, or while held: pets float above
    /// everything, the house sits among the windows.
    private let freeLevel: NSWindow.Level

    /// Being dragged by hand: no riding, falling or jumping meanwhile.
    var isHeld: () -> Bool = { false }
    var fallBegan: () -> Void = {}
    /// The landing at the end of a fall.
    var fallEnded: () -> Void = {}
    /// Returns how long the take-off takes before leaving the ground.
    var jumpBegan: () -> TimeInterval = { 0 }
    var jumpEnded: () -> Void = {}
    /// The window was put somewhere by the perch itself: a landing, a jump, a return on screen.
    var settled: () -> Void = {}
    /// Standing on a window, or not, changed.
    var perchChanged: (_ onWindow: Bool) -> Void = { _ in }

    /// Snap to Windows: off, it lands on nothing, not even the screen bottom.
    var snapping = true {
        didSet { if !snapping { surface = nil } }
    }

    /// The window stood on, as last seen; nil on the screen bottom or in the air.
    private(set) var surface: DesktopSurfaces.Surface? {
        didSet { if oldValue?.window != surface?.window { perchChanged(surface != nil) } }
    }

    init(window: NSWindow, freeLevel: NSWindow.Level, feet: @escaping () -> NSPoint?) {
        self.window = window
        self.freeLevel = freeLevel
        self.feet = feet
    }

    /// Until then, window changes come from Mission Control, Show Desktop, or the screens
    /// waking or unlocking.
    private var overviewUntil: TimeInterval = 0
    /// The window just stepped off, possibly still shrinking away: never a landing spot.
    private var leftWindow: CGWindowID?
    private var fall: (fromY: CGFloat, toY: CGFloat, started: TimeInterval)?
    private static let gravity: CGFloat = 2500  // points per second squared

    // MARK: Away

    private var awayReasons: Set<PetController.PauseReason> = []

    /// Asleep or locked, other apps' windows can leave the window list.
    var isAway: Bool { !awayReasons.isEmpty }

    /// The screens sleeping or the session locked. Waking and unlocking zoom every window
    /// out and back in, like Mission Control: ride it.
    func setAway(_ away: Bool, _ reason: PetController.PauseReason) {
        if away { awayReasons.insert(reason) } else { awayReasons.remove(reason) }
        overviewUntil = CACurrentMediaTime() + 2
    }

    // MARK: Landing

    private var screenUnderFeet: NSScreen {
        let x = window.frame.minX + (feet()?.x ?? window.frame.width / 2)
        return NSScreen.screens.first { $0.frame.minX <= x && x < $0.frame.maxX }
            ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Picked up: off whatever it stood on, with any fall, jump or window to jump back to forgotten.
    func leave() {
        surface = nil
        leftWindow = nil
        fall = nil
        jump = nil
        awaited = nil
    }

    /// Lands on the nearest window top or screen bottom within `gap` points of the feet,
    /// under them. Returns whether it found one.
    @discardableResult
    func snapToSurface(within gap: CGFloat) -> Bool {
        guard let feet = feet(),
              let best = landingSpot(for: window.frame, within: gap, among: DesktopSurfaces.windows()) else { return false }
        surface = best.window
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: best.top - feet.y))
        return true
    }

    /// The nearest window top or screen bottom within `gap` points of the feet, under them,
    /// were the window at `frame`.
    func landingSpot(for frame: NSRect, within gap: CGFloat, among surfaces: [DesktopSurfaces.Surface])
        -> (top: CGFloat, window: DesktopSurfaces.Surface?)? {
        guard snapping, let feet = feet() else { return nil }
        let x = frame.minX + feet.x, y = frame.minY + feet.y
        var best: (top: CGFloat, window: DesktopSurfaces.Surface?)?
        for surface in surfaces
            where surface.window != leftWindow
               && surface.frame.minX <= x && x <= surface.frame.maxX
               && abs(surface.frame.maxY - y) <= gap && abs(surface.frame.maxY - y) < abs((best?.top ?? .infinity) - y) {
            best = (surface.frame.maxY, surface)
        }
        let bottom = screenUnderFeet.visibleFrame.minY
        if abs(bottom - y) <= gap, abs(bottom - y) < abs((best?.top ?? .infinity) - y) {
            best = (bottom, nil)
        }
        return best
    }

    // MARK: Every frame

    /// Comes back on screen, keeps with the perch window's level, follows that window or
    /// falls when it's gone, and animates a fall or jump in progress.
    /// Without `canFall` (while paused or hidden) it only rides, and leaves any fall for later.
    func update(at now: TimeInterval, canFall: Bool) {
        returnIfOffScreen(at: now)
        keepWithWindow()
        if canFall, animateJump(at: now) { return }
        if canFall, surface == nil, fall == nil { watchForReturn(at: now) }
        if let fall {
            guard canFall else { return }
            let t = now - fall.started
            let y = max(fall.toY, fall.fromY - 0.5 * Self.gravity * t * t)
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: y))
            if y <= fall.toY {
                self.fall = nil
                // What it was falling to may have moved away meanwhile: keep falling.
                if !snapToSurface(within: 4) {
                    startFall(at: now)
                    if self.fall != nil { return }
                }
                fallEnded()
                settled()
            }
            return
        }
        guard let perch = surface, !isHeld(), let feet = feet(),
              let checked = checkPerch(perch.window, at: now) else { return }
        let frame = window.frame
        guard let seen = checked else {
            // Locked, other apps' windows leave the list, and come back a moment after unlocking.
            if canFall, now >= overviewUntil {
                rememberForReturn(perch)
                startFall(at: now)
            }
            return
        }
        // Mission Control and Show Desktop shrink and slide windows, then put them back:
        // ride along through it rather than treating it as minimizing.
        // Checked on every change, and every frame while one is under way; changes stay
        // treated this way for a second after it ends, while windows animate back.
        if perchMovedAt == now || now < overviewUntil, missionControlSeen {
            overviewUntil = now + 1
        }
        if now >= overviewUntil {
            // Stepped off the end of a window that got narrower.
            let shifted = frame.minX + feet.x + (seen.frame.minX - perch.frame.minX)
            guard seen.frame.minX <= shifted, shifted <= seen.frame.maxX else {
                if canFall { startFall(at: now) }
                return
            }
            // A window that changes size while its top edge moves is minimizing (the genie
            // or scale effect) or being resized from the top: step off rather than ride it.
            if seen.frame.size != perch.frame.size, seen.frame.maxY != perch.frame.maxY {
                if canFall {
                    rememberForReturn(perch)
                    startFall(at: now)
                }
                return
            }
        }

        // Ride along with the window's top-left corner, but never off the screen: Show
        // Desktop slides windows away and back, so it waits at the edge and rides back in.
        let dx = seen.frame.minX - perch.frame.minX, dy = seen.frame.maxY - perch.frame.maxY
        guard dx != 0 || dy != 0 else { return }
        let moved = NSPoint(x: frame.minX + feet.x + dx, y: frame.minY + feet.y + dy)
        guard NSScreen.screens.contains(where: { $0.frame.contains(moved) }) else { return }
        window.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        surface = seen
    }

    private var nextPerchCheck: TimeInterval = 0
    private var perchMovedAt: TimeInterval = 0
    private var lastSeenFrame = NSRect.zero
    private var missionControlSeen = false
    private var inFrontOfPerch = false

    /// The perch window, when it's due a check: every frame while it moves, for smooth
    /// riding while it's dragged, otherwise 10 times a second, on a beat all pets share
    /// so they read the windows once between them. (Reading from a background thread
    /// instead stalled drawing for half a second.)
    private func checkPerch(_ perch: CGWindowID, at now: TimeInterval) -> DesktopSurfaces.Surface?? {
        guard now >= nextPerchCheck else { return nil }
        let snapshot = DesktopSurfaces.snapshot(at: now)
        let seen = snapshot.windows[perch]
        missionControlSeen = snapshot.missionControl
        inFrontOfPerch = seen.map { perch in
            snapshot.windows[CGWindowID(window.windowNumber)].map { $0.place < perch.place } ?? false
        } ?? false
        if let seen, seen.surface.frame != lastSeenFrame {
            perchMovedAt = now
            lastSeenFrame = seen.surface.frame
        }
        nextPerchCheck = now - perchMovedAt < 0.5 ? now : ((now * 10).rounded(.down) + 1) / 10
        return .some(seen?.surface)
    }

    /// Standing on an ordinary window, it sits just above that window instead of above
    /// everything, so whatever covers the window covers it too. On an always-on-top window
    /// it floats; elsewhere, or held, it's at its free level.
    private func keepWithWindow() {
        guard let surface, surface.layer == 0, !isHeld() else {
            let level = surface != nil && !isHeld() ? .floating : freeLevel
            if window.level != level {
                window.level = level
                window.orderFrontRegardless()
            }
            return
        }
        // Clicking the window brings it in front: go back on top of it.
        if window.level == .normal, inFrontOfPerch { return }
        window.level = .normal
        window.order(.above, relativeTo: Int(surface.window))
        inFrontOfPerch = true
    }

    private var lastOnScreenCheck: TimeInterval = 0

    /// Safety net: feet on no screen (saved mid-move, a display that went away, whatever
    /// put them there) drop back in at the nearest screen's bottom edge.
    private func returnIfOffScreen(at now: TimeInterval) {
        // Not while the screens sleep, are locked or have just come back, when they can be
        // missing from the list.
        guard now - lastOnScreenCheck >= 1, now >= overviewUntil, !isAway, !isHeld(), let feet = feet() else { return }
        lastOnScreenCheck = now
        let frame = window.frame
        let at = NSPoint(x: frame.minX + feet.x, y: frame.minY + feet.y)
        // A point of slack: with the Dock hidden, things stand on the screen's very bottom
        // edge, and rounding can leave the feet a hair below it.
        guard !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(at) }),
              let screen = NSScreen.screens.min(by: { abs($0.frame.midX - at.x) < abs($1.frame.midX - at.x) })
        else { return }
        surface = nil
        fall = nil
        let visible = screen.visibleFrame
        // The feet back on screen, not the whole window: a pet's is much wider, for the widest clip.
        let x = min(max(at.x, visible.minX), visible.maxX) - feet.x
        window.setFrameOrigin(NSPoint(x: x, y: visible.minY - feet.y))
        settled()
    }

    // MARK: Falling and jumping back

    /// The window fallen from when it minimized or hid, where on it the feet were,
    /// whether it has been seen gone, and its last frame, to wait for it to settle.
    private var awaited: (window: CGWindowID, offset: CGFloat, gone: Bool, lastFrame: NSRect)?
    private var jump: (from: NSPoint, to: NSPoint, started: TimeInterval, duration: TimeInterval)?
    private var nextReturnCheck: TimeInterval = 0

    private func rememberForReturn(_ perch: DesktopSurfaces.Surface) {
        guard let feet = feet() else { return }
        awaited = (perch.window, window.frame.minX + feet.x - perch.frame.minX, false, .zero)
    }

    /// Jumps back onto the awaited window once it's back on screen and has stopped
    /// animating (restoring from the Dock, or unhiding).
    private func watchForReturn(at now: TimeInterval) {
        guard let awaited, !isHeld(), now >= nextReturnCheck, let feet = feet() else { return }
        nextReturnCheck = ((now * 10).rounded(.down) + 1) / 10
        guard let seen = DesktopSurfaces.snapshot(at: now).windows[awaited.window]?.surface else {
            self.awaited?.gone = true
            return
        }
        self.awaited?.lastFrame = seen.frame
        guard awaited.gone, seen.frame == awaited.lastFrame else { return }
        self.awaited = nil
        let frame = window.frame
        let x = min(max(seen.frame.minX + awaited.offset, seen.frame.minX + 20), seen.frame.maxX - 20)
        let to = NSPoint(x: x - feet.x, y: seen.frame.maxY - feet.y)
        let rise = abs(to.y - frame.minY)
        // Leaves the ground once the take-off (a pet's JumpStart clip, where there is one) has played.
        let takeOff = jumpBegan()
        jump = (frame.origin, to, now + takeOff, min(0.9, 0.45 + Double(rise) / 2000))
        leftWindow = nil
    }

    /// A jump in progress: an arc up and over to the window top, then the landing.
    private func animateJump(at now: TimeInterval) -> Bool {
        guard let jump else { return false }
        let t = max(0, min(1, (now - jump.started) / jump.duration))
        let arc = max(80, abs(jump.to.y - jump.from.y) * 0.25)
        let x = jump.from.x + (jump.to.x - jump.from.x) * t
        let y = jump.from.y + (jump.to.y - jump.from.y) * t + arc * 4 * t * (1 - t)
        window.setFrameOrigin(NSPoint(x: x, y: y))
        if t >= 1 {
            self.jump = nil
            let landed = snapToSurface(within: 4)
            jumpEnded()
            if !landed { startFall(at: now) }
            settled()
        }
        return true
    }

    /// Drops to the highest window top below the feet, or the screen bottom.
    private func startFall(at now: TimeInterval) {
        if let surface { leftWindow = surface.window }
        surface = nil
        guard let feet = feet() else { return }
        let frame = window.frame
        let x = frame.minX + feet.x, y = frame.minY + feet.y
        var landing = screenUnderFeet.visibleFrame.minY
        for surface in DesktopSurfaces.windows()
            where surface.window != leftWindow
               && surface.frame.minX <= x && x <= surface.frame.maxX
               && surface.frame.maxY < y - 1 && surface.frame.maxY > landing {
            landing = surface.frame.maxY
        }
        guard landing < y - 1 else { return }
        fall = (frame.minY, landing - feet.y, now)
        fallBegan()
    }
}
