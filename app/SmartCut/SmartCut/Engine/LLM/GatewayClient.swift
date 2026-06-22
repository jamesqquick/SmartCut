import Foundation

// MARK: - Gateway configuration

struct GatewayConfig: Sendable {
    let accountId: String
    let gatewayId: String
    let anthropicApiKey: String?
    let gatewayToken: String?

    enum AuthMode { case byok, unified }
    var mode: AuthMode { anthropicApiKey != nil ? .byok : .unified }

    /// Builds the gateway base URL, percent-encoding user-supplied path components
    /// so special characters in accountId/gatewayId don't produce a crash or a
    /// malformed URL. Returns nil if URLComponents rejects the result.
    var baseURL: URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host   = "gateway.ai.cloudflare.com"
        let encAccount = accountId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? accountId
        let encGateway = gatewayId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? gatewayId
        comps.path = "/v1/\(encAccount)/\(encGateway)/anthropic"
        return comps.url
    }

    static func from(_ config: AppConfig) throws -> GatewayConfig {
        guard let accountId = config.cloudflareAccountId, !accountId.isEmpty else {
            throw EngineError.missingCredentials(
                "CLOUDFLARE_ACCOUNT_ID not configured. Open Settings → Credentials.")
        }
        let gatewayId = config.cfAigGatewayId?.isEmpty == false ? config.cfAigGatewayId! : "default"
        let hasToken     = !(config.cfAigToken ?? "").isEmpty
        let hasAnthropic = !(config.anthropicApiKey ?? "").isEmpty
        guard hasToken || hasAnthropic else {
            throw EngineError.missingCredentials(
                "No API key configured. Set CF_AIG_TOKEN or Anthropic API Key in Settings → Credentials.")
        }
        return GatewayConfig(
            accountId: accountId,
            gatewayId: gatewayId,
            anthropicApiKey: hasAnthropic ? config.anthropicApiKey : nil,
            gatewayToken:    hasToken     ? config.cfAigToken      : nil
        )
    }
}

// MARK: - Anthropic Messages client (URLSession, SSE)

