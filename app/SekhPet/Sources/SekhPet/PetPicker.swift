import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A pet pack that is available, whether or not it is on the desktop. Reading
/// one only decodes its catalog; the model and animations load when it is placed.
struct PetPack: Identifiable {
    let directory: URL
    let name: String
    let displayName: String
    let paldeckNo: String?
    /// On-screen standing height in metres, after the game's mesh scale.
    let height: Double
    /// Animations to pick from, as the Pet Viewer lists them (a start/loop/end group counts once).
    let animationCount: Int
    let thumbnail: NSImage?

    var id: String { name }

    init(directory: URL) throws {
        let catalog = try Catalog.load(from: directory)
        self.directory = directory
        name = catalog.name
        displayName = catalog.displayName
        paldeckNo = catalog.paldeckNo
        height = catalog.clip(catalog.idleClip).bounds.max[1] * catalog.meshScale
        animationCount = ViewerAnimation.list(for: catalog).count
        thumbnail = NSImage(contentsOf: directory.appendingPathComponent("thumbnail.png"))
    }
}

/// State behind the picker window; `setEnabled` places or removes a pet,
/// `trash` deletes its pack, and `rescan` re-reads the pets folder.
@MainActor
@Observable
final class PetPickerModel {
    private(set) var packs: [PetPack]
    private(set) var enabled: Set<String>
    @ObservationIgnored var setEnabled: (String, Bool) -> Void = { _, _ in }
    @ObservationIgnored var trash: (PetPack) -> Void = { _ in }
    @ObservationIgnored var rescan: () -> Void = {}

    init(packs: [PetPack], enabled: Set<String>) {
        self.packs = packs
        self.enabled = enabled
    }

    func update(packs: [PetPack], enabled: Set<String>) {
        self.packs = packs
        self.enabled = enabled
    }

    func openFolder() { NSWorkspace.shared.open(PetLibrary.folder) }

    func reveal(_ pack: PetPack) { NSWorkspace.shared.activateFileViewerSelecting([pack.directory]) }

    func toggle(_ name: String, on: Bool) {
        if on { enabled.insert(name) } else { enabled.remove(name) }
        setEnabled(name, on)
    }

    /// Keeps the list in step when a pet is removed from the menu instead.
    func refresh(enabled: Set<String>) { self.enabled = enabled }

    // MARK: Adding and exporting

    func chooseToAdd() {
        let panel = NSOpenPanel()
        panel.message = "Choose pet zips (one pet each) or pet folders to add."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Checks what was chosen or dropped, asks once, then installs the pets that passed.
    func add(_ urls: [URL]) {
        Task {
            let scan = await PetImport.scan(urls)
            defer { for folder in scan.scratch { try? FileManager.default.removeItem(at: folder) } }
            var incoming: [String: PetPack] = [:]
            for found in scan.found {
                if let pack = try? PetPack(directory: found.directory) { incoming[pack.name] = pack }
            }
            let packs = incoming.values.sorted { $0.displayName < $1.displayName }
            guard confirm(packs, problems: scan.problems) else { return }

            var replacedOnDesktop: [String] = []
            var failures: [String] = []
            for pack in packs {
                let existing = self.packs.first { $0.name == pack.name }
                do {
                    try PetImport.install(pack, replacing: existing)
                    if existing != nil, enabled.contains(pack.name) { replacedOnDesktop.append(pack.name) }
                } catch {
                    failures.append("\(pack.displayName): \(error.localizedDescription)")
                }
            }
            rescan()
            // A placed pet keeps its old pack loaded; put it back to load the new one.
            for name in replacedOnDesktop {
                setEnabled(name, false)
                setEnabled(name, true)
            }
            if !failures.isEmpty { report("Some pets couldn't be added", failures) }
        }
    }

    private func confirm(_ packs: [PetPack], problems: [String]) -> Bool {
        guard !packs.isEmpty else {
            report("Nothing to add", problems)
            return false
        }
        let alert = NSAlert()
        alert.messageText = packs.count == 1 ? "Add \(packs[0].displayName)?" : "Add \(packs.count) pets?"
        var lines = packs.map { pack in
            let replaces = self.packs.contains { $0.name == pack.name } ? " (replaces the one you have)" : ""
            return String(format: "• %@: %.2f m tall, %d animations", pack.displayName, pack.height, pack.animationCount) + replaces
        }
        if !problems.isEmpty { lines += ["", "Not added:"] + problems.map { "• \($0)" } }
        alert.informativeText = lines.joined(separator: "\n")
        if let icon = packs.first?.thumbnail { alert.icon = icon }
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Saves `pack` as `<Name>.zip`, ready to drop into the Pets window on another Mac.
    func export(_ pack: PetPack) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pack.displayName).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PetImport.export(pack, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            report("Couldn't export \(pack.displayName)", [error.localizedDescription])
        }
    }

