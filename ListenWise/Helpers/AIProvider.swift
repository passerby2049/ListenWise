/*
Abstract:
Unified AI interface supporting OpenRouter (cloud),
Anthropic Messages-compatible endpoints, and Google AI Studio (Gemini).
*/

import Foundation

// MARK: - AI Provider

struct AIProvider {
    enum Provider: String, CaseIterable, Identifiable {
        case openRouter
        case anthropic
        case googleAI

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .anthropic: return "Anthropic"
            case .googleAI: return "Google AI Studio"
            }
        }
    }

    private static let prefs = AppPreferences()

    static var anthropicBase: URL {
        URL(string: prefs.anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
    }

    static let openRouterBase = URL(string: "https://openrouter.ai/api/v1")!
    static let googleAIBase = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    static var openRouterKey: String { prefs.openRouterAPIKey }

    static var anthropicKey: String { prefs.anthropicAPIKey }

    static var googleAIKey: String { prefs.googleAIAPIKey }

    static let anthropicModels = [
        "claude-opus-4-6",
        "claude-sonnet-4-6",
        "claude-haiku-4-5"
    ]

    static let openRouterModels = [
        "google/gemini-2.5-flash",
        "google/gemini-2.5-flash-lite",
        "google/gemini-3.1-flash-lite-preview",
        "deepseek/deepseek-v3.2",
        "minimax/minimax-m2.7",
        "qwen/qwen3.6-plus:free",
        "google/gemma-3-27b-it:free",
        "minimax/minimax-m2.5:free",
    ]

    /// Google AI Studio models — bare IDs without vendor prefix, which
    /// distinguishes them from OpenRouter's `google/gemini-*` entries.
    /// Text-chat capable models only; image/audio/TTS/embedding variants
    /// aren't applicable to ListenWise's LLM call sites.
    static let googleAIModels = [
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
    ]

    static func provider(for model: String) -> Provider {
        if googleAIModels.contains(model) || (model.hasPrefix("gemini-") && !model.contains("/")) {
            return .googleAI
        }
        if anthropicModels.contains(model) || model.hasPrefix("claude-") {
            return .anthropic
        }
        return .openRouter
    }

    static func models(for provider: Provider) -> [String] {
        switch provider {
        case .openRouter: return openRouterModels
        case .anthropic: return anthropicModels
        case .googleAI: return googleAIModels
        }
    }

    static func anthropicMessagesURL(from baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "v1/messages" {
            return baseURL
        }
        if normalizedPath == "v1" {
            return baseURL.appendingPathComponent("messages")
        }
        return baseURL.appendingPathComponent("v1").appendingPathComponent("messages")
    }

    static var anthropicMessagesURL: URL {
        anthropicMessagesURL(from: anthropicBase)
    }

    static func stream(prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        switch provider(for: model) {
        case .openRouter:
            return streamOpenRouter(prompt: prompt, model: model)
        case .anthropic:
            return streamAnthropic(prompt: prompt, model: model)
        case .googleAI:
            return streamGoogleAI(prompt: prompt, model: model)
        }
    }

    static func translate(text: String, to targetLanguage: String = "中文", model: String) -> AsyncThrowingStream<String, Error> {
        stream(prompt: "将以下文本翻译成\(targetLanguage)，只输出翻译结果，不要解释：\n\n\(text)", model: model)
    }

    static func availableModels() async -> [String] {
        uniqueModels(anthropicModels + openRouterModels + googleAIModels)
    }

    private static func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in models where seen.insert(model).inserted {
            result.append(model)
        }
        return result
    }

    static func errorMessage(from responseBody: String) -> String? {
        guard let data = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return responseBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : responseBody
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        return responseBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : responseBody
    }

    // MARK: - OpenRouter Streaming (OpenAI-compatible)

    private static func streamOpenRouter(prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var request = URLRequest(url: openRouterBase.appendingPathComponent("chat/completions"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(openRouterKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 300
                let body: [String: Any] = [
                    "model": model,
                    "messages": [["role": "user", "content": prompt]],
                    "stream": true
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(domain: "OpenRouter", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
                        return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else {
                            if line.contains("\"error\""), let message = errorMessage(from: line) {
                                continuation.finish(throwing: NSError(domain: "OpenRouter", code: 400, userInfo: [NSLocalizedDescriptionKey: message]))
                                return
                            }
                            continue
                        }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: NSError(domain: "OpenRouter", code: 400, userInfo: [NSLocalizedDescriptionKey: message]))
                            return
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }

                        if let finish = choices.first?["finish_reason"] as? String, !finish.isEmpty {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Anthropic Messages Streaming

    private static func streamAnthropic(prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var request = URLRequest(url: anthropicMessagesURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anthropicKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.timeoutInterval = 300
                let body: [String: Any] = [
                    "model": model,
                    "max_tokens": 4096,
                    "stream": true,
                    "messages": [["role": "user", "content": prompt]]
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(domain: "Anthropic", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
                        return
                    }

                    var currentEvent = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            if currentEvent == "message_stop" {
                                break
                            }
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: NSError(domain: "Anthropic", code: 400, userInfo: [NSLocalizedDescriptionKey: message]))
                            return
                        }

                        let eventType = currentEvent.isEmpty ? (json["type"] as? String ?? "") : currentEvent
                        if eventType == "message_stop" {
                            break
                        }

                        if eventType == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String,
                           !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Google AI Studio (Gemini) Streaming

    private static func streamGoogleAI(prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Gemini path segments contain a literal `:streamGenerateContent`
                // suffix; URLComponents handles the colon correctly, appendingPathComponent
                // would percent-encode it.
                guard let url = URL(string: "\(googleAIBase.absoluteString)/models/\(model):streamGenerateContent?alt=sse") else {
                    continuation.finish(throwing: NSError(domain: "GoogleAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for model \(model)"]))
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(googleAIKey, forHTTPHeaderField: "x-goog-api-key")
                request.timeoutInterval = 300
                let body: [String: Any] = [
                    "contents": [
                        ["role": "user", "parts": [["text": prompt]]]
                    ]
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(domain: "GoogleAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
                        return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: NSError(domain: "GoogleAI", code: 400, userInfo: [NSLocalizedDescriptionKey: message]))
                            return
                        }

                        guard let candidates = json["candidates"] as? [[String: Any]],
                              let content = candidates.first?["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]]
                        else { continue }

                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
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

// MARK: - LLM Response Parsing

/// Extract and decode a JSON array from an LLM response that may be wrapped in markdown fences.
func parseLLMJSON<T: Decodable>(_ raw: String) -> [T]? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "["), let e = jsonStr.lastIndex(of: "]") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([T].self, from: data)
}

/// Extract and decode a JSON object from an LLM response that may be wrapped in markdown fences.
func parseLLMJSONObject<T: Decodable>(_ raw: String) -> T? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "{"), let e = jsonStr.lastIndex(of: "}") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
