import Foundation

/// One clip in a sequence. `loops == nil` repeats until the sequence is released.
/// A `travel` step carries the pet `dx` metres sideways (and toward `depthTo`)
/// at the clip's stride speed, and is released when it arrives.
struct Step {
    struct Travel {
        let dx: Double
        let depthTo: Double
        let speed: Double
    }

    let clip: String
    let loops: Int?
    var travel: Travel? = nil
}

/// An ordered run of clips treated as a single behavior. Grouped start/loop/end
/// clips are always played through one of these, and interrupting a sequence
/// plays its `exitSteps` (a group's end clips) instead of cutting out mid-group.
@MainActor
final class ClipSequence {
    let name: String
    /// Screen side for directional clips: +1 faces right, -1 faces left.
    let side: Double
    /// The head follows the cursor while this sequence plays.
    var watchesCursor = false
    /// Started from the menu rather than chosen at random.
    var requested = false

    /// Whether any step carries the pet across the screen.
    var travels: Bool { steps.contains { $0.travel != nil } }
    private var steps: [Step]
    private let exitSteps: [Step]
    private var index = -1
    private var stepEnds = TimeInterval.infinity
    private var exiting = false
    private(set) var isFinished = false

    init(name: String, steps: [Step], exitSteps: [Step] = [], side: Double = Bool.random() ? 1 : -1) {
        self.name = name
        self.steps = steps
        self.exitSteps = exitSteps
        self.side = side
    }

    static func single(_ clip: String, loops: Int? = 1, side: Double = Bool.random() ? 1 : -1) -> ClipSequence {
        ClipSequence(name: clip, steps: [Step(clip: clip, loops: loops)], side: side)
    }

    /// A catalog group: start clips, the loop clip `loops` times (or until released), then end clips.
    static func group(_ name: String, in catalog: Catalog, loops: Int? = nil, side: Double? = nil) -> ClipSequence {
        guard let group = catalog.groups[name] else { fatalError("clips.json has no group named \(name)") }
        let end = group.end.map { Step(clip: $0, loops: 1) }
        return ClipSequence(name: name,
                            steps: group.start.map { Step(clip: $0, loops: 1) } + [Step(clip: group.loop, loops: loops)] + end,
                            exitSteps: end,
                            side: side ?? (Bool.random() ? 1 : -1))
    }

    func start(on rig: PetRig, at now: TimeInterval) { advance(rig, now) }

    func update(on rig: PetRig, at now: TimeInterval) {
        if !isFinished, now >= stepEnds { advance(rig, now) }
    }

    /// Ends an until-released loop and continues with the remaining steps.
    func release(on rig: PetRig, at now: TimeInterval) {
        guard index >= 0, index < steps.count, steps[index].loops == nil else { return }
        advance(rig, now)
    }

    /// Asks the sequence to wrap up: groups play their end clips, anything else stops now.
    func interrupt(on rig: PetRig, at now: TimeInterval) {
        guard !exiting, !isFinished else { return }
        exiting = true
        if exitSteps.isEmpty {
            isFinished = true
            return
        }
        // Already playing the end clips: let them finish naturally.
        if index >= steps.count - exitSteps.count { return }
        steps = exitSteps
        index = -1
        advance(rig, now)
    }

    /// Keeps step timing in step with animations after the scene was paused.
    func shift(by interval: TimeInterval) { stepEnds += interval }

    private func advance(_ rig: PetRig, _ now: TimeInterval) {
        index += 1
        guard index < steps.count else {
            isFinished = true
            return
        }
        let step = steps[index]
        let clip = rig.catalog.clip(step.clip)
        rig.play(step, side: side, at: now)
        if let loops = step.loops {
            // Hand over slightly before the clip ends so the next crossfade
            // overlaps its tail rather than holding a frozen last frame.
            let overlap = min(0.3, clip.duration * 0.25)
            stepEnds = now + clip.duration * Double(loops) - overlap
        } else {
            stepEnds = .infinity
        }
    }
}

/// Picks what the pet does next. By default the idle clip loops, and at random
/// intervals one surprise (any non-input clip or group) plays before returning
/// to idle. In loop mode the selected entry repeats instead, with no surprises.
/// Input reactions interrupt either, then hand back to the baseline.
@MainActor
final class BehaviorEngine {
    enum Mode { case random, loop }
    enum Watch: String, CaseIterable { case occasionally, always, never }
    /// Share of surprises that are a cursor-watching spell, in `Watch.occasionally`.
    static let watchChance = 0.2

