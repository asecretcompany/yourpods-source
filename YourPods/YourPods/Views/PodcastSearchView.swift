import SwiftUI

/// Add Podcasts screen with search, add-by-link, protected feed support, and stream previews.
struct PodcastSearchView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(SettingsManager.self) private var settings
    
    @State private var searchText = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedResult: PodcastSearchResult?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Connectivity banner
                    OfflineBanner()
                    
                    // Prominent Search Box
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Search", systemImage: "magnifyingglass")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        SearchBar(text: $searchText, isSearching: $isSearching)
                            .onChange(of: searchText) { _, newValue in
                                debounceSearch(newValue)
                            }
                    }
                    
                    // Search Results
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView("Searching...")
                            Spacer()
                        }
                        .padding(.top, 30)
                    } else if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .padding()
                    } else if !results.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(results) { result in
                                SearchResultRow(result: result) {
                                    selectedResult = result
                                }
                                Divider()
                                    .padding(.leading, 76)
                            }
                        }
                        .yourPodsGlass(role: .card, cornerRadius: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    } else if searchText.count >= 2 {
                        ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                               description: Text("Try a different search term."))
                        .padding(.top, 30)
                    }
                    
                    // Add by Link
                    AddByLinkCard()
                    
                    // Protected Feed
                    ProtectedFeedCard()
                }
                .padding(.vertical)
            }
            .navigationTitle("Add Podcasts")
            .sheet(item: $selectedResult) { result in
                PodcastPreviewSheet(result: result)
                    .environment(podcastManager)
                    .environment(playerManager)
            }
        }
    }
    
    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard query.count >= 2 else { results = []; return }
        
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performSearch(query)
        }
    }
    
    @MainActor
    private func performSearch(_ query: String) async {
        isSearching = true
        errorMessage = nil
        
        let result = SearchProviderResolver.resolve(
            provider: settings.searchProvider,
            apiKey: settings.podcastIndexApiKey,
            apiSecret: settings.podcastIndexApiSecret
        )
        
        let provider: PodcastSearchProvider
        switch result {
        case .provider(let p):
            provider = p
        case .missingCredentials(let message):
            errorMessage = message
            isSearching = false
            return
        }
        
        do {
            results = try await provider.search(query)
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
        isSearching = false
    }
}

// MARK: - Prominent Search Bar

