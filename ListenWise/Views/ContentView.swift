/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The app's main view.
*/

import SwiftUI

struct ContentView: View {
    @Environment(AppPreferences.self) private var preferences
    @State private var selection: Story?
    @State private var stories: [Story] = []
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List(stories, selection: $selection) { story in
                NavigationLink(value: story) {
                    StoryRowView(story: story)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        deleteStory(story)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ListenWise")
            .toolbar {
                ToolbarItem {
                    Button {
                        let newStory = Story.blank()
                        stories.append(newStory)
                        selection = newStory
                    } label: {
                        Label("New Story", systemImage: "plus")
                    }
                }
            }
            .onDeleteCommand {
                if let sel = selection { deleteStory(sel) }
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let sel = selection,
               let idx = stories.firstIndex(where: { $0.id == sel.id }),
               idx < stories.count {
                TranscriptView(story: Binding(
                    get: {
                        guard idx < stories.count else { return Story.blank() }
                        return stories[idx]
                    },
                    set: {
                        guard idx < stories.count else { return }
                        stories[idx] = $0
                    }
                ))
                .id(sel.id)
            } else {
                emptyStateView
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environment(preferences)
            }
            .frame(minWidth: 500, minHeight: 420)
        }
        .onAppear {
            if stories.isEmpty {
                stories = StoryStore.shared.loadAll()
            }
        }
        .onChange(of: stories) {
            StoryStore.shared.save(stories)
        }
    }

    // MARK: - Sidebar Footer

    @ViewBuilder
    var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showingSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(.bar)
    }

    // MARK: - Empty State

    @ViewBuilder
    var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "headphones.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Import to Start Learning")
                .font(.title2.bold())
            Text("Create a new Story, then import an audio\nor video file to transcribe and learn.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    func deleteStory(_ story: Story) {
        if selection?.id == story.id { selection = nil }
        stories.removeAll { $0.id == story.id }
    }
}

// MARK: - Story Row

private struct StoryRowView: View {
    let story: Story

    var langPairLabel: String {
        // Short labels: first 2 chars of source → first 2 chars of target
        let src = String(story.sourceLanguage.prefix(2)).uppercased()
        let tgt = story.targetLanguage == "中文" ? "ZH" : String(story.targetLanguage.prefix(2)).uppercased()
        return "\(src)→\(tgt)"
    }

    var metaText: String {
        if !story.isDone { return "Transcribing..." }
        let type = story.sourceIsVideo ? "Video" : "Audio"
        // Estimate duration from last subtitle card's end time
        if let lastEnd = story.savedSubtitleCards.last?.end, lastEnd > 0 {
            let total = Int(lastEnd)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            let duration = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            return "\(type) · \(duration) · \(langPairLabel)"
        }
        return "\(type) · \(langPairLabel)"
    }

    var icon: String {
        story.sourceIsVideo ? "film" : "waveform"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(story.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(metaText)
                    .font(.system(size: 12))
            }
            .foregroundStyle(story.isDone ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 2)
    }
}