    let rig: PetRig
    private let clock: () -> TimeInterval
    private var current: ClipSequence?
    private var pending: (sequence: ClipSequence, baseline: Bool)?
    private var currentIsBaseline = false
    private var nextSurprise = TimeInterval.infinity
    private var lastSurprise: Catalog.PoolEntry?
    private var pausedAt: TimeInterval?
    /// Watch Cursor Now in loop mode tracks the cursor on top of the loop until then.
    private var watchOverlayUntil: TimeInterval = 0

    private(set) var mode = Mode.random
    var watch = Watch.occasionally {
        didSet { updateWatching() }
    }
    private(set) var loopSelection: Catalog.PoolEntry
    /// Seconds between surprises; nil turns surprises off.
    var surpriseInterval: ClosedRange<Double>? {
        didSet { scheduleSurprise(from: clock()) }
    }
    var onChange: ((String) -> Void)?

    init(rig: PetRig, clock: @escaping () -> TimeInterval) {
        self.rig = rig
        self.clock = clock
        let range = rig.catalog.surprise.intervalSeconds
        surpriseInterval = range[0]...range[1]
        loopSelection = Catalog.PoolEntry(clip: rig.catalog.idleClip, group: nil)
        rig.motion.onArrive = { [weak self] in
            guard let self, let current = self.current else { return }
            current.release(on: self.rig, at: self.clock())
        }
    }

    var currentName: String? { current?.name }
    var isPaused: Bool { pausedAt != nil }
    var secondsUntilSurprise: TimeInterval? {
        guard mode == .random, nextSurprise.isFinite else { return nil }
        return max(0, nextSurprise - (pausedAt ?? clock()))
    }

    func tick() {
        guard pausedAt == nil else { return }
        let now = clock()
        if watchOverlayUntil > 0, now >= watchOverlayUntil {
            watchOverlayUntil = 0
            updateWatching()
        }
        current?.update(on: rig, at: now)
        if current?.isFinished ?? true {
            if let next = pending {
                pending = nil
                start(next.sequence, baseline: next.baseline, at: now)
            } else {
                start(baseline(), baseline: true, at: now)
            }
        } else if mode == .random, currentIsBaseline, now >= nextSurprise {
            perform(surprise(), at: now)
        }
    }

    // MARK: Requests

    /// Runs `sequence` as soon as the current one can let go: immediately, or
    /// after a group has played its end clips.
    func perform(_ sequence: ClipSequence) { perform(sequence, at: clock()) }

    /// Plays an entry from the menu: once (then back to idle) in random mode,
    /// or as the repeating selection in loop mode.
    func playNow(_ entry: Catalog.PoolEntry) {
        if mode == .loop {
            loopSelection = entry
            perform(baseline(), asBaseline: true, at: clock())
        } else {
            perform(sequence(for: entry, loops: randomLoops()), at: clock())
        }
    }

    // MARK: Input reactions

    func click() {
        guard let clip = rig.catalog.input.singleClick.pickWeighted() else { return }
        perform(.single(clip, side: rig.preferredSide(for: clip)), at: clock())
    }

    /// Chosen per pet in its menus; nil plays the pack's own double-click clip.
    var doubleClickOverride: Catalog.PoolEntry?
    /// Each double-click plays a different surprise or travel gait.
    var doubleClickRandom = false

    /// One of the pet's surprises or travel gaits, picked at random.
    func randomEntry() -> Catalog.PoolEntry? {
        let catalog = rig.catalog
        return (catalog.surprisePool + catalog.locomotion.map { Catalog.PoolEntry(clip: $0.clip, group: nil) }).randomElement()
    }

    func doubleClick() {
        if let entry = doubleClickRandom ? randomEntry() : doubleClickOverride {
            // Played like Play Now: groups run start to end, travel gaits go for a walk.
            perform(sequence(for: entry, loops: randomLoops()), at: clock())
            return
        }
        guard let clip = rig.catalog.input.doubleClick else { return }
        perform(.single(clip, side: rig.preferredSide(for: clip)), at: clock())
    }

    /// Held while dragging: the carry group's loop runs until the drop.
    func dragBegan() {
        guard let group = rig.catalog.input.dragGroup else { return }
        perform(.group(group, in: rig.catalog), at: clock())
    }

    /// A jump of the pet's own: the landing group (Jump: its start clips, then its loop
    /// held in the air) until `jumpEnded`. Returns how long the take-off lasts.
    @discardableResult
    func jumpBegan() -> TimeInterval {
        let catalog = rig.catalog
        guard let name = catalog.input.dropGroup, let group = catalog.groups[name] else {
            dragBegan()
            return 0
        }
        perform(.group(name, in: catalog), at: clock())
        return group.start.compactMap { catalog.clips[$0]?.duration }.reduce(0, +)
    }

