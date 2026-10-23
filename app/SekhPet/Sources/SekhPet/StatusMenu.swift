import AppKit
import ServiceManagement

enum PetSize: String, CaseIterable {
    case small, medium, large

    var title: String { rawValue.capitalized }

    /// On-screen points per scene metre; the character is about two metres tall.
    var pointsPerMetre: Double {
        switch self {
        case .small: 70
        case .medium: 110
        case .large: 160
        }
    }
}

/// How often a surprise animation interrupts idle.
enum SurpriseInterval: String, CaseIterable {
    case frequent, normal, relaxed, rare, off

    var title: String {
        switch self {
        case .frequent: "Every 30 s – 1 min"
        case .normal: "Every 1 – 3 min"
        case .relaxed: "Every 3 – 5 min"
        case .rare: "Every 5 – 10 min"
        case .off: "Never"
        }
    }

    var seconds: ClosedRange<Double>? {
        switch self {
        case .frequent: 30...60
        case .normal: 60...180
        case .relaxed: 180...300
        case .rare: 300...600
        case .off: nil
        }
    }
}

/// Drawing fewer frames, without anti-aliasing, to spare a slower Mac or the battery.
enum PowerSaving: String, CaseIterable {
    case automatic, always, never

    var title: String {
        switch self {
        case .automatic: "Automatic (on Battery or Low Power Mode)"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// The menu-bar item: one submenu per pet, then settings shared by all pets.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var togglePaused: () -> Void
        var toggleWander: () -> Void
        var setSize: (PetSize) -> Void
        var setInterval: (SurpriseInterval) -> Void
        var setWatch: (BehaviorEngine.Watch) -> Void
        var watch: () -> BehaviorEngine.Watch
        var setPowerSaving: (PowerSaving) -> Void
        var powerSaving: () -> PowerSaving
        var choosePets: () -> Void
        var removePet: (String) -> Void
        var isPaused: () -> Bool
        var wanders: () -> Bool
        var size: () -> PetSize
        var interval: () -> SurpriseInterval
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let pets: () -> [PetController]
    private let actions: Actions

    init(pets: @escaping () -> [PetController], actions: Actions) {
        self.pets = pets
        self.actions = actions
        super.init()
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Desktop pets")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pets = pets()
        if pets.isEmpty {
            menu.addItem(label("No pets on the desktop"))
        }
        for pet in pets {
            menu.addItem(submenu("\(pet.displayName): \(pet.engine.currentName ?? "…")", petMenu(pet)))
        }
        menu.addItem(entry("Choose Pets…", ",") { [actions] in actions.choosePets() })
        menu.addItem(.separator())
        menu.addItem(entry(actions.isPaused() ? "Resume All" : "Pause All", "p") { [actions] in actions.togglePaused() })
        let wander = entry("Wander", "") { [actions] in actions.toggleWander() }
        wander.state = actions.wanders() ? .on : .off
        menu.addItem(wander)

        let intervals = NSMenu()
        for interval in SurpriseInterval.allCases {
            let item = entry(interval.title, "") { [actions] in actions.setInterval(interval) }
            item.state = actions.interval() == interval ? .on : .off
            intervals.addItem(item)
        }
        menu.addItem(submenu("Surprises", intervals))

        let watching = NSMenu()
        for (watch, title) in [(BehaviorEngine.Watch.occasionally, "Occasionally"), (.always, "Always"), (.never, "Never")] {
            let item = entry(title, "") { [actions] in actions.setWatch(watch) }
            item.state = actions.watch() == watch ? .on : .off
            watching.addItem(item)
        }
        menu.addItem(submenu("Watch Cursor", watching))

        let sizes = NSMenu()
        for size in PetSize.allCases {
            let item = entry(size.title, "") { [actions] in actions.setSize(size) }
            item.state = actions.size() == size ? .on : .off
            sizes.addItem(item)
        }
        menu.addItem(submenu("Size", sizes))

        let power = NSMenu()
        for saving in PowerSaving.allCases {
            let item = entry(saving.title, "") { [actions] in actions.setPowerSaving(saving) }
            item.state = actions.powerSaving() == saving ? .on : .off
            power.addItem(item)
        }
        menu.addItem(submenu("Low Power", power))
        menu.addItem(.separator())

        let login = entry("Launch at Login", "") { [weak self] in self?.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(entry("Quit", "q") { NSApp.terminate(nil) })
    }

    private func petMenu(_ pet: PetController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let engine = pet.engine
        if let current = engine.currentName {
            menu.addItem(label("Now: \(current)"))
        }
        if let seconds = engine.secondsUntilSurprise {
            menu.addItem(label("Next surprise in \(Self.format(seconds))"))
        }
        menu.addItem(.separator())

        let modes = NSMenu()
        let random = entry("Random (idle + surprises)", "") { pet.setMode(.random) }
        random.state = engine.mode == .random ? .on : .off
        modes.addItem(random)
        let loop = entry("Loop: \(engine.loopSelection.name)", "") { pet.setMode(.loop) }
        loop.state = engine.mode == .loop ? .on : .off
        modes.addItem(loop)
        menu.addItem(submenu("Mode", modes))
        menu.addItem(wanderItem(pet))
        menu.addItem(submenu(engine.mode == .loop ? "Loop Animation" : "Play Now", playMenu(pet)))
        if pet.stage.rig.look.isAvailable {
            menu.addItem(entry("Watch Cursor Now", "") { pet.engine.watchCursorNow() })
        }
        menu.addItem(entry("Reset Position", "") { pet.resetPosition() })
        menu.addItem(.separator())
        menu.addItem(entry("Remove from Desktop", "") { [actions] in actions.removePet(pet.name) })
        return menu
    }

    /// The pet's right-click menu: just its Wander toggle and removal.
    func contextMenu(for pet: PetController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(wanderItem(pet))
        menu.addItem(.separator())
        menu.addItem(entry("Remove from Desktop", "") { [actions] in actions.removePet(pet.name) })
        return menu
    }

    /// Greyed out while the shared Wander switch pins every pet.
    private func wanderItem(_ pet: PetController) -> NSMenuItem {
        let item = entry("Wander", "") { pet.setPinned(!pet.isPinned) }
        item.state = pet.isPinned ? .off : .on
        item.isEnabled = actions.wanders()
        return item
    }

    /// Idle, every surprise, the travel gaits (one trip, or patrolling in loop
    /// mode), then the input reactions for auditioning.
    private func playMenu(_ pet: PetController) -> NSMenu {
        let menu = NSMenu()
        let catalog = pet.catalog
        let selected = pet.engine.mode == .loop ? pet.engine.loopSelection : nil
        func add(_ entry: Catalog.PoolEntry, _ title: String) {
            let item = self.entry(title, "") { pet.playNow(entry) }
            item.state = entry == selected ? .on : .off
            menu.addItem(item)
        }
        add(Catalog.PoolEntry(clip: catalog.idleClip, group: nil), catalog.idleClip)
        menu.addItem(.separator())
        menu.addItem(label("Surprises"))
        for entry in catalog.surprisePool.sorted(by: { $0.name < $1.name }) {
            add(entry, entry.group != nil ? "\(entry.name) (start → loop → end)" : entry.name)
        }
        menu.addItem(.separator())
        menu.addItem(label("Travel"))
        for clip in catalog.locomotion.map(\.clip) {
            add(Catalog.PoolEntry(clip: clip, group: nil), clip)
        }
        menu.addItem(.separator())
        menu.addItem(label("Reactions"))
        for clip in catalog.input.singleClick.map(\.clip) + [catalog.input.doubleClick].compactMap({ $0 }) {
            add(Catalog.PoolEntry(clip: clip, group: nil), clip)
        }
        return menu
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nThis works only when SekhPet runs from its .app bundle."
            alert.runModal()
        }
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func entry(_ title: String, _ key: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, keyEquivalent: key, handler: handler)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
