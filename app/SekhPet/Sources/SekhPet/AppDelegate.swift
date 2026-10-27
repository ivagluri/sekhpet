import AppKit
import IOKit.ps
import SceneKit

/// Lists the available pet packs, places the chosen ones on the desktop, and owns
/// the settings they share: size, surprise interval and pausing. Each pet's own
/// window and behavior live in `PetController`, created only while it is placed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Defaults {
        static let size = "petSize"
        static let interval = "surpriseInterval"
        static let enabled = "enabledPets"
        static let watch = "watchCursor"
        static let wander = "wander"
        static let powerSaving = "powerSaving"
        static let house = "petHouse"
        static let randomPicks = "randomPets"
        static let randomShuffled = "randomPetsShuffled"
    }

    private var packs: [PetPack] = []
    private var pets: [PetController] = []
    private var picker: PetPickerModel!
    private var pickerWindow: PetPickerWindow?
    private var menu: StatusMenu!
    private var displayLink: CADisplayLink?
    private var userPaused = false
    private var wander = UserDefaults.standard.object(forKey: Defaults.wander) as? Bool ?? true
    private var relaunching = false
    private var house: PetHouse?
    private var viewer: PetViewerWindow?
    private var size = PetSize(rawValue: UserDefaults.standard.string(forKey: Defaults.size) ?? "") ?? .medium
    /// The pets out by chance (the rest of `pets` were switched on), and the ones waiting to be swapped out.
    private var randomPicks: [String] = []
    private var swapQueue: [String] = []
    /// Recently swapped-out pets, so a shuffle doesn't bring one straight back.
    private var recentlyOut: [String] = []
    private var shuffleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPacks()
        let enabled = savedEnabled()
        picker = PetPickerModel(packs: packs, enabled: enabled)
        picker.setEnabled = { [unowned self] name, on in setEnabled(name, on) }
        picker.trash = { [unowned self] in trash($0) }
        picker.rescan = { [unowned self] in rescan() }
        picker.randomChanged = { [unowned self] in fillRandom() }
        picker.shuffleNow = { [unowned self] in shuffleRandom(staggered: false) }
        for pack in packs.filter({ enabled.contains($0.name) }).prefix(PetLibrary.maxOut) { place(pack) }
        startRandom()
        menu = StatusMenu(pets: { [unowned self] in pets }, actions: menuActions())
        // With nothing installed, start where pets get added.
        if packs.isEmpty { showPicker() }
        observeSystem()
        ClaudeWatch.shared.start()
        if UserDefaults.standard.bool(forKey: Defaults.house) { setHouse(true) }

        // Behavior and window movement run on the display's refresh, so walking is smooth.
        displayLink = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(frame))
        displayLink?.add(to: .main, forMode: .common)
        applyPowerSaving()
    }

    @objc private func frame() {
        let now = CACurrentMediaTime()
        for pet in pets { pet.frame(at: now) }
        house?.frame(at: now)
        viewer?.frame(at: now)
    }

    // MARK: Pet House

    /// Moves every pet into the Pet House window, or back out to the desktop.
    private func setHouse(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Defaults.house)
        if on {
            if house == nil {
                let house = PetHouse()
                house.onClose = { [unowned self] in setHouse(false) }
                house.lowPower = lowPower
                house.setPaused(userPaused)
                for pet in pets { house.add(pet) }
                self.house = house
            }
            house?.show()
        } else {
            house?.onClose = nil
            house?.close()
            house = nil
        }
    }

    // MARK: Pet library

    private func loadPacks() {
        packs = PetLibrary.packDirectories().compactMap { directory in
            do {
                return try PetPack(directory: directory)
            } catch {
                NSLog("SekhPet: skipping pet pack %@: %@", directory.lastPathComponent, error.localizedDescription)
                return nil
            }
        }
        .sorted { $0.displayName < $1.displayName }
    }

    /// Re-reads the pets folder; pets whose packs have gone leave the desktop.
    private func rescan() {
        loadPacks()
        for pet in pets where !packs.contains(where: { $0.name == pet.name }) {
            setEnabled(pet.name, false)
        }
        fillRandom()
        picker.update(packs: packs, enabled: Set(fixedNames), random: Set(randomPicks))
    }

    private func showPicker() {
        if pickerWindow == nil { pickerWindow = PetPickerWindow(model: picker) }
        pickerWindow?.show()
    }

    private func trash(_ pack: PetPack) {
        let alert = NSAlert()
        alert.messageText = "Move \(pack.displayName) to the Trash?"
        alert.informativeText = "Its pack folder goes to the Trash, so you can put it back from there. It will also be taken off the desktop."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setEnabled(pack.name, false)
        do {
            try PetLibrary.trash(pack.directory)
        } catch {
            NSAlert(error: error).runModal()
        }
        rescan()
    }

    // MARK: Placing pets

    /// The pets saved as on the desktop; before the picker existed, every pack was.
    private func savedEnabled() -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: Defaults.enabled) {
            return Set(saved)
        }
        return Set(packs.map(\.name))
    }

    /// Switches a pet on (it stays out) or off. A random pet switched on is kept: it stops being random and
    /// another is drawn for its slot. Switching one on when every slot is taken frees a random one first.
    private func setEnabled(_ name: String, _ on: Bool) {
        if on, let index = randomPicks.firstIndex(of: name) {
            randomPicks.remove(at: index)
        } else if on, !pets.contains(where: { $0.name == name }) {
            if pets.count >= PetLibrary.maxOut, let spare = randomPicks.last { takeOut(spare) }
            if pets.count >= PetLibrary.maxOut {
                tellAboutCap()
            } else if let pack = packs.first(where: { $0.name == name }) {
                place(pack)
            }
        } else if !on, pets.contains(where: { $0.name == name }) {
            takeOut(name)
        }
        fillRandom()
        saveOut()
    }

    /// The pets switched on, in the order they came out.
    private var fixedNames: [String] { pets.map(\.name).filter { !randomPicks.contains($0) } }

    private func saveOut() {
        UserDefaults.standard.set(fixedNames, forKey: Defaults.enabled)
        UserDefaults.standard.set(randomPicks, forKey: Defaults.randomPicks)
        picker?.refresh(enabled: Set(fixedNames), random: Set(randomPicks))
    }

    /// Puts a pet away, switched on or random.
    private func takeOut(_ name: String) {
        if let index = randomPicks.firstIndex(of: name) {
            randomPicks.remove(at: index)
            remember(name)
        }
        swapQueue.removeAll { $0 == name }
        guard let index = pets.firstIndex(where: { $0.name == name }) else { return }
        house?.remove(pets[index])
        pets.remove(at: index).close()
    }

    // MARK: Random pets

    /// How many random pets there should be: the count asked for, in the slots left by pets switched on.
    private var randomTarget: Int { max(0, min(picker.randomCount, PetLibrary.maxOut - fixedNames.count)) }

    /// The pets a random slot can draw: the favourites when asked (every pet while none are starred), less
    /// those out already and those just swapped out (unless that leaves nothing).
    private func randomPool() -> [PetPack] {
        let out = Set(pets.map(\.name))
        var pool = packs.filter { !out.contains($0.name) }
        if picker.randomFavoritesOnly {
            let starred = pool.filter { picker.favorites.contains($0.name) }
            if !starred.isEmpty || !picker.favorites.isEmpty { pool = starred }
        }
        let fresh = pool.filter { !recentlyOut.contains($0.name) }
        return fresh.isEmpty ? pool : fresh
    }

    private func remember(_ name: String) {
        recentlyOut.removeAll { $0 == name }
        recentlyOut.append(name)
        if recentlyOut.count > PetLibrary.maxOut * 2 { recentlyOut.removeFirst() }
    }

    /// Brings random pets out or puts them away until there are as many as asked for.
    private func fillRandom() {
        guard picker != nil else { return }
        while randomPicks.count > randomTarget, let name = randomPicks.last { takeOut(name) }
        while randomPicks.count < randomTarget, let pack = randomPool().randomElement() {
            let before = pets.count
            place(pack)
            guard pets.count > before else { break }
            randomPicks.append(pack.name)
        }
        saveOut()
    }

    /// Restores the last random picks, or draws new ones when they change at each launch; then keeps
    /// an eye on the clock for hourly and daily shuffles.
    private func startRandom() {
        let saved = UserDefaults.standard.stringArray(forKey: Defaults.randomPicks) ?? []
        if picker.shuffleInterval != .launch {
            for name in saved where randomPicks.count < randomTarget && !pets.contains(where: { $0.name == name }) {
                guard let pack = packs.first(where: { $0.name == name }) else { continue }
                place(pack)
                if pets.contains(where: { $0.name == name }) { randomPicks.append(name) }
            }
        } else {
            recentlyOut = saved
        }
        fillRandom()
        shuffleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shuffleIfDue() }
        }
    }

    private func shuffleIfDue() {
        guard let period = picker.shuffleInterval.seconds, !randomPicks.isEmpty, swapQueue.isEmpty else { return }
        let last = UserDefaults.standard.object(forKey: Defaults.randomShuffled) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= period { shuffleRandom(staggered: true) }
    }

    /// Swaps every random pet for a new one: now, or one at a time a few minutes apart.
    private func shuffleRandom(staggered: Bool) {
        UserDefaults.standard.set(Date(), forKey: Defaults.randomShuffled)
        swapQueue = randomPicks
        if staggered { swapNext() } else { while !swapQueue.isEmpty { swapOne() } }
    }

    private func swapNext() {
        guard !swapQueue.isEmpty else { return }
        swapOne()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.swapNext() }
    }

    private func swapOne() {
        let name = swapQueue.removeFirst()
        guard randomPicks.contains(name) else { return }
        takeOut(name)
        fillRandom()
    }

    private var capAlertShowing = false

    /// Once, however many pets were refused at a time (the Pets window's All button asks for each).
    private func tellAboutCap() {
        guard !capAlertShowing else { return }
        capAlertShowing = true
        DispatchQueue.main.async { [self] in
            let alert = NSAlert()
            alert.messageText = "Up to \(PetLibrary.maxOut) pets can be out at once"
            alert.informativeText = "Each pet out takes memory and drawing time. Put one away to bring out another."
            alert.runModal()
            capAlertShowing = false
        }
    }

    private func place(_ pack: PetPack) {
        do {
            let pet = try PetController(assets: pack.directory, index: pets.count, size: size)
            pet.engine.surpriseInterval = interval?.seconds ?? pet.engine.surpriseInterval
            if userPaused { pet.setPaused(true, .user) }
            pet.wanderAllowed = wander
            pet.lowPower = lowPower
            pet.defaultWatch = watch
            pet.onRenderStuck = { [unowned self] in relaunch() }
            pet.contextMenu = { [unowned self, unowned pet] in menu.contextMenu(for: pet) }
            pets.append(pet)
            house?.add(pet)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't load \(pack.displayName)"
            alert.runModal()
        }
    }

    private var watch: BehaviorEngine.Watch {
        BehaviorEngine.Watch(rawValue: UserDefaults.standard.string(forKey: Defaults.watch) ?? "") ?? .occasionally
    }

    private var interval: SurpriseInterval? {
        if let saved = UserDefaults.standard.string(forKey: Defaults.interval) {
            return SurpriseInterval(rawValue: saved)
        }
        return nil
    }

    /// Forgets every setting, shared and per pet, and every position, keeping only which
    /// pets are out; then starts afresh. Launch at Login is the system's, and stays.
    private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset SekhPet to its defaults?"
        alert.informativeText = "Every setting goes back to its default, for all pets, and the pets return to the bottom of the screen. The pets you have out stay out."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, let domain = Bundle.main.bundleIdentifier else { return }
        let enabled = fixedNames
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.set(enabled, forKey: Defaults.enabled)
        relaunch(reason: "to reset its settings")
    }

    /// Last resort when a pet's rendering can't be restarted in this process:
    /// a fresh copy of the app renders normally.
    private func relaunch(reason: String = "to restore rendering") {
        guard !relaunching, Bundle.main.bundleURL.pathExtension == "app" else { return }
        relaunching = true
        NSLog("SekhPet: relaunching %@", reason)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { NSLog("SekhPet: relaunch failed: %@", error.localizedDescription) } else { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Low Power

    private var powerSaving: PowerSaving {
        PowerSaving(rawValue: UserDefaults.standard.string(forKey: Defaults.powerSaving) ?? "") ?? .automatic
    }

    private var lowPower: Bool {
        switch powerSaving {
        case .always: true
        case .never: false
        case .automatic: ProcessInfo.processInfo.isLowPowerModeEnabled || Self.onBattery
        }
    }

    private static var onBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info).takeRetainedValue() as String == kIOPMBatteryPowerKey
    }

    /// Pets draw at 20 fps without anti-aliasing, and windows move at 30 Hz instead of 60.
    private func applyPowerSaving() {
        let low = lowPower
        for pet in pets { pet.lowPower = low }
        house?.lowPower = low
        displayLink?.preferredFrameRateRange = low ? CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
                                                   : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    private static let powerSourceChanged = Notification.Name("SekhPetPowerSourceChanged")

    private func observeSystem() {
        // Automatic Low Power follows the power source and macOS Low Power Mode.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: AppDelegate.powerSourceChanged, object: nil)
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        for name in [Self.powerSourceChanged, Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPowerSaving() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let away: @MainActor (Bool, PetController.PauseReason) -> Void = { [weak self] on, reason in
            for pet in self?.pets ?? [] { pet.setPaused(on, reason) }
            self?.house?.setAway(on, reason)
        }
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { away(asleep, .screensAsleep) }
            }
        }
        // Locked or switched away from, other apps' windows leave the window list: perched pets
        // would take their window for closed.
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { away(locked, .locked) }
            }
        }
        for (name, gone) in [(NSWorkspace.sessionDidResignActiveNotification, true),
                             (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { away(gone, .locked) }
            }
        }
    }

    private func menuActions() -> StatusMenu.Actions {
        StatusMenu.Actions(
            togglePaused: { [unowned self] in
                userPaused.toggle()
                for pet in pets { pet.setPaused(userPaused, .user) }
                house?.setPaused(userPaused)
            },
            toggleWander: { [unowned self] in
                wander.toggle()
                UserDefaults.standard.set(wander, forKey: Defaults.wander)
                for pet in pets { pet.wanderAllowed = wander }
            },
            setSize: { [unowned self] newSize in
                size = newSize
                UserDefaults.standard.set(newSize.rawValue, forKey: Defaults.size)
                for pet in pets { pet.defaultSize = newSize }
            },
            setInterval: { [unowned self] interval in
                UserDefaults.standard.set(interval.rawValue, forKey: Defaults.interval)
                for pet in pets { pet.engine.surpriseInterval = interval.seconds }
            },
            setWatch: { [unowned self] watch in
                UserDefaults.standard.set(watch.rawValue, forKey: Defaults.watch)
                for pet in pets { pet.defaultWatch = watch }
            },
            watch: { [unowned self] in watch },
            setPowerSaving: { [unowned self] saving in
                UserDefaults.standard.set(saving.rawValue, forKey: Defaults.powerSaving)
                applyPowerSaving()
            },
            powerSaving: { [unowned self] in powerSaving },
            choosePets: { [unowned self] in showPicker() },
            toggleHouse: { [unowned self] in setHouse(house == nil) },
            showViewer: { [unowned self] in
                if viewer == nil { viewer = PetViewerWindow() }
                viewer?.show(packs: packs)
            },
            isHouseOpen: { [unowned self] in house != nil },
            resetToDefaults: { [unowned self] in resetToDefaults() },
            removePet: { [unowned self] in setEnabled($0, false) },
            shuffleRandom: { [unowned self] in shuffleRandom(staggered: false) },
            hasRandom: { [unowned self] in !randomPicks.isEmpty },
            isPaused: { [unowned self] in userPaused },
            wanders: { [unowned self] in wander },
            size: { [unowned self] in size },
            interval: { [unowned self] in interval ?? .normal }
        )
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "SekhPet"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}