private struct SearchBar: View {
    @Binding var text: String
    @Binding var isSearching: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.blue)
                .font(.title3)
            
            TextField("Enter a podcast name", text: $text)
                .font(.body)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .yourPodsGlass(role: .card, cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
        )
        .padding(.horizontal)
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: PodcastSearchResult
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: URL(string: result.artworkUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        .overlay { Image(systemName: "waveform").foregroundStyle(.secondary) }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    if let author = result.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let genre = result.genre {
                        Text(genre)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let description = result.description, !description.isEmpty {
                        Text(description.strippingHTML())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let website = result.websiteUrl, let url = URL(string: website), let host = url.host() {
                        Label(host, systemImage: "globe")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add by Link Card

private struct AddByLinkCard: View {
    @Environment(PodcastManager.self) private var podcastManager
    @State private var feedUrl = ""
    @State private var isAdding = false
    @State private var error: String?
    @State private var success = false
    
    private var isInsecure: Bool {
        URLSanitizer.isInsecure(feedUrl)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add by Link", systemImage: "link")
                .font(.headline)
            
            HStack {
                TextField("RSS feed URL", text: $feedUrl)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                
                Button {
                    addByLink()
                } label: {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
                .disabled(feedUrl.isEmpty || isAdding)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .yourPodsGlass(role: .card, cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            if isInsecure {
                Label {
                    Text("This feed uses HTTP. Data will be sent unencrypted. Use HTTPS if available.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }
            
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            if success {
                Label("Podcast added!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            }
        }
        .padding(.horizontal)
    }
    
    private func addByLink() {
        isAdding = true
        error = nil
        success = false
        Task {
            do {
                try await podcastManager.addSubscription(url: feedUrl)
                feedUrl = ""
                success = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    success = false
                }
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }
}

// MARK: - Protected Feed Card

private struct ProtectedFeedCard: View {
    @Environment(PodcastManager.self) private var podcastManager
    @State private var feedUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var requiresAuth = true
    @State private var isAdding = false
    @State private var error: String?
    @State private var success = false
    
    private var isInsecure: Bool {
        URLSanitizer.isInsecure(feedUrl)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Protected Feed", systemImage: "lock.shield")
                .font(.headline)
            
            TextField("Protected feed URL", text: $feedUrl)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .yourPodsGlass(role: .card, cornerRadius: 10)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            if isInsecure {
                Label {
                    Text("Credentials will be sent unencrypted over HTTP. Use HTTPS for security.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }
            
            Toggle("Authentication Required", isOn: $requiresAuth)
                .font(.subheadline)
            
            if requiresAuth {
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .yourPodsGlass(role: .card, cornerRadius: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                
                RevealableSecureField(label: "Password", text: $password)
                    .textContentType(.password)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .yourPodsGlass(role: .card, cornerRadius: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            Button {
                addProtectedFeed()
            } label: {
                if isAdding {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Add Protected Feed")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(feedUrl.isEmpty || (requiresAuth && (username.isEmpty || password.isEmpty)) || isAdding)
            
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            if success {
                VStack(spacing: 4) {
                    Label("Podcast added!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                    if requiresAuth {
                        Label("Credentials stored securely on this device only — not synced to any server.", systemImage: "lock.shield.fill")
                            .foregroundStyle(.secondary).font(.caption2)
                    }
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func addProtectedFeed() {
        isAdding = true
        error = nil
        success = false
        Task {
            do {
                // Pass auth credentials to the subscription method
                try await podcastManager.addSubscription(
                    url: feedUrl,
                    username: requiresAuth ? username : nil,
                    password: requiresAuth ? password : nil
                )
                feedUrl = ""
                username = ""
                password = ""
                success = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    success = false
                }
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }
}

// MARK: - Podcast Preview Sheet

private struct PodcastPreviewSheet: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(\.dismiss) private var dismiss
    let result: PodcastSearchResult
    
    @State private var previewEpisodes: [PreviewEpisode] = []
    @State private var isLoadingEpisodes = true
    @State private var isSubscribing = false
    @State private var subscribeError: String?
    @State private var subscribed = false
    @State private var feedDescription: String?
    @State private var feedWebsite: String?
    
    /// Tracks episode IDs that have been added to the queue, for visual feedback.
    @State private var queuedEpisodeIds: Set<UUID> = []
    /// Tracks episode IDs already in the queue (checked on load).
    @State private var alreadyInQueueIds: Set<UUID> = []
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Podcast Header
                    HStack(spacing: 16) {
                        CachedAsyncImage(url: URL(string: result.artworkUrl ?? "")) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                                .overlay {
                                    Image(systemName: "waveform")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                }
                        }
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.title)
                                .font(.title3.bold())
                                .lineLimit(3)
                            if let author = result.author {
                                Text(author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let genre = result.genre {
                                Text(genre)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Action Buttons
                    HStack(spacing: 12) {
                        Button {
                            subscribe()
                        } label: {
                            HStack {
                                if isSubscribing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                                Text(subscribed
                                     ? String(localized: "search.subscribed",
                                              defaultValue: "Subscribed ✓",
                                              comment: "Button state after the user follows a podcast. Keep the ✓ glyph. This is FOLLOWING A SHOW, not a paid subscription.")
                                     : String(localized: "search.subscribe",
                                              defaultValue: "Subscribe",
                                              comment: "Button that adds this podcast to the user's library. This is FOLLOWING A SHOW — no money is involved. The paid-plan button is a separate string."))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(subscribed ? .green : .accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isSubscribing || subscribed)
                    }
                    .padding(.horizontal)
                    
                    if let error = subscribeError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .padding(.horizontal)
                    }
                    
                    // Description (prefer search result, fall back to feed)
                    let descriptionText = (result.description?.isEmpty == false ? result.description : nil) ?? feedDescription
                    if let description = descriptionText, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(.headline)
                            Text(description.strippingHTML())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    
                    // Website (prefer search result, fall back to feed)
                    let websiteText = result.websiteUrl ?? feedWebsite
                    if let website = websiteText, let url = URL(string: website), let host = url.host() {
                        Link(destination: url) {
                            Label(host, systemImage: "globe")
                                .font(.subheadline)
                        }
                        .padding(.horizontal)
                    }
                    
                    // Latest Episodes with Stream + Queue Buttons
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Latest Episodes")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        if isLoadingEpisodes {
                            HStack {
                                Spacer()
                                ProgressView("Loading episodes...")
                                Spacer()
                            }
                            .padding()
                        } else if previewEpisodes.isEmpty {
                            Text("No episodes available")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        } else {
                            ForEach(previewEpisodes) { episode in
                                previewEpisodeRow(episode)
                                
                                if episode.id != previewEpisodes.last?.id {
                                    Divider()
                                        .padding(.horizontal)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Preview")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadPreviewEpisodes()
            }
        }
    }
    
    // MARK: - Episode Row
    
    @ViewBuilder
    private func previewEpisodeRow(_ episode: PreviewEpisode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.subheadline.bold())
                        .lineLimit(2)
                    if let pubDate = episode.pubDate {
                        Text(pubDate, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if let audioUrl = episode.audioUrl {
                    HStack(spacing: 8) {
                        // Add-to-queue button (with visual feedback). Same
                        // addToQueue(playNext: false) call as the context menu
                        // below, so it says the same thing the menu says.
                        if queuedEpisodeIds.contains(episode.id) {
                            // Just added — show confirmation
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        } else if alreadyInQueueIds.contains(episode.id) {
                            // Already in queue from previous add
                            Text("In Queue")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            // Add to queue button
                            Button {
                                addToQueue(episode, audioUrl: audioUrl, playNext: false)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.orange)
                            }
                            .accessibilityLabel("Add to Queue")
                        }
                        
                        // Stream button (play without subscribing)
                        Button {
                            streamEpisode(episode, audioUrl: audioUrl)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                        }
                        .accessibilityLabel("Stream episode")
                    }
                }
            }
            
            if let description = episode.description {
                Text(description.strippingHTML())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .contextMenu {
            if let audioUrl = episode.audioUrl {
                Button {
                    addToQueue(episode, audioUrl: audioUrl, playNext: true)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                
                Button {
                    addToQueue(episode, audioUrl: audioUrl, playNext: false)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                
                Divider()
                
                Button {
                    streamEpisode(episode, audioUrl: audioUrl)
                } label: {
                    Label("Stream Now", systemImage: "play.fill")
                }
                
                Button {
                    podcastManager.toggleHidden(guid: episode.guid, podcastUrl: result.feedUrl, audioUrl: audioUrl)
                } label: {
                    let isHidden = podcastManager.episodeActionSync.isHidden(guid: episode.guid)
                    Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                }
            }
        }
        // An all-literal ternary binds LocalizedStringKey and extracts both
        // words. The `{ … }()` closure this replaces returned String, so
        // neither "Unhide" nor "Hide" ever reached the catalog.
        .accessibilityAction(named: podcastManager.episodeActionSync.isHidden(guid: episode.guid) ? "Unhide" : "Hide") {
            if let audioUrl = episode.audioUrl {
                podcastManager.toggleHidden(guid: episode.guid, podcastUrl: result.feedUrl, audioUrl: audioUrl)
            }
        }
    }
    
    // MARK: - Actions
    
    private func subscribe() {
        isSubscribing = true
        subscribeError = nil
        Task {
            do {
                try await podcastManager.addSubscription(url: result.feedUrl)
                subscribed = true
            } catch {
                subscribeError = "Failed to subscribe: \(error.localizedDescription)"
            }
            isSubscribing = false
        }
    }
    
    /// Creates a QueueItem from preview episode data — no subscription required.
    /// Carries all available RSS metadata so the detail sheet can display full episode info
    /// even when the podcast is not in the user's library.
    private func makeQueueItem(from episode: PreviewEpisode, audioUrl: String) -> QueueItem {
        QueueItem(
            id: episode.id.uuidString,
            title: episode.title,
            podcastTitle: result.title,
            audioUrl: audioUrl,
            artworkUrl: episode.imageUrl ?? result.artworkUrl,
            durationSeconds: episode.durationSeconds,
            positionSeconds: 0,
            podcastUrl: result.feedUrl,
            pubDate: episode.pubDate,
            podcastAuthor: result.author,
            chaptersUrl: episode.chaptersUrl,
            transcriptUrl: episode.transcriptUrl,
            episodeDescription: episode.description
        )
    }
    
    private func streamEpisode(_ episode: PreviewEpisode, audioUrl: String) {
        let tempItem = makeQueueItem(from: episode, audioUrl: audioUrl)
        playerManager.playQueueItem(tempItem)
    }
    
    private func addToQueue(_ episode: PreviewEpisode, audioUrl: String, playNext: Bool) {
        let item = makeQueueItem(from: episode, audioUrl: audioUrl)
        if playNext {
            playerManager.audioManager.insertNext([item])
        } else {
            playerManager.audioManager.appendToQueue([item])
        }
        
        // Visual feedback — show "Added" for 2 seconds
        withAnimation(.easeInOut(duration: 0.3)) {
            _ = queuedEpisodeIds.insert(episode.id)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) {
                _ = queuedEpisodeIds.remove(episode.id)
                _ = alreadyInQueueIds.insert(episode.id)
            }
        }
    }
    
    @MainActor
    private func loadPreviewEpisodes() async {
        isLoadingEpisodes = true
        do {
            let rssService = RSSService()
            guard let (podcast, episodes) = try await rssService.fetchFeed(url: result.feedUrl) else { return }
            feedDescription = podcast.description
            feedWebsite = podcast.website
            let sorted = episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            previewEpisodes = sorted.prefix(20).map { ep in
                PreviewEpisode(
                    guid: ep.guid,
                    title: ep.title,
                    pubDate: ep.pubDate,
                    description: ep.description,
                    audioUrl: ep.audioUrl,
                    imageUrl: ep.imageUrl,
                    durationSeconds: ep.durationSeconds,
                    chaptersUrl: ep.chaptersUrl,
                    transcriptUrl: ep.transcriptUrl
                )
            }
        } catch {
            // Silently fail — just show empty episodes
        }
        isLoadingEpisodes = false
    }
}

/// Lightweight model for preview episodes (not persisted).
private struct PreviewEpisode: Identifiable {
    let id = UUID()
    let guid: String
    let title: String
    let pubDate: Date?
    let description: String?
    let audioUrl: String?
    /// Episode-specific artwork (e.g., The Daily uses unique photos per episode).
    /// Falls back to podcast artwork in makeQueueItem if nil.
    let imageUrl: String?
    /// Duration in seconds from itunes:duration in the RSS feed.
    let durationSeconds: Int?
    /// Podcasting 2.0 chapters URL
    let chaptersUrl: String?
    /// Podcasting 2.0 transcript URL
    let transcriptUrl: String?
}