    /// The landing: the jump group's end (JumpEnd).
    func jumpEnded() {
        guard rig.catalog.input.dropGroup != nil else { return dragEnded() }
        current?.release(on: rig, at: clock())
    }

    func dragEnded() {
        let input = rig.catalog.input
        if let group = input.dropGroup, group == input.dragGroup {
            // Held in the group's loop (e.g. JumpLoop); letting go plays its end (JumpEnd).
            current?.release(on: rig, at: clock())
        } else if let group = input.dropGroup {
            perform(.group(group, in: rig.catalog, loops: 1), at: clock())
        } else if rig.catalog.input.dragGroup != nil {
            // Without a landing, end the carry and settle back to the baseline.
            current?.interrupt(on: rig, at: clock())
        }
    }

    /// Ends whatever is holding in a loop (a walk steered from outside, say) and moves on.
    func release() {
        current?.release(on: rig, at: clock())
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .loop, let current, !currentIsBaseline,
           let entry = (rig.catalog.surprisePool + rig.catalog.locomotion.map { Catalog.PoolEntry(clip: $0.clip, group: nil) })
               .first(where: { $0.name == current.name || "Wander (\($0.name))" == current.name }) {
            // Keep whatever surprise is showing as the thing to loop.
            loopSelection = entry
        }
        if newMode == .random { scheduleSurprise(from: clock()) }
        perform(baseline(), asBaseline: true, at: clock())
    }

    func pause() {
        guard pausedAt == nil else { return }
        pausedAt = clock()
    }

    func resume() {
        guard let pausedAt else { return }
        let paused = clock() - pausedAt
        current?.shift(by: paused)
        rig.motion.shift(by: paused)
        nextSurprise += paused
        if watchOverlayUntil > 0 { watchOverlayUntil += paused }
        self.pausedAt = nil
    }

    // MARK: Sequencing

    private func perform(_ sequence: ClipSequence, asBaseline: Bool = false, at now: TimeInterval) {
        guard let current, !current.isFinished else {
            start(sequence, baseline: asBaseline, at: now)
            return
        }
        current.interrupt(on: rig, at: now)
        if current.isFinished {
            start(sequence, baseline: asBaseline, at: now)
        } else {
            pending = (sequence, asBaseline)
        }
    }

    private func start(_ sequence: ClipSequence, baseline: Bool, at now: TimeInterval) {
        let wasBaseline = currentIsBaseline
        current = sequence
        currentIsBaseline = baseline
        sequence.start(on: rig, at: now)
        updateWatching()
        // Depth is a travel effect: settling back into idle eases the pet back to
        // neutral depth, so pets always rest at their true relative sizes.
        if baseline, !sequence.travels {
            rig.actor.setDepth(0, over: 2.5)
        }
        // The surprise clock restarts each time the pet settles back into idle.
        if baseline, !wasBaseline || !nextSurprise.isFinite { scheduleSurprise(from: now) }
        onChange?(sequence.name)
    }

    private func scheduleSurprise(from now: TimeInterval) {
        guard let range = surpriseInterval else {
            nextSurprise = .infinity
            return
        }
        nextSurprise = now + Double.random(in: range)
    }

    private func baseline() -> ClipSequence {
        switch mode {
        case .random:
            return .single(rig.catalog.idleClip, loops: nil, side: 1)
        case .loop:
            // Non-looping clips replay one pass at a time so each restart crossfades;
            // locomotion keeps wandering back and forth.
            if let clip = loopSelection.clip, !rig.catalog.isLocomotion(clip) {
                return .single(clip, loops: rig.catalog.clip(clip).loop ? nil : 1, side: rig.preferredSide(for: clip))
            }
            return sequence(for: loopSelection, loops: nil)
        }
    }

    static let watchSeconds: ClosedRange<Double> = 8...15

    /// Idles while following the cursor for 8–15 seconds.
    func watchCursor() -> ClipSequence {
        let idle = rig.catalog.idleClip
        let seconds = Double.random(in: Self.watchSeconds)
        let loops = max(1, Int((seconds / rig.catalog.clip(idle).duration).rounded()))
        let sequence = ClipSequence(name: "Watch Cursor", steps: [Step(clip: idle, loops: loops)], side: 1)
        sequence.watchesCursor = true
        return sequence
    }

    /// In random mode, starts a watching spell. In loop mode the loop keeps playing
    /// and the head follows the cursor on top of it for the same 8–15 seconds.
    /// Either way it works even when watching is set to Never, since it was asked for.
    func watchCursorNow() {
        if mode == .loop {
            watchOverlayUntil = clock() + Double.random(in: Self.watchSeconds)
            updateWatching()
        } else {
            let sequence = watchCursor()
            sequence.requested = true
            perform(sequence, at: clock())
        }
    }

