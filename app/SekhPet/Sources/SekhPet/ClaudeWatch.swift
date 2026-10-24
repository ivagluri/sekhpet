import Foundation

/// Which apps host a Claude Code session that's working, from the state files its hooks
/// write (see the README): each is named for a `claude` process ID and holds "working" or
/// "idle". The hooks rename each new state into place, so watching the folder is enough.
/// A pet standing on a window of one of these apps (a terminal, say) works.
@MainActor
final class ClaudeWatch {
    static let shared = ClaudeWatch()
    static let folder = PetLibrary.folder.deletingLastPathComponent().appendingPathComponent("Claude", isDirectory: true)

    /// Every ancestor process of each working session: its shell, terminal app and so on.
    private(set) var hosts: Set<pid_t> = []
    private var source: DispatchSourceFileSystemObject?
    private var recheck: Timer?

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let descriptor = open(Self.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        reload()
    }

    private func reload() {
        let fm = FileManager.default
        var hosts: Set<pid_t> = []
        for name in (try? fm.contentsOfDirectory(atPath: Self.folder.path)) ?? [] where !name.hasPrefix(".") {
            let file = Self.folder.appendingPathComponent(name)
            guard let pid = pid_t(name), kill(pid, 0) == 0 else {
                try? fm.removeItem(at: file)  // a session that quit without saying so
                continue
            }
            let state = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A session suspended mid-turn (Ctrl-Z) still says working, but isn't.
            if state == "working", Self.process(pid).map { Int32($0.kp_proc.p_stat) } != SSTOP { hosts.formUnion(Self.ancestors(of: pid)) }
        }
        self.hosts = hosts
        // While anything works, look again now and then in case its session dies mid-turn.
        if hosts.isEmpty {
            recheck?.invalidate()
            recheck = nil
        } else if recheck == nil {
            recheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    private static func ancestors(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while current > 1, chain.count < 32 {
            chain.append(current)
            guard let info = process(current) else { break }
            current = info.kp_eproc.e_ppid
        }
        return chain
    }

    private static func process(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
