import Foundation
import Network

/// An OpenAI-compatible HTTP server backed by the in-process llama.cpp engine.
///
/// It deliberately imitates the `llama-server` surface (`/health`, `/props`,
/// `/v1/models`, `/v1/chat/completions`) so that `LocalModelManager`, the
/// health checks, the adoption logic and `ProviderRouter` all keep working
/// unchanged — the only difference is that the HTTP hop terminates inside this
/// process instead of in a child process.
///
/// Only starts when the in-process engine is available (arm64). On Intel the
/// caller falls back to spawning `llama-server`.
final class LocalInferenceServer: @unchecked Sendable {

    struct Config {
        var port: UInt16
        var modelPath: String
        var modelAlias: String
        var nCtx: Int32
        var nBatch: Int32
        var nUBatch: Int32
        var nGPULayers: Int32
        var flashAttn: Bool
    }

    private(set) var isRunning = false
    private(set) var loadedPath: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.jxrouter.inference.server", qos: .userInitiated)
    private var cfg: Config?

    // MARK: - Lifecycle

    /// Load the model, then bind the port. Throws if either step fails.
    func start(_ config: Config, onProgress: ((Double) -> Void)? = nil) async throws {
        let engine = InProcessLlamaEngine.shared
        guard engine.isAvailable else {
            throw InProcessLlamaEngine.EngineError.unavailable(
                engine.unavailableReason ?? "engine not bound")
        }

        var params = JXLoadParams()
        params.nCtx = config.nCtx
        params.nBatch = config.nBatch > 0 ? config.nBatch : 2048
        params.nUBatch = config.nUBatch > 0 ? config.nUBatch : 512
        params.nGPULayers = config.nGPULayers
        params.flashAttn = config.flashAttn ? 1 : 0

        try await engine.load(modelPath: config.modelPath, params: params, onProgress: onProgress)
        loadedPath = config.modelPath

        do {
            try bind(port: config.port)
        } catch {
            await engine.unload()
            loadedPath = nil
            throw error
        }
        cfg = config
        isRunning = true
    }

