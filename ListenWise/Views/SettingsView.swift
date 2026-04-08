/*
Abstract:
App settings view — API keys, server configuration, model selection.
*/

import SwiftUI

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var openRouterKey = ""
    @State private var anthropicBaseURL = "https://api.anthropic.com"
    @State private var anthropicAPIKey = ""
    @State private var defaultModel = "google/gemini-2.5-flash"

    @State private var testStatusOR: String = ""
    @State private var isTestingOR = false
    @State private var testStatusAnthropic: String = ""
    @State private var isTestingAnthropic = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { preferences.appearance },
                    set: { preferences.appearance = $0 }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Model") {
                Picker("Default Model", selection: $defaultModel) {
                    if !availableModels.contains(defaultModel) {
                        Text(defaultModel).tag(defaultModel)
                    }
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                HStack {
                    Button("Refresh Models") {
                        Task { await loadModels() }
                    }
                    .disabled(isLoadingModels)
                    if isLoadingModels {
                        ProgressView().controlSize(.small)
                    }
                }

                Text("OpenRouter models and Anthropic/relay models are listed together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenRouter (Cloud)") {
                SecureField("API Key", text: $openRouterKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Test Connection") {
                        Task { await testOpenRouter() }
                    }
                    .disabled(isTestingOR || openRouterKey.isEmpty)
                    if isTestingOR {
                        ProgressView().controlSize(.small)
                    }
                    if !testStatusOR.isEmpty {
                        Text(testStatusOR)
                            .font(.caption)
                            .foregroundStyle(testStatusOR.contains("OK") ? .green : .red)
                    }
                }
                Text("Get a free key at [openrouter.ai/keys](https://openrouter.ai/keys)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Anthropic / Relay (Messages API)") {
                TextField("Base URL", text: $anthropicBaseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Test Connection") {
                        Task { await testAnthropic() }
                    }
                    .disabled(isTestingAnthropic || anthropicAPIKey.isEmpty || anthropicBaseURL.isEmpty)
                    if isTestingAnthropic {
                        ProgressView().controlSize(.small)
                    }
                    if !testStatusAnthropic.isEmpty {
                        Text(testStatusAnthropic)
                            .font(.caption)
                            .foregroundStyle(testStatusAnthropic.contains("OK") ? .green : .red)
                    }
                }
                Text("Use a Messages API-compatible endpoint, including relay/proxy base URLs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            openRouterKey = preferences.openRouterAPIKey
            anthropicBaseURL = preferences.anthropicBaseURL
            anthropicAPIKey = preferences.anthropicAPIKey
            defaultModel = preferences.defaultModel
            Task { await loadModels() }
        }
        .onChange(of: openRouterKey) { _, newValue in
            preferences.openRouterAPIKey = newValue
        }
        .onChange(of: anthropicBaseURL) { _, newValue in
            preferences.anthropicBaseURL = newValue
        }
        .onChange(of: anthropicAPIKey) { _, newValue in
            preferences.anthropicAPIKey = newValue
        }
        .onChange(of: defaultModel) { _, newValue in
            preferences.defaultModel = newValue
        }
    }

    func loadModels() async {
        isLoadingModels = true
        availableModels = await AIProvider.availableModels()
        isLoadingModels = false
    }

    func testOpenRouter() async {
        isTestingOR = true
        testStatusOR = ""
        do {
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            request.setValue("Bearer \(openRouterKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    testStatusOR = "OK — Key valid"
                } else if http.statusCode == 401 {
                    testStatusOR = "Invalid API Key"
                } else {
                    testStatusOR = "HTTP \(http.statusCode)"
                }
            }
        } catch {
            testStatusOR = "Failed: \(error.localizedDescription)"
        }
        isTestingOR = false
    }

    func testAnthropic() async {
        isTestingAnthropic = true
        testStatusAnthropic = ""
        do {
            guard let baseURL = URL(string: anthropicBaseURL) else {
                testStatusAnthropic = "Invalid URL"
                isTestingAnthropic = false
                return
            }

            var request = URLRequest(url: AIProvider.anthropicMessagesURL(from: baseURL))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anthropicAPIKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 10
            let body: [String: Any] = [
                "model": AIProvider.anthropicModels.first ?? "claude-opus-4-6",
                "max_tokens": 1,
                "stream": false,
                "messages": [["role": "user", "content": "Hi"]]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                testStatusAnthropic = "No response"
                isTestingAnthropic = false
                return
            }

            if http.statusCode == 200 {
                testStatusAnthropic = "OK — Endpoint reachable"
            } else if http.statusCode == 401 || http.statusCode == 403 {
                testStatusAnthropic = "Invalid API Key"
            } else if http.statusCode == 404 {
                testStatusAnthropic = "Wrong base URL or incompatible endpoint"
            } else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                if let message = AIProvider.errorMessage(from: bodyText) {
                    testStatusAnthropic = "HTTP \(http.statusCode): \(message)"
                } else {
                    testStatusAnthropic = "HTTP \(http.statusCode)"
                }
            }
        } catch {
            testStatusAnthropic = "Failed: \(error.localizedDescription)"
        }
        isTestingAnthropic = false
    }
}
