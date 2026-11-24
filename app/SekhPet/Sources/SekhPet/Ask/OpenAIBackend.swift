import Foundation
import os
import Security

/// Any server with the OpenAI chat completions API: llama.cpp, LM Studio, Ollama, vLLM, MLX
/// servers and the like, on this Mac or another. Streams `delta.content` over server-sent events.
///
/// With no model set it answers with the model the server has loaded, or its only model, and
/// never asks for one that isn't loaded: on a server that holds one model at a time, naming
/// another would unload whatever is using it.
struct OpenAIBackend: AskBackend {
    var baseURL: URL
    var apiKey: String?
    /// Empty: automatic, as above.
    var model: String
    var name: String { "Server" }

    /// A server that suspends when idle can take a while to wake on the first packets.
    static let connectTimeout: TimeInterval = 60
    static let answerTimeout: TimeInterval = 300
    /// The most a reply may run to, thinking included: plenty for a quick answer, and it stops a
    /// small model that has started going round in circles.
    static let maxTokens = Int(ProcessInfo.processInfo.environment["SEKHPET_ASK_MAX_TOKENS"] ?? "") ?? 12_000

    /// `http://host:port`, `http://host:port/v1` or with a trailing slash: all the same server.
    static func normalized(_ text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.isEmpty { return nil }
        if !string.contains("://") { string = "http://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        if string.hasSuffix("/v1") { string.removeLast(3) }
        guard let url = URL(string: string), url.host != nil else { return nil }
        return url
    }

    func answer(_ question: String, history: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        let backend = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try await backend.resolveModel()
                    try await backend.stream(question, history: history, model: model) { continuation.yield($0) }
                    continuation.finish()
                } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                    continuation.finish(throwing: AskError.failed("macOS allows plain http:// only to IP addresses and .local names. Use https://, or the server's IP address."))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.connectTimeout
        configuration.timeoutIntervalForResource = Self.answerTimeout
        return URLSession(configuration: configuration)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent(path))
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The models the server offers, and which are loaded where it says so.
    func models() async throws -> [(id: String, loaded: Bool?)] {
        let (data, response) = try await session.data(for: request("models"))
        try check(response, data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw AskError.failed("The server's model list wasn't readable.") }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            // llama.cpp's router says {"status": {"value": "loaded"}}; some servers a plain string.
            let status = (entry["status"] as? [String: Any])?["value"] as? String ?? entry["status"] as? String
            return (id, status.map { $0 == "loaded" })
        }
    }

    private func resolveModel() async throws -> String {
        if !model.isEmpty { return model }
        let models = try await models()
        if let loaded = models.first(where: { $0.loaded == true }) { return loaded.id }
        if models.count == 1 { return models[0].id }
        if models.isEmpty { throw AskError.failed("The server lists no models.") }
        throw AskError.failed("No model is loaded on the server, and it has \(models.count). Pick one in Quick Ask → Server Settings…")
    }

    private func stream(_ question: String, history: [AskTurn], model: String, yield: (String) -> Void) async throws {
        var messages: [[String: String]] = [["role": "system", "content": AskPrompt.system]]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])
        let first = try await complete(messages, model: model, maxTokens: Self.maxTokens, yield: yield)
        guard first.hitLimit else { return }
        guard !first.wroteAnswer, !first.reasoning.isEmpty else {
            throw AskError.failed("Stopped after \(Self.maxTokens.formatted()) tokens without finishing.")
        }
        // Out of room while still thinking: hand the model its own reasoning and ask it to answer now.
        // (Servers that budget thinking themselves do this inside the model; this works on any server.)
        let wrapUp = """
            Your reasoning so far on this question:

            \(first.reasoning.suffix(Self.wrapUpReasoningCharacters))

            You've thought about this enough. Give your best answer now, briefly, without further deliberation. \
            If it can only be approximate, say so.
            """
        let second = try await complete(messages + [["role": "user", "content": wrapUp]], model: model,
                                        maxTokens: Self.wrapUpTokens, yield: yield)
        if second.hitLimit {
            throw AskError.failed(second.wroteAnswer
                ? "Cut short at the length limit."
                : "Stopped after \(Self.maxTokens.formatted()) tokens of thinking without an answer. Try a simpler question, or Claude Code for this one.")
        }
    }

    /// Room for the answer after a wrap-up, and how much of the reasoning goes back to the model.
    static let wrapUpTokens = 3_000
    static let wrapUpReasoningCharacters = 8_000

    /// One streamed completion: the answer goes to `yield` as it arrives, the reasoning is kept.
    private func complete(_ messages: [[String: String]], model: String, maxTokens: Int,
                          yield: (String) -> Void) async throws -> (wroteAnswer: Bool, reasoning: String, hitLimit: Bool) {
        var request = request("chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, "stream": true, "max_tokens": maxTokens,
        ] as [String: Any])

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 4000 { break } }
            try check(response, body)
        }
        var wroteAnswer = false, hitLimit = false
        var reasoning = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = object["error"] { throw AskError.failed(Self.message(from: error)) }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
            if choice["finish_reason"] as? String == "length" { hitLimit = true }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            // Servers name the thinking `reasoning_content` (llama.cpp and most) or `reasoning`.
            if let thought = (delta["reasoning_content"] ?? delta["reasoning"]) as? String { reasoning += thought }
            if let text = delta["content"] as? String, !text.isEmpty {
                wroteAnswer = true
                yield(text)
            }
        }
        return (wroteAnswer, reasoning, hitLimit)
    }

    private func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let detail = object.flatMap { $0["error"] }.map(Self.message(from:))
            ?? String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (detail?.isEmpty == false ? detail! : HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        throw AskError.failed(http.statusCode == 401 ? "The server refused the API key (401)." : "Server error \(http.statusCode): \(text.prefix(300))")
    }

    private static func message(from error: Any) -> String {
        if let error = error as? [String: Any], let message = error["message"] as? String { return message }
        return "\(error)"
    }
}

/// The server's API key, kept in the login keychain rather than in preferences. Read once per
/// launch and kept in memory: each read of an ad-hoc signed app's item can ask for permission.
enum AskKeychain {
    private static let service = "SekhPet Quick Ask"
    private static let account = "server"
    /// nil until read; then the key, or "" for none.
    private static let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static var apiKey: String? {
        get {
            if let cached = cache.withLock({ $0 }) { return cached.isEmpty ? nil : cached }
            let key = stored
            cache.withLock { $0 = key ?? "" }
            return key
        }
        set {
            guard (newValue ?? "") != (apiKey ?? "") else { return }  // unchanged: leave the keychain be
            stored = newValue
            cache.withLock { $0 = newValue ?? "" }
        }
    }

    private static var stored: String? {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
