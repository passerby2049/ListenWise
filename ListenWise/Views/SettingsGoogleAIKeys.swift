/*
Abstract:
Google AI Studio settings section — manages a list of API keys with
add/rename/delete/select-active and a test-connection button that
pings Google's models endpoint with the currently active key.
*/

import SwiftUI

struct GoogleAIKeysSettingsSection: View {
    @Environment(AppPreferences.self) private var preferences

    @State private var keys: [GoogleAIKeyEntry] = []
    @State private var activeKeyID: UUID?
    @State private var testStatus: String = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            keysSection
            actionsSection
        }
        .formStyle(.grouped)
        .onAppear {
            keys = preferences.googleAIKeys
            activeKeyID = preferences.googleAIActiveKeyID ?? keys.first?.id
        }
        .onChange(of: keys) { _, newValue in
            preferences.googleAIKeys = newValue
        }
        .onChange(of: activeKeyID) { _, newValue in
            preferences.googleAIActiveKeyID = newValue
        }
    }

    // MARK: - Sections

    private var keysSection: some View {
        Section {
            if keys.isEmpty {
                Text("No API keys yet. Click **Add Key** below to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($keys) { $entry in
                keyRow(entry: $entry)
            }
        } header: {
            Text("API Keys")
        }
    }

    private func keyRow(entry: Binding<GoogleAIKeyEntry>) -> some View {
        let id = entry.wrappedValue.id
        let isActive = activeKeyID == id
        return HStack(spacing: 10) {
            Button {
                activeKeyID = id
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isActive ? preferences.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "Active key" : "Set as active")
            .help(isActive ? "Active key" : "Set as active")

            TextField("Name", text: entry.name)
                .textFieldStyle(.plain)
                .frame(width: 120)

            SecureField("API Key", text: entry.key)
                .textFieldStyle(.roundedBorder)

            Button(role: .destructive) {
                deleteKey(id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete key")
            .help("Delete this key")
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button("Add Key", systemImage: "plus") {
                    addKey()
                }
                Spacer()
                Button("Test Active Key") {
                    Task { await testActiveKey() }
                }
                .disabled(isTesting || activeKeyValue.isEmpty)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
            }
            if !testStatus.isEmpty {
                Text(testStatus)
                    .font(.caption)
                    .foregroundStyle(testStatus.contains("OK") ? .green : .red)
            }
            Text("The active key is used for all Gemini requests. Get a free key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var activeKeyValue: String {
        guard let id = activeKeyID else { return "" }
        return keys.first(where: { $0.id == id })?.key ?? ""
    }

    private func addKey() {
        let entry = GoogleAIKeyEntry(name: "Key \(keys.count + 1)", key: "")
        keys.append(entry)
        if activeKeyID == nil {
            activeKeyID = entry.id
        }
    }

    private func deleteKey(_ id: UUID) {
        keys.removeAll { $0.id == id }
        if activeKeyID == id {
            activeKeyID = keys.first?.id
        }
    }

    private func testActiveKey() async {
        let key = activeKeyValue
        guard !key.isEmpty else { return }
        isTesting = true
        testStatus = ""
        defer { isTesting = false }
        do {
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                testStatus = "No response"
                return
            }
            switch http.statusCode {
            case 200:
                testStatus = "OK — Key valid"
            case 401, 403:
                testStatus = "Invalid API Key"
            default:
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                if let message = AIProvider.errorMessage(from: bodyText) {
                    testStatus = "HTTP \(http.statusCode): \(message)"
                } else {
                    testStatus = "HTTP \(http.statusCode)"
                }
            }
        } catch {
            testStatus = "Failed: \(error.localizedDescription)"
        }
    }
}
