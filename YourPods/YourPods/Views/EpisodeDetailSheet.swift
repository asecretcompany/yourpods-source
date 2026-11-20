import SwiftUI

/// Detail sheet shown when tapping an episode. Displays artwork, description, and action buttons.
struct EpisodeDetailSheet: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settings
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.dismiss) private var dismiss
    
    let episode: Episode
    
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var showChapters = false
    @State private var showTranscript = false
    @State private var showShareOptions = false
    @State private var showAddNote = false
    @State private var chapters: [Chapter]
    @State private var transcript: Transcript?
    @State private var formattedDescription: AttributedString?
    
    init(episode: Episode) {
        self.episode = episode
        _chapters = State(initialValue: [])
    }
    
    private var isCurrentlyPlaying: Bool {
        episode.guid == playerManager.currentEpisodeGuid
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Episode Artwork
                    artworkSection
                    
                    // Title & metadata
                    metadataSection
                    
                    // Playback scrubber (if this is the playing episode)
                    if isCurrentlyPlaying {
                        playbackSection
                    } else if episode.listenedSeconds > 0 {
                        // Static progress for non-playing episode
                        staticProgressSection
                    }
                    
                    Divider()
                    
                    // Action buttons
                    actionButtonsSection
                    
                    // Chapters & Transcript buttons (appears when data is loaded by .task)
                    chaptersTranscriptSection
                    
                    Divider()
                    
                    // Episode description
                    descriptionSection
                }
                .padding()
            }
            .task {
                // Yield to ensure view update completes before mutating state
                try? await Task.sleep(for: .milliseconds(50))
                
                // Fetch chapters: URL → inline Podlove JSON → description.
                // This is a browsing surface for possibly-unplayed episodes,
                // so it stays feed-only by design (no embedded AVAsset
                // parsing) — fetchAllChapters already implements the full
                // feed-source chain in one call, including the inline
                // `chaptersJSON` source the old hand-rolled chain here used
                // to skip entirely (bug fix: Podlove-only feeds
                // showed no chapters).
                chapters = await ChapterService.shared.fetchAllChapters(
                    chaptersUrl: episode.chaptersUrl,
                    chaptersJSON: episode.chaptersJSON,
                    description: episode.episodeDescription)
                if let transcriptUrl = episode.transcriptUrl, !transcriptUrl.isEmpty {
                    transcript = await TranscriptService.shared.fetchTranscript(
                        url: transcriptUrl, type: episode.transcriptType
                    )
                }
                // Pre-compute the HTML attributed string for the description.
                // This MUST happen in .task (not in the view body) because
                // NSAttributedString(data:options:.html) internally uses WebKit,
                // which crashes with an assertion failure when invoked during
                // iOS snapshot callbacks (FBSSceneSnapshotAction).
                if let desc = episode.episodeDescription {
                    formattedDescription = desc.htmlAttributedString()
                }
            }
            .navigationTitle("Episode Details")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showChapters) {
                ChapterListSheet(
                    chapters: chapters,
                    currentPosition: isCurrentlyPlaying ? playerManager.currentPosition : TimeInterval(episode.listenedSeconds)
                ) { chapter in
                    if isCurrentlyPlaying {
                        playerManager.seek(to: chapter.startTime)
                    }
                }
            }
            .sheet(isPresented: $showTranscript) {
                if let transcript {
                    TranscriptListSheet(
                        transcript: transcript,
                        currentPosition: isCurrentlyPlaying ? playerManager.currentPosition : TimeInterval(episode.listenedSeconds)
                    ) { item in
                        if isCurrentlyPlaying {
                            playerManager.seek(to: item.start)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddNote) {
                AddEditNoteSheet(
                    episodeUrl: episode.audioUrl ?? "",
                    podcastUrl: episode.podcastUrl ?? "",
                    episodeGuid: episode.guid,
                    timestampSec: isCurrentlyPlaying ? playerManager.currentPosition : TimeInterval(episode.listenedSeconds),
                    podcastTitle: episode.podcastTitle,
                    episodeTitle: episode.title,
                    artUrl: episode.imageUrl ?? episode.podcast?.logoUrl,
                    durationSec: episode.durationSeconds.map { TimeInterval($0) },
                    transcriptUrl: episode.transcriptUrl
                )
                .environment(podcastManager)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
            }

            #if os(macOS)
            .frame(minWidth: 500, minHeight: 500)
            #endif
        }
    }
    
    // MARK: - Playback Section (live seek bar)
    
    private var playbackSection: some View {
        VStack(spacing: 8) {
            // Seek slider
            Slider(
                value: Binding(
                    get: {
                        if isDragging { return dragValue }
                        return PlayerManager.playbackProgress(
                            position: playerManager.currentPosition,
                            duration: playerManager.currentDuration
                        )
                    },
                    set: { newValue in
                        isDragging = true
                        dragValue = newValue
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        // Drag ended — seek to position
                        let seekTime = dragValue * playerManager.currentDuration
                        playerManager.seek(to: seekTime)
                        isDragging = false
                    }
                }
            )
            .tint(.accentColor)
            
            // Time labels
            HStack {
                let displayPosition = isDragging
                    ? dragValue * playerManager.currentDuration
                    : playerManager.currentPosition
                let remaining = playerManager.currentDuration - displayPosition
                
                Text(PlayerManager.formatTimestamp(displayPosition))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DurationFormatting.remainingTimestamp(max(0, remaining)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            // Playback controls
            HStack(spacing: 32) {
                Button {
                    playerManager.seekRelative(seconds: -Double(settings.skipBackwardSeconds))
                } label: {
                    Image(systemName: "gobackward.\(settings.skipBackwardSeconds)")
                        .font(.title2)
                }
                
                Button { playerManager.togglePlayPause() } label: {
                    Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                }
                
                Button {
                    playerManager.seekRelative(seconds: Double(settings.skipForwardSeconds))
                } label: {
                    Image(systemName: "goforward.\(settings.skipForwardSeconds)")
                        .font(.title2)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Static Progress (for non-playing but partially listened)
    
    private var staticProgressSection: some View {
        VStack(spacing: 4) {
            ProgressView(value: episode.listenProgress)
                .tint(.accentColor)
            
            HStack {
                Text(PlayerManager.formatTimestamp(TimeInterval(episode.listenedSeconds)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let total = episode.durationSeconds {
                    let remaining = max(0, total - episode.listenedSeconds)
                    Text(DurationFormatting.remainingTimestamp(TimeInterval(remaining)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Artwork
    
    private var artworkSection: some View {
        let imageUrl = episode.imageUrl ?? episode.podcast?.logoUrl
        return CachedAsyncImage(url: URL(string: imageUrl ?? "")) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .yourPodsGlassFill(cornerRadius: 16)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(maxWidth: 280, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 12)
    }
    
    // MARK: - Metadata
    
    private var metadataSection: some View {
        VStack(spacing: 8) {
            Text(episode.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            
            if let podcastTitle = episode.podcastTitle {
                let subscribedPodcast = EpisodeDetailSheetHelper.findSubscribedPodcast(
                    podcastUrl: episode.podcastUrl,
                    subscriptions: podcastManager.subscriptions
                )
                if let subscribedPodcast {
                    Button {
                        dismiss()
                        // Small delay to let the sheet dismiss before navigating
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            navigationState.navigateToLibrary(podcast: subscribedPodcast)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(podcastTitle)
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                        }
                    }
                    .accessibilityLabel("Go to \(podcastTitle)")
                    .accessibilityHint("Opens this podcast in your library")
                } else {
                    Text(podcastTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Season / Episode / Type badges
            HStack(spacing: 8) {
                if let seasonNum = episode.seasonNumber {
                    let epNum = episode.episodeNumber.map { Int($0) }
                    let label = episode.episodeDisplay
                        ?? (epNum != nil ? "S\(seasonNum)E\(epNum!)" : "Season \(seasonNum)")
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12))
                        .foregroundStyle(.indigo)
                        .clipShape(Capsule())
                } else if let epNum = episode.episodeNumber {
                    Text(episode.episodeDisplay ?? "Episode \(Int(epNum))")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12))
                        .foregroundStyle(.indigo)
                        .clipShape(Capsule())
                }
                
                if let seasonName = episode.seasonName {
                    Text(seasonName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let type = episode.episodeType, type != "full" {
                    Text(type.capitalized)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(type == "trailer" ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15))
                        .foregroundStyle(type == "trailer" ? .orange : .purple)
                        .clipShape(Capsule())
                }
                
                if episode.explicit == true {
                    Text("Explicit")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
            }
            
            HStack(spacing: 16) {
                if let pubDate = episode.pubDate {
                    Label(pubDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let duration = episode.durationSeconds {
                    Label(PlayerManager.formatDuration(TimeInterval(duration)), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Action Buttons
    
    private var actionButtonsSection: some View {
        let isCurrentlyPlaying = episode.guid == playerManager.currentEpisodeGuid
        let isDownloaded = downloadManager.isDownloaded(episode.guid)
        let isDownloading = downloadManager.activeDownloads[episode.guid] != nil

        return VStack(spacing: 12) {
            // Primary play button
            if episode.isPlayed {
                // PlayerManager treats explicit playback of a completed episode as relisten.
                Button {
                    playerManager.playEpisode(episode)
                    dismiss()
                } label: {
                    Label("Replay Episode", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Button {
                    playerManager.playEpisode(episode)
                    dismiss()
                } label: {
                    Label(
                        isCurrentlyPlaying ? "Now Playing" : "Play Episode",
                        systemImage: isCurrentlyPlaying ? "speaker.wave.2.fill" : "play.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isCurrentlyPlaying)
            }
            
            // Secondary actions row
            HStack(spacing: 12) {
                ActionButton(title: "Play Next", icon: "text.insert") {
                    playerManager.addToQueue(episode, playNext: true)
                    dismiss()
                }
                
                ActionButton(title: "Queue", icon: "text.append") {
                    playerManager.addToQueue(episode)
                    dismiss()
                }
                
                ActionButton(
                    title: isDownloaded ? "Downloaded" : "Download",
                    icon: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle",
                    isBusy: isDownloading
                ) {
                    if isDownloaded {
                        downloadManager.deleteDownload(guid: episode.guid)
                    } else if let audioUrl = episode.audioUrl {
                        Task {
                            let authHeaders: [String: String]? = episode.podcast?.requiresAuth == true
                                ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: episode.podcast!.url)
                                    .map { ["Authorization": $0] }
                                : nil
                            let privacyMode = episode.podcast?.effectiveSettings.privacyMode ?? settings.p3Enabled
                            downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl, authHeaders: authHeaders, privacyMode: privacyMode)
                        }
                    }
                }
                
                ActionButton(title: "Played", icon: "checkmark") {
                    if EpisodeDetailSheetHelper.shouldUsePlayerManager(
                        episodeGuid: episode.guid,
                        currentEpisodeGuid: playerManager.currentEpisodeGuid
                    ) {
                        // Currently-playing episode: mark played and advance to the
                        // next queued episode (stops when Up Next is empty)
                        playerManager.markCurrentEpisodeAsPlayed()
                    } else {
                        // Non-playing episode: data-layer update only
                        let resolvedUrl = EpisodeDetailSheetHelper.resolvePodcastUrl(
                            episodePodcastUrl: episode.podcastUrl,
                            currentItemPodcastUrl: playerManager.audioManager.currentItem?.podcastUrl,
                            episodeGuid: episode.guid,
                            subscriptions: podcastManager.subscriptions
                        )
                        if let resolvedUrl {
                            podcastManager.markEpisodeAsPlayed(podcastUrl: resolvedUrl, episodeGuid: episode.guid)
                        }
                    }
                    dismiss()
                }
                
                let isHidden = podcastManager.episodeActionSync.isHidden(guid: episode.guid)
                ActionButton(
                    title: isHidden ? "Unhide" : "Hide",
                    icon: isHidden ? "eye" : "eye.slash"
                ) {
                    podcastManager.toggleHidden(episode: episode)
                    dismiss()
                }
                
                Menu {
                    Button {
                        Task { @MainActor in
                            let items = await ShareLinkBuilder.shared.makeItems(for: ShareRequest(
                                kind: .episode, podcastUrl: episode.podcastUrl ?? "",
                                episodeUrl: episode.audioUrl, episodeGuid: episode.guid, startSec: nil,
                                episodeTitle: episode.title, podcastTitle: episode.podcastTitle ?? "",
                                episodeLink: episode.link))
                            SharePresenter.present(items: items)
                        }
                    } label: { Label("Share Episode", systemImage: "waveform") }

                    Button {
                        Task { @MainActor in
                            let items = await ShareLinkBuilder.shared.makeItems(for: ShareRequest(
                                kind: .podcast, podcastUrl: episode.podcastUrl ?? "",
                                episodeUrl: nil, episodeGuid: nil, startSec: nil,
                                episodeTitle: nil, podcastTitle: episode.podcastTitle ?? "",
                                episodeLink: episode.podcast?.website))
                            SharePresenter.present(items: items)
                        }
                    } label: { Label("Share Podcast", systemImage: "antenna.radiowaves.left.and.right") }

                    if isCurrentlyPlaying {
                        Button {
                            Task { @MainActor in
                                let items = await ShareLinkBuilder.shared.makeItems(for: ShareRequest(
                                    kind: .episode, podcastUrl: episode.podcastUrl ?? "",
                                    episodeUrl: episode.audioUrl, episodeGuid: episode.guid,
                                    startSec: Int(playerManager.currentPosition),
                                    episodeTitle: episode.title, podcastTitle: episode.podcastTitle ?? "",
                                    episodeLink: episode.link))
                                SharePresenter.present(items: items)
                            }
                        } label: { Label("Share Position", systemImage: "clock") }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                        Text("Share")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    
    // MARK: - Chapters & Transcript
    
    private var chaptersTranscriptSection: some View {
        HStack(spacing: 12) {
            if !chapters.isEmpty {
                ActionButton(title: "Chapters", icon: "book.pages") {
                    showChapters = true
                }
            }
            if let transcript, !transcript.items.isEmpty {
                ActionButton(title: "Transcript", icon: "text.quote") {
                    showTranscript = true
                }
            }
            ActionButton(title: "Add Note", icon: "note.text.badge.plus") {
                showAddNote = true
            }
        }
    }
    
    // MARK: - Description
    
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About This Episode")
                .font(.headline)
            
            if let description = episode.episodeDescription {
                if let formattedDescription {
                    // Rich HTML rendering (pre-computed in .task)
                    Text(formattedDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    // Lightweight fallback until .task completes
                    Text(description.strippingHTML())
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No description available.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable Action Button

private struct ActionButton: View {
    let title: String
    let icon: String
    /// When true, the icon is replaced by a spinner and the button is disabled
    /// (used by Download to show work is in progress).
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Fixed height so swapping the icon for a spinner doesn't
                // resize the button and shift the action grid.
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.title3)
                    }
                }
                .frame(height: 22)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.primary)
        .disabled(isBusy)
        .accessibilityValue(isBusy ? "Downloading" : "")
    }
}