    private func report(_ title: String, _ lines: [String]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = lines.map { "• \($0)" }.joined(separator: "\n")
        alert.runModal()
    }
}

struct PetPickerView: View {
    @Bindable var model: PetPickerModel
    @State private var search = ""
    @State private var dropTargeted = false

    private var filtered: [PetPack] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.packs }
        return model.packs.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search pets", text: $search).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            if model.packs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pawprint").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No pets installed").font(.headline)
                    Text("Add a pet's zip, or drop it on this window.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add Pet…") { model.chooseToAdd() }
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List(filtered) { pack in
                HStack(spacing: 12) {
                    thumbnail(pack)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.displayName).font(.headline)
                        Text(String(format: "%.2f m tall · %d animations", pack.height, pack.animationCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("On desktop", isOn: Binding(
                        get: { model.enabled.contains(pack.name) },
                        set: { model.toggle(pack.name, on: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Menu {
                        packActions(pack)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.vertical, 4)
                .contextMenu { packActions(pack) }
            }
            }
            Divider()
            HStack {
                Button {
                    model.chooseToAdd()
                } label: {
                    Label("Add Pet…", systemImage: "plus")
                }
                .help("Add a pet from its zip; you can also drop zips on this window")
                Button {
                    model.openFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open Pets Folder (\(PetLibrary.folder.path))")
                Text("\(model.enabled.count) of \(model.packs.count) on the desktop (up to \(PetLibrary.maxOut))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("None") { for pack in filtered where model.enabled.contains(pack.name) { model.toggle(pack.name, on: false) } }
                Button("All") { for pack in filtered where !model.enabled.contains(pack.name) { model.toggle(pack.name, on: true) } }
            }
            .padding(10)
        }
        .frame(minWidth: 360, minHeight: 280)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Label("Drop to add pets", systemImage: "plus.circle").font(.title3))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func packActions(_ pack: PetPack) -> some View {
        Button("Show in Finder") { model.reveal(pack) }
        Button("Export as Zip…") { model.export(pack) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.trash(pack) }
    }

    @ViewBuilder
    private func thumbnail(_ pack: PetPack) -> some View {
        if let image = pack.thumbnail {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "pawprint.fill").foregroundStyle(.secondary))
        }
    }
}

/// The "Pets" window, opened from the menu bar. It rescans the pets folder each
/// time it comes forward, so packs dropped into the folder appear.
@MainActor
final class PetPickerWindow {
    private let window: NSWindow
    private var keyObserver: NSObjectProtocol?

    init(model: PetPickerModel) {
        window = NSWindow(contentViewController: NSHostingController(rootView: PetPickerView(model: model)))
        window.title = "Pets"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 400, height: 460))
        window.isReleasedWhenClosed = false
        window.center()
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                             object: window, queue: .main) { _ in
            MainActor.assumeIsolated { model.rescan() }
        }
    }

    func show() {
        // A menu-bar app has to activate itself for its window to come forward.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
