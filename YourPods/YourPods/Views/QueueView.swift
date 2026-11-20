import SwiftUI

/// "Up Next" queue view with now playing, reorderable queue, episode dates, and % listened.
struct QueueView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasSeenQueueMessage") private var hasSeenQueueMessage = false
    @State private var showDismissableMessage = true
    @State private var itemToRemove: QueueItem?
    @State private var showRemovalDialog = false
    @State private var rememberChoice = false
    @State private var showSettings = false
    @State private var episodeSheetItem: EpisodeSheetItem?
    @State private var showRemoveAllConfirmation = false
    
    /// Resolve the Episode model from a QueueItem GUID.
    /// Searches subscriptions first, then falls back to creating a transient
    /// Episode from the QueueItem's data for full detail sheet display.
    private func resolveEpisode(for item: QueueItem) -> Episode? {
        return EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: item.id,
            subscriptions: podcastManager.subscriptions,
            fallbackQueueItem: item
        )
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // First-time message
                if !hasSeenQueueMessage && showDismissableMessage {
                    QueueInfoBanner {
                        withAnimation {
                            hasSeenQueueMessage = true
                        }
                    }
                }
                
                // Connectivity banner (informational — queue is local)
                OfflineBanner()
                
                List {
                    // Now Playing section
                    if let current = playerManager.audioManager.currentItem {
                        Section("Now Playing") {
                            QueueItemRow(
                                item: current,
                                isNowPlaying: true,
                                progress: PlayerManager.playbackProgress(
                                    position: playerManager.currentPosition,
                                    duration: playerManager.currentDuration
                                )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let ep = resolveEpisode(for: current) {
                                    episodeSheetItem = EpisodeSheetItem(episode: ep)
                                }
                            }
                            .contextMenu {
                                Button {
                                    if let ep = resolveEpisode(for: current) {
                                        episodeSheetItem = EpisodeSheetItem(episode: ep)
                                    }
                                } label: {
                                    Label("Details", systemImage: "info.circle")
                                }
                                Divider()
                                Button {
                                    downloadAction(for: current)
                                } label: {
                                    Label(
                                        EpisodeDownloadHelper.downloadLabel(isDownloaded: downloadManager.isDownloaded(current.id)),
                                        systemImage: EpisodeDownloadHelper.downloadIcon(isDownloaded: downloadManager.isDownloaded(current.id))
                                    )
                                }
                                Button(role: .destructive) {
                                    handleRemoveCurrentItem(current)
                                } label: {
                                    Label("Remove from Queue", systemImage: "minus.circle")
                                }
                                Button {
                                    playerManager.markCurrentEpisodeAsPlayed()
                                } label: {
                                    Label("Mark as Played", systemImage: "checkmark.circle")
                                }
                                if let ep = resolveEpisode(for: current) {
                                    Button {
                                        podcastManager.toggleHidden(episode: ep)
                                    } label: {
                                        let isHidden = podcastManager.episodeActionSync.isHidden(guid: current.id)
                                        Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                                    }
                                }
                            }
                            // MARK: VoiceOver - Now Playing
                            .accessibilityAction(named: "Details") {
                                if let ep = resolveEpisode(for: current) {
                                    episodeSheetItem = EpisodeSheetItem(episode: ep)
                                }
                            }
                            .accessibilityAction(named: EpisodeDownloadHelper.accessibilityActionName(isDownloaded: downloadManager.isDownloaded(current.id))) {
                                downloadAction(for: current)
                            }
                            .accessibilityAction(named: "Remove from Queue") {
                                handleRemoveCurrentItem(current)
                            }
                            .accessibilityAction(named: "Mark as Played") {
                                playerManager.markCurrentEpisodeAsPlayed()
                            }
                            .accessibilityAction(named: podcastManager.episodeActionSync.isHidden(guid: current.id) ? "Unhide" : "Hide") {
                                if let ep = resolveEpisode(for: current) {
                                    podcastManager.toggleHidden(episode: ep)
                                }
                            }
                        }
                    }
                    
                    // Up Next section
                    let upcoming = playerManager.audioManager.queue
                    Section("Up Next (\(upcoming.count))") {
                        if upcoming.isEmpty {
                            ContentUnavailableView(
                                "Queue Empty",
                                systemImage: "text.append",
                                description: Text("Add episodes from your library or search.")
                            )
                        } else {
                            ForEach(upcoming) { item in
                                queueItemView(for: item)
                            }
                            .onDelete { indexSet in
                                // Convert IndexSet to items and handle removal
                                for idx in indexSet {
                                    let item = upcoming[idx]
                                    handleRemoveItem(item)
                                }
                            }
                            .onMove { from, to in
                                playerManager.audioManager.moveQueueItems(from: from, to: to)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    let strategy = settingsManager.syncConflictStrategy
                    let conflicts = await podcastManager.refreshAndSync(
                        playerManager: playerManager,
                        downloadManager: downloadManager,
                        settingsManager: settingsManager,
                        strategy: strategy
                    )
                    playerManager.deliverConflicts(conflicts, strategy: strategy)
                }
            }
            .navigationTitle("Up Next")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
                #endif
                ToolbarItem(placement: .secondaryAction) {
                    if !playerManager.audioManager.queue.isEmpty || playerManager.audioManager.currentItem != nil {
                        Button(role: .destructive) {
                            showRemoveAllConfirmation = true
                        } label: {
                            Label("Clear Queue", systemImage: "trash")
                        }
                        .accessibilityLabel("Clear Queue")
                        .accessibilityHint("Remove episodes from your Up Next queue")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Queue Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    QueueSettingsSheet()
                        .environment(settingsManager)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
            .sheet(item: $episodeSheetItem) { item in
                EpisodeDetailSheet(episode: item.episode)
                    .environment(playerManager)
                    .environment(podcastManager)
                    .environment(downloadManager)
                    .environment(settingsManager)
                    .environment(navigationState)
                    .modelContext(modelContext)
            }
            .confirmationDialog(
                "Remove from Queue",
                isPresented: $showRemovalDialog,
                titleVisibility: .visible
            ) {
                Button("Remove") {
                    if let item = itemToRemove {
                        if playerManager.audioManager.currentItem?.id == item.id {
                            playerManager.removeCurrentEpisodeFromQueue()
                        } else {
                            playerManager.removeFromQueue(item)
                        }
                        if rememberChoice {
                            settingsManager.queueRemovalAction = .removeOnly
                            settingsManager.hasChosenQueueRemovalAction = true
                        }
                    }
                    itemToRemove = nil
                    rememberChoice = false
                }
                Button("Remove & Mark as Played") {
                    if let item = itemToRemove {
                        if playerManager.audioManager.currentItem?.id == item.id {
                            playerManager.markCurrentEpisodeAsPlayed()
                        } else {
                            playerManager.audioManager.removeFromQueue(item)
                            podcastManager.markEpisodeAsPlayed(
                                podcastUrl: item.podcastUrl,
                                episodeGuid: item.id
                            )
                        }
                        if rememberChoice {
                            settingsManager.queueRemovalAction = .removeAndMarkPlayed
                            settingsManager.hasChosenQueueRemovalAction = true
                        }
                    }
                    itemToRemove = nil
                    rememberChoice = false
                }
                Button("Cancel", role: .cancel) {
                    itemToRemove = nil
                    rememberChoice = false
                }
            } message: {
                if !settingsManager.hasChosenQueueRemovalAction {
                    Text("What would you like to do? Your choice will be remembered. You can change this later in Settings → Queue Management.")
                } else {
                    Text("What would you like to do with this episode?")
                }
            }
            .confirmationDialog(
                "Clear Queue",
                isPresented: $showRemoveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Up Next", role: .destructive) {
                    playerManager.audioManager.clearQueue()
                }
                if playerManager.audioManager.currentItem != nil {
                    Button("Clear Everything", role: .destructive) {
                        playerManager.clearAllQueue()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if playerManager.audioManager.currentItem != nil {
                    Text("\"Clear Up Next\" removes upcoming episodes. \"Clear Everything\" also stops playback and removes the current episode.")
                } else {
                    Text("This will remove all episodes from your Up Next queue.")
                }
            }
        }
    }
    
    // MARK: - Queue Item View (extracted to reduce type-checker complexity)
    
    @ViewBuilder
    private func queueItemView(for item: QueueItem) -> some View {
        QueueItemRow(item: item)
            .contentShape(Rectangle())
            .onTapGesture {
                playerManager.playQueueItem(item)
            }
            .contextMenu {
                Button {
                    playerManager.playQueueItem(item)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    playerManager.audioManager.moveToTop(item)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Divider()
                Button {
                    downloadAction(for: item)
                } label: {
                    Label(
                        EpisodeDownloadHelper.downloadLabel(isDownloaded: downloadManager.isDownloaded(item.id)),
                        systemImage: EpisodeDownloadHelper.downloadIcon(isDownloaded: downloadManager.isDownloaded(item.id))
                    )
                }
                Button(role: .destructive) {
                    handleRemoveItem(item)
                } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
                Button {
                    playerManager.markQueuedEpisodeAsPlayed(item)
                } label: {
                    Label("Mark as Played", systemImage: "checkmark.circle")
                }
                if let ep = resolveEpisode(for: item) {
                    Button {
                        podcastManager.toggleHidden(episode: ep)
                    } label: {
                        let isHidden = podcastManager.episodeActionSync.isHidden(guid: item.id)
                        Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                    }
                }
                Divider()
                Button {
                    if let ep = resolveEpisode(for: item) {
                        episodeSheetItem = EpisodeSheetItem(episode: ep)
                    }
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
            }
            // MARK: VoiceOver - Queue Items
            .accessibilityAction(named: "Play") {
                playerManager.playQueueItem(item)
            }
            .accessibilityAction(named: "Play Next") {
                playerManager.audioManager.moveToTop(item)
            }
            .accessibilityAction(named: EpisodeDownloadHelper.accessibilityActionName(isDownloaded: downloadManager.isDownloaded(item.id))) {
                downloadAction(for: item)
            }
            .accessibilityAction(named: "Remove from Queue") {
                handleRemoveItem(item)
            }
            .accessibilityAction(named: "Mark as Played") {
                playerManager.markQueuedEpisodeAsPlayed(item)
            }
            .accessibilityAction(named: podcastManager.episodeActionSync.isHidden(guid: item.id) ? "Unhide" : "Hide") {
                if let ep = resolveEpisode(for: item) {
                    podcastManager.toggleHidden(episode: ep)
                }
            }
            .accessibilityAction(named: "Details") {
                if let ep = resolveEpisode(for: item) {
                    episodeSheetItem = EpisodeSheetItem(episode: ep)
                }
            }
    }
    
    /// Handle removing an item based on the user's queue removal preference.
    private func handleRemoveItem(_ item: QueueItem) {
        switch settingsManager.queueRemovalAction {
        case .removeOnly:
            playerManager.removeFromQueue(item)
        case .removeAndMarkPlayed:
            playerManager.audioManager.removeFromQueue(item)
            podcastManager.markEpisodeAsPlayed(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
        case .ask:
            itemToRemove = item
            showRemovalDialog = true
        }
    }
    
    /// Handle removing the currently-playing item based on the user's queue removal preference.
    /// DECISION (2026-07-09): the two preferences intentionally diverge on playback —
    /// .removeAndMarkPlayed advances to the next Up Next episode (stops when Up Next is empty) ("episode consumed,
    /// keep going"), .removeOnly stops playback ("silence this", see
    /// removeCurrentEpisodeFromQueue). Keep this asymmetry deliberate.
    private func handleRemoveCurrentItem(_ item: QueueItem) {
        switch settingsManager.queueRemovalAction {
        case .removeOnly:
            playerManager.removeCurrentEpisodeFromQueue()
        case .removeAndMarkPlayed:
            playerManager.markCurrentEpisodeAsPlayed()
        case .ask:
            itemToRemove = item
            showRemovalDialog = true
        }
    }
    
    /// Handle download/remove download action for a queue item.
    private func downloadAction(for item: QueueItem) {
        if downloadManager.isDownloaded(item.id) {
            downloadManager.deleteDownload(guid: item.id)
        } else {
            downloadManager.downloadEpisode(
                guid: item.id,
                audioUrl: item.audioUrl,
                authHeaders: item.authHeaders,
                privacyMode: item.privacyMode
            )
        }
    }
}

// MARK: - Queue Settings Sheet

private struct QueueSettingsSheet: View {
    @Environment(SettingsManager.self) private var settings
    
    var body: some View {
        Form {
            Section {
                Picker("On Queue Removal", selection: Binding(
                    get: { settings.queueRemovalAction },
                    set: { settings.queueRemovalAction = $0 }
                )) {
                    Text("Just Remove").tag(QueueRemovalAction.removeOnly)
                    Text("Remove & Mark Played").tag(QueueRemovalAction.removeAndMarkPlayed)
                    Text("Always Ask").tag(QueueRemovalAction.ask)
                }
            } header: {
                Label("Queue Management", systemImage: "list.bullet")
            } footer: {
                Text("Choose what happens when you remove an episode from the Up Next queue.")
            }
        }
        .navigationTitle("Queue Settings")
    }
}

// MARK: - Queue Info Banner

struct QueueInfoBanner: View {
    /// One-time banner shown to every account type, so the copy has to be
    /// accurate for all of them: gPodder/Nextcloud never sync the queue, Pro
    /// syncs it across devices and the web, and Vault Mode keeps it on-device.
    /// Exposed (not `private`) so the copy is covered by `QueueInfoBannerCopyTests`.
    static let title: LocalizedStringResource = "How Up Next Syncs"
    static let message: LocalizedStringResource = "gPodder and Nextcloud don't sync your Up Next queue between devices — only YourPods Pro syncs it across your devices and the web. Vault Mode keeps Up Next on this device. Your listening progress still syncs with any sync account."

    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title)
                    .font(.subheadline.bold())
                Text(Self.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Queue Item Row

struct QueueItemRow: View {
    let item: QueueItem
    var isNowPlaying: Bool = false
    var progress: Double = 0
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            CachedAsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.bold())
                    .foregroundColor(isNowPlaying ? .accentColor : .primary)
                    .lineLimit(2)
                
                Text(item.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    // Publication date
                    if let pubDate = item.pubDate {
                        Text(pubDate, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    
                    // Duration / Remaining
                    if let duration = item.durationSeconds, duration > 0 {
                        if isNowPlaying {
                            let listened = Int(progress * 100)
                            Text(DurationFormatting.percentListened(listened))
                                .font(.caption2.bold())
                                .foregroundColor(.accentColor)
                        } else if item.positionSeconds > 0 {
                            let remaining = duration - item.positionSeconds
                            Text(DurationFormatting.remaining(TimeInterval(remaining)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(PlayerManager.formatDuration(TimeInterval(duration)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            
            Spacer()
            
            if isNowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        // MARK: VoiceOver Accessibility
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EpisodeAccessibility.queueItemLabel(
            title: item.title,
            podcastTitle: item.podcastTitle,
            durationSeconds: item.durationSeconds,
            positionSeconds: item.positionSeconds,
            isNowPlaying: isNowPlaying,
            progress: progress
        ))
        .accessibilityHint(isNowPlaying ? "Double tap to show details" : "Double tap to play")
        .accessibilityAddTraits(isNowPlaying ? .isSelected : [])
    }
}
