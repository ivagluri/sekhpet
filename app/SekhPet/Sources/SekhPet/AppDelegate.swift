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

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPacks()
        let enabled = savedEnabled()
        picker = PetPickerModel(packs: packs, enabled: enabled)
        picker.setEnabled = { [unowned self] name, on in setEnabled(name, on) }
        picker.trash = { [unowned self] in trash($0) }
        picker.rescan = { [unowned self] in rescan() }
        for pack in packs.filter({ enabled.contains($0.name) }).prefix(PetLibrary.maxOut) { place(pack) }
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
        picker.update(packs: packs, enabled: Set(pets.map(\.name)))
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

    private func setEnabled(_ name: String, _ on: Bool) {
        if on, !pets.contains(where: { $0.name == name }), pets.count >= PetLibrary.maxOut {
            tellAboutCap()
        } else if on, !pets.contains(where: { $0.name == name }), let pack = packs.first(where: { $0.name == name }) {
            place(pack)
        } else if !on, let index = pets.firstIndex(where: { $0.name == name }) {
            house?.remove(pets[index])
            pets.remove(at: index).close()
        }
        let names = pets.map(\.name)
        UserDefaults.standard.set(names, forKey: Defaults.enabled)
        picker.refresh(enabled: Set(names))
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
        let enabled = pets.map(\.name)
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
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    for pet in self?.pets ?? [] { pet.setPaused(asleep, .screensAsleep) }
                }
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