    private func bind(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "LocalInferenceServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        // This endpoint is OpenAI-compatible and carries NO authentication, so it
        // must not be reachable from the network by default. A bare
        // `NWListener(using:on:)` listens on every interface — confirmed with lsof as
        // `TCP *:8081 (LISTEN)` — which hands the loaded model to anyone on the same
        // WiFi, all the more so with the macOS application firewall off. Pin it to
        // loopback unless the user has deliberately opted in.
        //
        // There are two ways to pin the bind: carry the port in the local
        // endpoint and drop `on:`, or leave the endpoint's port at 0 and keep
        // `on:` (the idiom used by ProxyServer.start(port:)). Passing a
        // *specific* port in the endpoint *and* `on:` is the only combination
        // that throws EINVAL — which is what makes the two forms look mutually
        // exclusive when they are not.
        let params = NWParameters.tcp
        let listener: NWListener
        if ConfigManager.shared.ggufExposeOnLAN {
            listener = try NWListener(using: params, on: nwPort)
        } else {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            listener = try NWListener(using: params)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // One queue per connection: a hung client cannot wedge the rest.
            let cq = DispatchQueue(label: "com.jxrouter.inference.conn", qos: .userInitiated)
            connection.start(queue: cq)
            self.beginReading(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        InProcessLlamaEngine.shared.cancel()
        Task { await InProcessLlamaEngine.shared.unload() }
        loadedPath = nil
        cfg = nil
    }

    // MARK: - Reading

    private final class ConnState { var buffer = Data() }

    private func beginReading(_ connection: NWConnection) {
        let state = ConnState()
        readMore(connection, state)
    }

    private func readMore(_ connection: NWConnection, _ state: ConnState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            if let error {
                print("[Inference] receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            guard let data else { connection.cancel(); return }
            state.buffer.append(data)
            if self.tryDispatch(connection, state) {
                return   // response already sent (or connection closed)
            }
            self.readMore(connection, state)
        }
    }

    /// Returns true when the request is complete and handled.
    private func tryDispatch(_ connection: NWConnection, _ state: ConnState) -> Bool {
        let raw = state.buffer
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return false }

        let headerData = raw[raw.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendJSON(connection, status: 400, body: ["error": "bad request"]); return true
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return true }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return true }
        let method = parts[0].uppercased()
        let path = (parts[1].components(separatedBy: "?").first ?? parts[1])

        var contentLength = 0
        for l in lines.dropFirst() {
            if l.lowercased().hasPrefix("content-length:") {
                contentLength = Int(l.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let need = headerEnd.upperBound + contentLength
        guard raw.count >= need else { return false }   // wait for the rest

        let body = Data(raw[bodyStart..<min(need, raw.count)])
        state.buffer = Data()
        handle(method: method, path: path, body: body, connection: connection)
        return true
    }

    // MARK: - Routing

    private func handle(method: String, path: String, body: Data, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/health"):
            sendJSON(connection, status: 200, body: ["status": "ok"])

        case ("GET", "/props"):
            sendJSON(connection, status: 200, body: [
                "model_path": loadedPath ?? "",
                "model_alias": cfg?.modelAlias ?? "",
                "default_generation_settings": ["n_ctx": InProcessLlamaEngine.shared.nCtx]
            ])

        case ("GET", "/v1/models"):
            let alias = cfg?.modelAlias ?? "local"
            sendJSON(connection, status: 200, body: [
                "object": "list",
                "data": [[
                    "id": alias,
                    "object": "model",
                    "created": Int(Date().timeIntervalSince1970),
                    "owned_by": "jxrouter-inprocess"
                ]]
            ])

        case ("POST", "/v1/chat/completions"):
            handleChat(body: body, connection: connection)

        case ("POST", "/v1/completions"):
            handleCompletion(body: body, connection: connection)

        default:
            sendJSON(connection, status: 404, body: ["error": "not found"])
        }
    }

    // MARK: - Chat

    private func handleChat(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            sendJSON(connection, status: 400, body: ["error": "missing messages"])
            return
        }

        var roles: [String] = []
        var texts: [String] = []
        for m in messages {
            let role = m["role"] as? String ?? "user"
            var content = ""
            if let s = m["content"] as? String {
                content = s
            } else if let blocks = m["content"] as? [[String: Any]] {
                content = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            roles.append(role)
            texts.append(content)
        }

        let engine = InProcessLlamaEngine.shared
        let prompt = engine.applyChatTemplate(roles: roles, messages: texts, addAssistant: true)
            ?? fallbackPrompt(roles: roles, texts: texts)

        var s = JXSampling()
        s.temperature = Float((json["temperature"] as? NSNumber)?.floatValue ?? 0.7)
        s.topP = Float((json["top_p"] as? NSNumber)?.floatValue ?? 0.9)
        s.topK = Int32((json["top_k"] as? NSNumber)?.intValue ?? 40)
        s.maxTokens = Int32((json["max_tokens"] as? NSNumber)?.intValue ?? 512)

        let wantsStream = (json["stream"] as? Bool) ?? false
        let modelName = (json["model"] as? String) ?? cfg?.modelAlias ?? "local"

        Task {
            do {
                if wantsStream {
                    try await self.streamChat(prompt: prompt, sampling: s,
                                              model: modelName, connection: connection)
                } else {
                    let (text, tokens) = try await engine.generate(prompt: prompt, sampling: s)
                    let payload: [String: Any] = [
                        "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
                        "object": "chat.completion",
                        "created": Int(Date().timeIntervalSince1970),
                        "model": modelName,
                        "choices": [[
                            "index": 0,
                            "message": ["role": "assistant", "content": text],
                            "finish_reason": "stop"
                        ]],
                        "usage": ["prompt_tokens": 0, "completion_tokens": Int(tokens), "total_tokens": Int(tokens)]
                    ]
                    self.sendJSON(connection, status: 200, body: payload)
                }
            } catch {
                self.sendJSON(connection, status: 500,
                              body: ["error": error.localizedDescription])
            }
        }
    }

    private func streamChat(prompt: String, sampling: JXSampling,
                            model: String, connection: NWConnection) async throws {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-\(UUID().uuidString.prefix(8))"

        // text/event-stream with chunked transfer so URLSession flushes early.
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "\r\n"
        connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })

        func chunk(_ event: String) {
            guard let d = event.data(using: .utf8) else { return }
            var frame = Data()
            frame.append(String(format: "%x\r\n", d.count).data(using: .utf8)!)
            frame.append(d)
            frame.append(Data("\r\n".utf8))
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }

        func delta(_ content: String) -> String {
            let payload: [String: Any] = [
                "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                "choices": [["index": 0, "delta": ["content": content], "finish_reason": NSNull()]]
            ]
            guard let j = try? JSONSerialization.data(withJSONObject: payload),
                  let s = String(data: j, encoding: .utf8) else { return "" }
            return "data: \(s)\n\n"
        }

        _ = try await InProcessLlamaEngine.shared.generate(prompt: prompt, sampling: sampling) { piece in
            chunk(delta(piece))
        }

        let stopPayload: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]
        ]
        if let j = try? JSONSerialization.data(withJSONObject: stopPayload),
           let s = String(data: j, encoding: .utf8) {
            chunk("data: \(s)\n\n")
        }
        chunk("data: [DONE]\n\n")
        // terminate chunked body
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    private func handleCompletion(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            sendJSON(connection, status: 400, body: ["error": "missing prompt"])
            return
        }
        var s = JXSampling()
        s.maxTokens = Int32((json["max_tokens"] as? NSNumber)?.intValue ?? 512)
        let modelName = (json["model"] as? String) ?? cfg?.modelAlias ?? "local"

        Task {
            do {
                let (text, tokens) = try await InProcessLlamaEngine.shared.generate(prompt: prompt, sampling: s)
                let payload: [String: Any] = [
                    "id": "cmpl-\(UUID().uuidString.prefix(8))",
                    "object": "text_completion",
                    "created": Int(Date().timeIntervalSince1970),
                    "model": modelName,
                    "choices": [["text": text, "index": 0, "finish_reason": "stop"]],
                    "usage": ["prompt_tokens": 0, "completion_tokens": Int(tokens), "total_tokens": Int(tokens)]
                ]
                self.sendJSON(connection, status: 200, body: payload)
            } catch {
                self.sendJSON(connection, status: 500, body: ["error": error.localizedDescription])
            }
        }
    }

    private func fallbackPrompt(roles: [String], texts: [String]) -> String {
        zip(roles, texts).map { "\($0): \($1)" }.joined(separator: "\n") + "\nassistant:"
    }

    // MARK: - Responses

    private func sendJSON(_ connection: NWConnection, status: Int, body: [String: Any]) {
        var data = Data()
        if let json = try? JSONSerialization.data(withJSONObject: body) {
            data = json
        } else {
            data = "{}".data(using: .utf8)!
        }
        let reason = status == 200 ? "OK" : (status == 400 ? "Bad Request" : (status == 404 ? "Not Found" : "Internal Server Error"))
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var out = head.data(using: .utf8)!
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }
}
