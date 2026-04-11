/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The app's main view.
*/

import SwiftUI

enum StoryFilter: Hashable {
    case all
    case favorites
    // Reserved for a future tag picker — keeps the enum open for extension
    // without forcing call sites to switch on a Bool.
    case tag(String)
}

struct ContentView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(DeepLinkRouter.self) private var deepLink
    @State private var selectionID: UUID?
    @State private var stories: [Story] = []
    @State private var filter: StoryFilter = .all
    @State private var isShowingReview = false
    @State private var dueCount: Int = 0

    private var filteredStories: [Story] {
        switch filter {
        case .all:
            return stories
        case .favorites:
            return stories.filter { $0.isFavorite }
        case .tag(let name):
            return stories.filter { $0.tags.contains(name) }
        }
    }


    var body: some View {
        NavigationSplitView {
            List(selection: $selectionID) {
                ForEach(filteredStories) { story in
                    StoryRowView(story: story)
                        .tag(story.id)
                        .contextMenu {
                            Button {
                                toggleFavorite(story)
                            } label: {
                                Label(story.isFavorite ? "Unfavorite" : "Favorite",
                                      systemImage: story.isFavorite ? "star.slash" : "star")
                            }
                            Divider()
                            Button(role: .destructive) {
                                deleteStory(story)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                filterBar
            }
            .navigationTitle("ListenWise")
            .toolbar {
                ToolbarItem {
                    Button {
                        if filter != .all { filter = .all }
                        let newStory = Story.blank()
                        stories.insert(newStory, at: 0)
                        selectionID = newStory.id
                    } label: {
                        Label("New Story", systemImage: "plus")
                    }
                }
            }
            .onDeleteCommand {
                if let id = selectionID,
                   let story = stories.first(where: { $0.id == id }) {
                    deleteStory(story)
                }
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let id = selectionID,
               let idx = stories.firstIndex(where: { $0.id == id }) {
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
                .id(id)
            } else {
                emptyStateView
            }
        }
        .sheet(isPresented: $isShowingReview, onDismiss: refreshDueCount) {
            ReviewSessionView()
                .environment(preferences)
        }
        .onAppear {
            loadStoriesIfNeeded()
            refreshDueCount()
            if deepLink.pendingYouTubeURL != nil {
                openStoryForDeepLink()
            }
        }
        .onChange(of: deepLink.pendingYouTubeURL) { _, newValue in
            guard newValue != nil else { return }
            openStoryForDeepLink()
        }
        .onChange(of: selectionID) { oldID, _ in
            discardBlankStory(withID: oldID)
        }
        .onChange(of: stories) {
            // Never persist blank stories — they're ephemeral drafts.
            let snapshot = stories.filter { !$0.isBlank }
            Task.detached(priority: .utility) {
                StoryStore.shared.save(snapshot)
            }
        }
    }

    // MARK: - Sidebar Footer

    @ViewBuilder
    var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                refreshDueCount()
                isShowingReview = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(dueCount > 0 ? preferences.accentColor : .secondary)
                    Text("Review")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    if dueCount > 0 {
                        Text("\(dueCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(preferences.accentColor))
                    } else {
                        Text("0")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            SettingsLink {
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

    private func refreshDueCount() {
        dueCount = GlobalVocabulary.shared.dueCount()
    }

    @State private var didLoadStories = false

    private func loadStoriesIfNeeded() {
        guard !didLoadStories else { return }
        didLoadStories = true
        // Strip any blank stories that predate the auto-cleanup rule.
        stories = StoryStore.shared.loadAll().filter { !$0.isBlank }
    }

    /// Spawn a new blank Story and select it so TranscriptView can consume
    /// the pending YouTube URL via DeepLinkRouter. Safe to call before
    /// `.onAppear` — loads persisted stories first so a cold-start deep
    /// link cannot skip the load path via the `stories.isEmpty` guard.
    private func openStoryForDeepLink() {
        loadStoriesIfNeeded()
        let newStory = Story.blank()
        stories.insert(newStory, at: 0)
        selectionID = newStory.id
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

    private var filterIconName: String {
        switch filter {
        case .all: return "folder"
        case .favorites: return "star.fill"
        case .tag: return "tag.fill"
        }
    }

    private var filterLabel: String {
        switch filter {
        case .all: return "All Stories"
        case .favorites: return "Favorites"
        case .tag(let name): return name
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        VStack(spacing: 0) {
            Menu {
                Button {
                    filter = .all
                } label: {
                    Label("All Stories", systemImage: filter == .all ? "checkmark" : "folder")
                }
                Button {
                    filter = .favorites
                } label: {
                    Label("Favorites", systemImage: filter == .favorites ? "checkmark" : "star.fill")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: filterIconName)
                    Text(filterLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(.bar)
    }

    /// Toggle the favorite flag and persist immediately. `Story` is a class,
    /// so mutating a field doesn't trip `.onChange(of: stories)` — we call
    /// the single-story save directly.
    private func toggleFavorite(_ story: Story) {
        story.isFavorite.toggle()
        StoryStore.shared.save(story)
    }

    func deleteStory(_ story: Story) {
        if selectionID == story.id { selectionID = nil }
        // Delete downloaded YouTube video file
        if !story.youtubeURL.isEmpty, let url = story.url {
            try? FileManager.default.removeItem(at: url)
        }
        stories.removeAll { $0.id == story.id }
    }

    /// Remove a blank story that the user abandoned by navigating away.
    /// No-ops if the id is missing, the story no longer exists, or it has content.
    private func discardBlankStory(withID id: UUID?) {
        guard let id,
              let story = stories.first(where: { $0.id == id }),
              story.isBlank else { return }
        stories.removeAll { $0.id == id }
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
        let type = story.isLiveStream ? "Live" : (!story.youtubeURL.isEmpty ? "YouTube" : (story.sourceIsVideo ? "Video" : "Audio"))
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
        if story.isLiveStream { return "antenna.radiowaves.left.and.right" }
        if !story.youtubeURL.isEmpty { return "play.rectangle.fill" }
        return story.sourceIsVideo ? "film" : "waveform"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(story.title)
                    .font(.body)
                    .lineLimit(1)
                if story.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
            }
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(metaText)
            }
            .font(.caption)
            .foregroundStyle(story.isDone ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 2)
    }
}