    private func updateWatching() {
        let spell = current?.watchesCursor ?? false
        rig.look.isWatching = watch == .always || (watch == .occasionally && spell)
            || (spell && current?.requested == true) || watchOverlayUntil > 0
    }

    private func surprise() -> ClipSequence {
        if watch == .occasionally, rig.look.isAvailable, Double.random(in: 0..<1) < Self.watchChance {
            return watchCursor()
        }
        if !rig.motion.isPinned, Double.random(in: 0..<1) < rig.catalog.wander.chance, let trip = wander() {
            return trip
        }
        let pool = rig.catalog.surprisePool
        let fitting = pool.filter { entry in entry.clip.map(rig.hasRoom(for:)) ?? true }
        let choices = fitting.count > 1 ? fitting.filter { $0 != lastSurprise } : fitting
        let entry = choices.randomElement() ?? Catalog.PoolEntry(clip: rig.catalog.idleClip, group: nil)
        lastSurprise = entry
        return sequence(for: entry, loops: randomLoops())
    }

    /// `loops == nil` repeats forever (loop mode); otherwise the sequence is sized
    /// to last at least the surprise minimum.
    private func sequence(for entry: Catalog.PoolEntry, loops: Int?) -> ClipSequence {
        let catalog = rig.catalog
        let minimum = catalog.surprise.minSeconds
        if let group = entry.group, let definition = catalog.groups[group] {
            let loopClip = catalog.clip(definition.loop)
            let count = loops.map { requested in
                definition.loopCount.map { Int.random(in: $0[0]...$0[1]) } ?? max(requested, Self.passes(loopClip, minimum))
            }
            return .group(group, in: catalog, loops: count)
        }
        let name = entry.name
        let clip = catalog.clip(name)
        if catalog.isLocomotion(name) {
            return wander(using: name) ?? .single(name, loops: loops)
        }
        if clip.loop {
            return .single(name, loops: loops.map { max($0, Self.passes(clip, minimum)) })
        }
        // One-shot clips repeat as separate passes so each restart crossfades.
        // Clips that travel on screen play once.
        let travels = (clip.rootTravel?.scale ?? 0) != 0
        let passes = loops == nil || travels ? 1 : Self.passes(clip, minimum)
        return ClipSequence(name: name, steps: Array(repeating: Step(clip: name, loops: 1), count: passes),
                            side: rig.preferredSide(for: name))
    }

    private static func passes(_ clip: Catalog.Clip, _ minimum: Double) -> Int {
        max(1, Int((minimum / max(clip.duration, 0.1)).rounded(.up)))
    }

    /// A trip across the screen on a locomotion clip, or nil when there's no room.
    private func wander(using name: String? = nil) -> ClipSequence? {
        let catalog = rig.catalog
        guard let name = name ?? catalog.locomotion.pickWeighted(),
              let speed = catalog.clip(name).groundSpeed else { return nil }
        let settings = catalog.wander
        // Pinned pets walk on the spot, so any trip fits.
        let room = rig.motion.isPinned ? (left: Double.infinity, right: Double.infinity) : rig.motion.room()
        let margin = rig.edgeMargin(for: name)
        let shortest = settings.minDistanceMetres
        let sides = [(-1.0, room.left - margin), (1.0, room.right - margin)].filter { $0.1 >= shortest }
        guard !sides.isEmpty else { return nil }
        // Favour the side with more space, so the pet drifts back from the edges.
        let total = sides.reduce(0) { $0 + min($1.1, 20) }
        var roll = Double.random(in: 0..<max(total, 0.001))
        let (side, space) = sides.first { roll -= min($0.1, 20); return roll < 0 } ?? sides[0]

        var seconds = Double.random(in: settings.seconds[0]...settings.seconds[1])
        if let limit = catalog.locomotion.first(where: { $0.clip == name })?.maxSeconds {
            seconds = min(seconds, limit)
        }
        let distance = max(shortest, min(speed * seconds, space))
        let depth = rig.actor.depth
        let depthTo = !rig.motion.isPinned && !rig.motion.holdsDepth && Double.random(in: 0..<1) < settings.depthChance
            ? Double.random(in: PetActor.depthRange) : depth
        let travel = Step.Travel(dx: side * distance, depthTo: depthTo, speed: speed)
        return ClipSequence(name: "Wander (\(name))", steps: [Step(clip: name, loops: nil, travel: travel)], side: side)
    }

    private func randomLoops() -> Int {
        let range = rig.catalog.surprise.loopCount
        return Int.random(in: range[0]...range[1])
    }
}
