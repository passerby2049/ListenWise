/*
Abstract:
App settings view — two-column layout similar to macOS System Settings.
Left sidebar for navigation, right pane for section content.
*/

import SwiftUI
import FluidAudio

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case transcription = "Transcription"
    case appearance = "Appearance"
    case model = "Model"
    case openRouter = "OpenRouter"
    case anthropic = "Anthropic"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcription: return "waveform"
        case .appearance: return "paintbrush"
        case .model: return "cpu"
        case .openRouter: return "cloud"
        case .anthropic: return "server.rack"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    @State private var selectedSection: SettingsSection = .transcription

    @State private var openRouterKey = ""
    @State private var anthropicBaseURL = "https://api.anthropic.com"
    @State private var anthropicAPIKey = ""
    @State private var defaultModel = "google/gemini-2.5-flash"

    @State private var selectedAccentColor = "blue"
    private var currentAccentColor: Color {
        AppPreferences.color(for: selectedAccentColor)
    }
    @State private var selectedEngine: TranscriptionEngineID = .appleSpeech
    @State private var isDownloadingModel: TranscriptionEngineID?
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String = ""
    @State private var modelDownloadStatus: [TranscriptionEngineID: Bool] = [:]

    @State private var testStatusOR: String = ""
    @State private var isTestingOR = false
    @State private var testStatusAnthropic: String = ""
    @State private var isTestingAnthropic = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedSection == section ? currentAccentColor.opacity(0.2) : Color.clear)
                            )
                            .foregroundStyle(selectedSection == section ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)

            Divider()

            // Detail
            ScrollView {
                detailContent
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
            }
        }
        .frame(width: 640, height: 480)
        .onAppear {
            openRouterKey = preferences.openRouterAPIKey
            anthropicBaseURL = preferences.anthropicBaseURL
            anthropicAPIKey = preferences.anthropicAPIKey
            defaultModel = preferences.defaultModel
            selectedEngine = preferences.selectedTranscriptionEngine
            selectedAccentColor = preferences.accentColorName
            Task { await loadModels() }
        }
        .onChange(of: openRouterKey) { _, v in preferences.openRouterAPIKey = v }
        .onChange(of: anthropicBaseURL) { _, v in preferences.anthropicBaseURL = v }
        .onChange(of: anthropicAPIKey) { _, v in preferences.anthropicAPIKey = v }
        .onChange(of: defaultModel) { _, v in preferences.defaultModel = v }
        .onChange(of: selectedEngine) { _, v in preferences.selectedTranscriptionEngine = v }
        .onChange(of: selectedAccentColor) { _, v in preferences.accentColorName = v }
    }

    // MARK: - Detail Content Router

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .transcription: transcriptionSection
        case .appearance: appearanceSection
        case .model: modelSection
        case .openRouter: openRouterSection
        case .anthropic: anthropicSection
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(TranscriptionEngineID.allCases) { engine in
                engineCard(engine)
            }
        }
        .padding()
        .onAppear { refreshModelStatus() }
    }

    private func engineCard(_ engine: TranscriptionEngineID) -> some View {
        let isActive = selectedEngine == engine
        let isDownloaded = modelDownloadStatus[engine] ?? !engine.requiresDownload
        let isCurrentlyDownloading = isDownloadingModel == engine

        return HStack(spacing: 12) {
            // Icon
            Image(systemName: engine.iconName)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(isActive ? currentAccentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(engine.speedLabel)
                    Text(engine.accuracyLabel)
                    if engine.requiresDownload {
                        Text(engine.downloadSize)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Action
            if isCurrentlyDownloading {
                ProgressView(value: downloadProgress)
                    .frame(width: 80)
            } else if isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            } else if !engine.requiresDownload || isDownloaded {
                Button("Activate") {
                    selectedEngine = engine
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Download") {
                    Task { await downloadModel(engine) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                #if !arch(arm64)
                if engine.requiresAppleSilicon {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                #endif
            }

            // Delete button for downloaded models
            if engine.requiresDownload && isDownloaded && !isCurrentlyDownloading {
                Button {
                    deleteModel(engine)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Delete downloaded model")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? currentAccentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? currentAccentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Form {
            Section {
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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent Color")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pick a preset accent color for the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(accentColorOptions, id: \.name) { option in
                            Button {
                                selectedAccentColor = option.name
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary.opacity(selectedAccentColor == option.name ? 0.6 : 0), lineWidth: 2)
                                            .padding(-2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var accentColorOptions: [(name: String, color: Color)] {
        [
            ("blue", .blue),
            ("purple", .purple),
            ("pink", .pink),
            ("red", .red),
            ("orange", .orange),
            ("yellow", .yellow),
            ("green", .green),
            ("gray", .gray),
        ]
    }

    // MARK: - Model

    private var modelSection: some View {
        Form {
            Section {
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
        }
        .formStyle(.grouped)
    }

    // MARK: - OpenRouter

    private var openRouterSection: some View {
        Form {
            Section {
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
        }
        .formStyle(.grouped)
    }

    // MARK: - Anthropic

    private var anthropicSection: some View {
        Form {
            Section {
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
    }

    // MARK: - Actions

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

    func downloadModel(_ engineID: TranscriptionEngineID) async {
        isDownloadingModel = engineID
        downloadProgress = 0
        downloadError = ""

        let engine = engineID.makeEngine()
        do {
            try await engine.prepare(locale: Locale(identifier: "en-US")) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
            selectedEngine = engineID
        } catch {
            downloadError = error.localizedDescription
        }

        isDownloadingModel = nil
        refreshModelStatus()
    }

    func deleteModel(_ engineID: TranscriptionEngineID) {
        guard engineID.requiresDownload else { return }

        let version: AsrModelVersion = engineID == .parakeetV3 ? .v3 : .v2
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        // defaultCacheDirectory points to .../Models/<repoFolder> — remove that folder
        try? FileManager.default.removeItem(at: cacheDir)

        if selectedEngine == engineID {
            selectedEngine = .appleSpeech
        }
        refreshModelStatus()
    }

    func refreshModelStatus() {
        for engine in TranscriptionEngineID.allCases {
            if engine.requiresDownload {
                let version: AsrModelVersion = engine == .parakeetV3 ? .v3 : .v2
                let cacheDir = AsrModels.defaultCacheDirectory(for: version)
                modelDownloadStatus[engine] = AsrModels.modelsExist(at: cacheDir, version: version)
            } else {
                modelDownloadStatus[engine] = true
            }
        }
    }
}
