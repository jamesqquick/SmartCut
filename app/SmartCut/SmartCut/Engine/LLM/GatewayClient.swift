import Foundation

// MARK: - Gateway configuration

struct GatewayConfig: Sendable {
    let accountId: String
    let gatewayId: String
    let anthropicApiKey: String?
    let gatewayToken: String?

    enum AuthMode { case byok, unified }
    var mode: AuthMode { anthropicApiKey != nil ? .byok : .unified }

    var baseURL: URL {
        URL(string: "https://gateway.ai.cloudflare.com/v1/\(accountId)/\(gatewayId)/anthropic")!
    }

    static func from(_ config: AppConfig) throws -> GatewayConfig {
        guard let accountId = config.cloudflareAccountId, !accountId.isEmpty else {
            throw EngineError.missingCredentials(
                "CLOUDFLARE_ACCOUNT_ID not configured. Open Settings → Credentials.")
        }
        let gatewayId = (config.cfAigGatewayId?.isEmpty == false)
            ? config.cfAigGatewayId! : "default"
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
/// Assembles tool_use input_json_delta pieces into the final tool call payload.
actor GatewayClient {

    let config: GatewayConfig
    private let session: URLSession
    private let timeoutInterval: TimeInterval = 20 * 60  // 20 minutes

    init(config: GatewayConfig) {
        self.config = config
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest  = 20 * 60
        urlConfig.timeoutIntervalForResource = 20 * 60
        self.session = URLSession(configuration: urlConfig)
    }

    // MARK: - Public

    /// Send a message and return the complete assembled Message (tool calls included).
    /// Retries transient stream errors with exponential backoff.
    func sendMessage(
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int = 32_000,
        useAdaptiveThinking: Bool = false
    ) async throws -> AnthropicMessage {
        let maxRetries = 3
        var lastError: Error = EngineError.llmError("No attempts made")
        for attempt in 0...maxRetries {
            do {
                return try await streamFinalMessage(
                    model: model,
                    system: system,
                    messages: messages,
                    tools: tools,
                    maxTokens: maxTokens,
                    useAdaptiveThinking: useAdaptiveThinking
                )
            } catch {
                lastError = error
                if isTransientError(error) && attempt < maxRetries {
                    let delayMs = 1000 * pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
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
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        switch config.mode {
        case .byok:
            request.setValue(config.anthropicApiKey!, forHTTPHeaderField: "x-api-key")
            if let token = config.gatewayToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "cf-aig-authorization")
            }
        case .unified:
            request.setValue("Bearer \(config.gatewayToken!)",
                             forHTTPHeaderField: "cf-aig-authorization")
        }

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EngineError.llmError("Non-HTTP response from gateway")
        }
        guard httpResponse.statusCode == 200 else {
            // Collect error body.
            var errorBody = ""
            for try await byte in asyncBytes {
                errorBody.append(Character(UnicodeScalar(byte)))
            }
            throw EngineError.llmError(
                "HTTP \(httpResponse.statusCode) from AI Gateway: \(errorBody.prefix(500))")
        }

        // Parse SSE and assemble the message.
        return try await parseSSE(asyncBytes)
    }

    // MARK: - SSE parser / message assembler

    private func parseSSE(_ bytes: URLSession.AsyncBytes) async throws -> AnthropicMessage {
        var lineBuffer = ""
        var currentEvent = ""
        var accumulatedDataLines: [String] = []

        // Assembled message fields.
        var messageId: String?
        var stopReason: String?
        var contentBlocks: [ContentBlockState] = []
        var currentBlockIndex: Int = -1

        struct ContentBlockState {
            var type: String       // "text", "tool_use", "thinking"
            var id: String?        // for tool_use
            var name: String?      // for tool_use
            var textAccum: String = ""
            var jsonAccum: String = ""  // input_json_delta pieces
        }

        for try await byte in bytes {
            let char = Character(UnicodeScalar(byte))
            if char == "\n" {
                let line = lineBuffer
                lineBuffer = ""

                if line.isEmpty {
                    // Blank line = dispatch the accumulated event.
                    if currentEvent.isEmpty || currentEvent == "message_stop" {
                        // End of stream; fall through.
                    }
                    let dataStr = accumulatedDataLines.joined(separator: "\n")
                    guard !dataStr.isEmpty,
                          let data = dataStr.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else {
                        currentEvent = ""
                        accumulatedDataLines = []
                        continue
                    }

                    switch currentEvent {
                    case "message_start":
                        if let msg = obj["message"] as? [String: Any] {
                            messageId  = msg["id"] as? String
                            stopReason = msg["stop_reason"] as? String
                        }

                    case "content_block_start":
                        guard let block = obj["content_block"] as? [String: Any],
                              let type = block["type"] as? String else { break }
                        let index = obj["index"] as? Int ?? (contentBlocks.count)
                        currentBlockIndex = index
                        var state = ContentBlockState(type: type)
                        state.id   = block["id"]   as? String
                        state.name = block["name"] as? String
                        if index == contentBlocks.count {
                            contentBlocks.append(state)
                        } else {
                            while contentBlocks.count <= index {
                                contentBlocks.append(ContentBlockState(type: "unknown"))
                            }
                            contentBlocks[index] = state
                        }

                    case "content_block_delta":
                        guard let delta = obj["delta"] as? [String: Any],
                              let deltaType = delta["type"] as? String else { break }
                        let index = obj["index"] as? Int ?? currentBlockIndex
                        guard index >= 0 && index < contentBlocks.count else { break }
                        switch deltaType {
                        case "text_delta":
                            if let text = delta["text"] as? String {
                                contentBlocks[index].textAccum += text
                            }
                        case "input_json_delta":
                            if let partial = delta["partial_json"] as? String {
                                contentBlocks[index].jsonAccum += partial
                            }
                        default:
                            break
                        }

                    case "content_block_stop":
                        break  // nothing extra needed

                    case "message_delta":
                        if let d = obj["delta"] as? [String: Any] {
                            if let sr = d["stop_reason"] as? String { stopReason = sr }
                        }

                    case "error":
                        let errObj = obj["error"] as? [String: Any]
                        let msg = (errObj?["message"] as? String) ?? dataStr
                        throw EngineError.llmError("Anthropic API error: \(msg)")

                    case "ping", "message_stop":
                        break

                    default:
                        break
                    }

                    currentEvent = ""
                    accumulatedDataLines = []
                } else if line.hasPrefix("event: ") {
                    currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data: ") {
                    accumulatedDataLines.append(String(line.dropFirst(6)))
                }
            } else {
                lineBuffer.append(char)
            }
        }

        // Build the AnthropicMessage from assembled state.
        var blocks: [AnthropicContent] = []
        for state in contentBlocks {
            switch state.type {
            case "tool_use":
                if let id = state.id, let name = state.name, !state.jsonAccum.isEmpty {
                    blocks.append(.toolUse(id: id, name: name, inputJSON: state.jsonAccum))
                }
            case "text":
                if !state.textAccum.isEmpty {
                    blocks.append(.text(state.textAccum))
                }
            default:
                break
            }
        }
        return AnthropicMessage(id: messageId ?? "", stopReason: stopReason ?? "", content: blocks)
    }

    // MARK: - Transient error detection

    private func isTransientError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("connection") || msg.contains("reset")
            || msg.contains("timeout")   || msg.contains("network")
            || msg.contains("eof")       || msg.contains("terminated")
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

    /// Find the first tool_use block with the given name and return its parsed input.
    func toolInput<T: Decodable>(name: String, as type: T.Type) throws -> T? {
        for block in content {
            if case .toolUse(_, let n, let json) = block, n == name {
                let data = Data(json.utf8)
                return try JSONDecoder().decode(T.self, from: data)
            }
        }
        return nil
    }
}