/// Calls Anthropic Messages API via Cloudflare AI Gateway using SSE streaming.
/// Accumulates `input_json_delta` pieces from `tool_use` content blocks into the
/// final tool call payload.
actor GatewayClient {

    let config: GatewayConfig
    private let session: URLSession
    private let timeoutInterval: TimeInterval = 20 * 60  // 20 minutes

    init(config: GatewayConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 20 * 60
        cfg.timeoutIntervalForResource = 20 * 60
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public

    /// Send a message and return the complete assembled Message (tool calls included).
    /// Retries on transient network errors with exponential backoff (up to 3 retries).
    func sendMessage(
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int = 32_000,
        useAdaptiveThinking: Bool = false
    ) async throws -> AnthropicMessage {
        var lastError: Error = EngineError.llmError("No attempts made")
        for attempt in 0...3 {
            do {
                return try await streamFinalMessage(
                    model: model, system: system, messages: messages,
                    tools: tools, maxTokens: maxTokens,
                    useAdaptiveThinking: useAdaptiveThinking)
            } catch {
                lastError = error
                if isTransientError(error) && attempt < 3 {
                    let delayNs = UInt64(1_000_000_000) * UInt64(pow(2.0, Double(attempt)))
                    try await Task.sleep(nanoseconds: delayNs)
                } else {
                    throw error
                }
            }
        }
        throw lastError
    }

    // MARK: - SSE streaming

    private func streamFinalMessage(
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int,
        useAdaptiveThinking: Bool
    ) async throws -> AnthropicMessage {
        guard let baseURL = config.baseURL else {
            throw EngineError.missingCredentials(
                "Invalid Cloudflare account ID or gateway ID — URL could not be constructed.")
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "tools": tools,
            "tool_choice": ["type": "auto"],
            "messages": messages,
            "stream": true,
        ]
        if useAdaptiveThinking {
            body["thinking"] = ["type": "adaptive"]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request  = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody   = bodyData
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")

        switch config.mode {
        case .byok:
            request.setValue(config.anthropicApiKey!, forHTTPHeaderField: "x-api-key")
            if let token = config.gatewayToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "cf-aig-authorization")
            }
        case .unified:
            request.setValue("Bearer \(config.gatewayToken!)", forHTTPHeaderField: "cf-aig-authorization")
        }

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.llmError("Non-HTTP response from gateway")
        }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await byte in asyncBytes { errorBody.append(Character(UnicodeScalar(byte))) }
            throw EngineError.llmError("HTTP \(http.statusCode) from AI Gateway: \(errorBody.prefix(500))")
        }

        return try await parseSSE(asyncBytes)
    }

    // MARK: - SSE parser / message assembler

    private func parseSSE(_ bytes: URLSession.AsyncBytes) async throws -> AnthropicMessage {
        // Buffer raw bytes and decode line-by-line as UTF-8. The previous byte-at-a-time
        // Character(UnicodeScalar(byte)) approach treated each byte as Latin-1, corrupting
        // multi-byte sequences (accented chars, smart quotes) in transcript content.
        var lineBuffer = Data()
        var currentEvent = ""
        var accumulatedData: [String] = []

        var messageId: String?
        var stopReason: String?
        var contentBlocks: [ContentBlockState] = []
        var currentBlockIndex = -1

        struct ContentBlockState {
            var type: String
            var id: String?
            var name: String?
            var textAccum: String = ""
            var jsonAccum: String = ""
        }

        func dispatchEvent(event: String, dataLines: [String]) throws {
            let dataStr = dataLines.joined(separator: "\n")
            guard !dataStr.isEmpty,
                  let data = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            switch event {
            case "message_start":
                if let msg = obj["message"] as? [String: Any] {
                    messageId  = msg["id"] as? String
                    stopReason = msg["stop_reason"] as? String
                }

            case "content_block_start":
                guard let block = obj["content_block"] as? [String: Any],
                      let type  = block["type"] as? String else { break }
                let index = obj["index"] as? Int ?? contentBlocks.count
                currentBlockIndex = index
                var state = ContentBlockState(type: type)
                state.id   = block["id"]   as? String
                state.name = block["name"] as? String
                while contentBlocks.count <= index {
                    contentBlocks.append(ContentBlockState(type: "unknown"))
                }
                contentBlocks[index] = state

            case "content_block_delta":
                guard let delta     = obj["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                let index = obj["index"] as? Int ?? currentBlockIndex
                guard index >= 0, index < contentBlocks.count else { break }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        contentBlocks[index].textAccum += text
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"] as? String {
                        contentBlocks[index].jsonAccum += partial
                    }
                default: break
                }

            case "message_delta":
                if let d = obj["delta"] as? [String: Any],
                   let sr = d["stop_reason"] as? String {
                    stopReason = sr
                }

            case "error":
                let errObj = obj["error"] as? [String: Any]
                let msg = errObj?["message"] as? String ?? dataStr
                throw EngineError.llmError("Anthropic API error: \(msg)")

            case "content_block_stop", "message_stop", "ping": break
            default: break
            }
        }

        for try await byte in bytes {
            if byte == 0x0A {  // LF
                // Decode the line as UTF-8 (not Latin-1). Strip trailing CR for \r\n support.
                var line = String(data: lineBuffer, encoding: .utf8) ?? ""
                lineBuffer.removeAll(keepingCapacity: true)
                if line.hasSuffix("\r") { line.removeLast() }

                if line.isEmpty {
                    // Blank line = dispatch event.
                    try dispatchEvent(event: currentEvent, dataLines: accumulatedData)
                    currentEvent = ""
                    accumulatedData = []
                } else if line.hasPrefix("event: ") {
                    currentEvent = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    accumulatedData.append(String(line.dropFirst(6)))
                }
            } else {
                lineBuffer.append(byte)
            }
        }

        var blocks: [AnthropicContent] = []
        for state in contentBlocks {
            switch state.type {
            case "tool_use":
                if let id = state.id, let name = state.name, !state.jsonAccum.isEmpty {
                    blocks.append(.toolUse(id: id, name: name, inputJSON: state.jsonAccum))
                }
            case "text":
                if !state.textAccum.isEmpty { blocks.append(.text(state.textAccum)) }
            default: break
            }
        }
        return AnthropicMessage(id: messageId ?? "", stopReason: stopReason ?? "", content: blocks)
    }

    // MARK: - Transient error detection

    /// Match on typed URLError codes rather than localised description strings
    /// (which break on non-English macOS).
    private func isTransientError(_ error: Error) -> Bool {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        if let engineErr = error as? EngineError,
           case .llmError(let msg) = engineErr {
            // Catch transient 5xx surfaced as EngineError from the HTTP status check.
            return msg.hasPrefix("HTTP 5") || msg.hasPrefix("HTTP 429")
        }
        return false
    }
}

// MARK: - Message types

enum AnthropicContent: Sendable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
}

struct AnthropicMessage: Sendable {
    let id: String
    let stopReason: String
    let content: [AnthropicContent]

    func toolInput<T: Decodable>(name: String, as type: T.Type) throws -> T? {
        for block in content {
            if case .toolUse(_, let n, let json) = block, n == name {
                return try JSONDecoder().decode(T.self, from: Data(json.utf8))
            }
        }
        return nil
    }
}
