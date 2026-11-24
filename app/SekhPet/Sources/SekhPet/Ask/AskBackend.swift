import Foundation
import os

/// One turn of a Quick Ask thread.
struct AskTurn: Sendable {
    var question: String
    var answer: String
}

/// Something that answers a question, streaming the answer's text as it arrives.
/// `history` is the thread so far (empty for a one-off question).
protocol AskBackend: Sendable {
    var name: String { get }
    func answer(_ question: String, history: [AskTurn]) -> AsyncThrowingStream<String, Error>
}

enum AskError: LocalizedError {
    case notFound(String)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "Couldn't find \(what)."
        case .failed(let message): message
        case .timedOut: "No answer in time."
        }
    }
}

/// The instructions every backend gets: a plain assistant, kept short for a bubble.
enum AskPrompt {
    static let system = """
        You answer quick questions typed into a small box on the user's Mac desktop. \
        Answer directly and briefly: usually one to four sentences. Use a short list or a code block \
        only when it really helps. No preamble, no follow-up offers. Markdown is fine.
        """

    /// A one-off question as is; a follow-up with the thread before it.
    static func prompt(_ question: String, history: [AskTurn]) -> String {
        guard !history.isEmpty else { return question }
        let earlier = history.map { "User: \($0.question)\n\nAssistant: \($0.answer)" }.joined(separator: "\n\n")
        return "Earlier in this conversation:\n\n\(earlier)\n\nThe user's follow-up question:\n\n\(question)"
    }
}

/// `claude -p`: Claude Code in print mode, with no tools, no settings (so none of the user's
/// hooks run and ClaudeWatch never sees it), no MCP servers and no saved session, from a
/// scratch folder so no project's CLAUDE.md is read. Streams text deltas from stream-json.
struct ClaudeCLIBackend: AskBackend {
    /// A model alias or name; nil uses Claude Code's default.
    var model: String?
    var name: String { "Claude" }

    static let timeout: TimeInterval = 180

    func answer(_ question: String, history: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                         "--no-session-persistence", "--system-prompt", AskPrompt.system]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        arguments.append(AskPrompt.prompt(question, history: history))
        let args = arguments
        return AsyncThrowingStream { continuation in
            let run = CLIRun()
            continuation.onTermination = { _ in run.cancel() }
            Task.detached {
                do {
                    guard let executable = CLILocator.find("claude") else { throw AskError.notFound("the claude command") }
                    try await run.start(executable: executable, arguments: args) { line in
                        switch ClaudeStreamLine.parse(line) {
                        case .text(let text): continuation.yield(text)
                        case .error(let message): throw AskError.failed(message)
                        case .none: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// What a line of `claude -p --output-format stream-json` carries for us.
enum ClaudeStreamLine: Equatable {
    case text(String)
    case error(String)

    static func parse(_ line: String) -> ClaudeStreamLine? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "result":
            guard object["is_error"] as? Bool == true else { return nil }
            return .error((object["result"] as? String) ?? (object["subtype"] as? String) ?? "Claude reported an error.")
        default:
            return nil
        }
    }
}

/// Finds a command-line tool. An app started from Finder or at login doesn't get the shell's
/// PATH, so look in the usual places, then ask a login shell once.
enum CLILocator {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    static func find(_ command: String) -> String? {
        if let known = cache.withLock({ $0[command] }) { return known }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                          "\(home)/.npm-global/bin", "\(home)/bin"].map { "\($0)/\(command)" }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? loginShellLookup(command)
        if let found { cache.withLock { $0[command] = found } }
        return found
    }

    private static func loginShellLookup(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// PATH for child processes: the usual tool folders before whatever the app was given.
    static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", inherited].joined(separator: ":")
    }

    /// A scratch working folder for CLI backends, outside any project.
    static var scratchFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("SekhPet/Ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// One child process, read line by line off the main thread; cancelling or timing out kills it.
final class CLIRun: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(process: Process?, cancelled: Bool)>(uncheckedState: (nil, false))

    func cancel() {
        let process = state.withLock { state -> Process? in
            state.cancelled = true
            return state.process
        }
        if let process, process.isRunning { process.terminate() }
    }

    func start(executable: String, arguments: [String], onLine: (String) throws -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = CLILocator.scratchFolder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CLILocator.searchPath
        // Never let a nested run think it's inside a Claude Code session.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let cancelled = state.withLock { state -> Bool in
            state.process = process
            return state.cancelled
        }
        guard !cancelled else { throw CancellationError() }
        try process.run()

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + ClaudeCLIBackend.timeout, execute: timer)
        defer { timer.cancel() }

        // Collect stderr alongside, so a failing tool can say why.
        let stderrText = OSAllocatedUnfairLock(initialState: Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stderrText.withLock { $0.append(chunk) }
        }
        do {
            for try await line in output.fileHandleForReading.bytes.lines { try onLine(line) }
        } catch {
            process.terminate()
            throw error
        }
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        if timedOut.withLock({ $0 }) { throw AskError.timedOut }
        if process.terminationStatus != 0 {
            let message = String(data: stderrText.withLock { $0 }, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AskError.failed(message.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(process.terminationStatus)." : String(message.suffix(400)))
        }
    }
}
