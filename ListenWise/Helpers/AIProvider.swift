/*
Abstract:
Unified AI interface supporting OpenRouter (cloud) and
Anthropic Messages-compatible endpoints.
*/

import Foundation

// MARK: - AI Provider

struct AIProvider {
    enum Provider {
        case openRouter
        case anthropic
    }

    private static let prefs = AppPreferences()

    static var anthropicBase: URL {
        URL(string: prefs.anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
    }

    static let openRouterBase = URL(string: "https://openrouter.ai/api/v1")!

    static var openRouterKey: String { prefs.openRouterAPIKey }

    static var anthropicKey: String { prefs.anthropicAPIKey }

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

    static func provider(for model: String) -> Provider {
        if anthropicModels.contains(model) || model.hasPrefix("claude-") {
            return .anthropic
        }
        return .openRouter
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
        }
    }

    static func translate(text: String, to targetLanguage: String = "中文", model: String) -> AsyncThrowingStream<String, Error> {
        stream(prompt: "将以下文本翻译成\(targetLanguage)，只输出翻译结果，不要解释：\n\n\(text)", model: model)
    }

    static func availableModels() async -> [String] {
        uniqueModels(anthropicModels + openRouterModels)
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
}
