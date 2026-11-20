import Foundation
#if canImport(CarPlay)
import CarPlay
#endif
import os
import Combine

/// Native CarPlay integration for YourPods.
/// Uses CPTemplateApplicationSceneDelegate pattern to talk directly
/// to the CarPlay framework and the AudioManager.

#if canImport(CarPlay)
@available(iOS 14.0, *)
@MainActor
final class CarPlayService: NSObject {
    static let shared = CarPlayService()
    
    private let logger = Logger(subsystem: "com.yourpods", category: "CarPlay")
    
    // Dependencies
    weak var podcastManager: PodcastManager?
    weak var playerManager: PlayerManager?
    weak var audioManager: AudioManager?
    var networkMonitor: NetworkMonitor?
    /// Owns chapter state for the currently playing item. Set by
    /// YourPodsApp alongside the other dependencies above — CarPlayService is
    /// a singleton (`static let shared`) and can't take constructor args, so
    /// property injection is the established pattern here (see the other
    /// `weak var`s). `ChapterCoordinator` is `@MainActor`, and so is this
    /// class (`@MainActor final class CarPlayService`), so reading
    /// `chapterCoordinator?.visibleChapters` below is already on the right
    /// actor — no `MainActor.run` needed.
    weak var chapterCoordinator: ChapterCoordinator?

    // CarPlay state
    private var interfaceController: CPInterfaceController?
    private var tabBarTemplate: CPTabBarTemplate?

    // Image cache — uses shared ImageCacheStore for disk cache fallback.
    // Previously this was a CarPlay-local NSCache that was wiped on every
    // CarPlay connect, causing missing artwork on low/no network.
    
    // Debouncing
    private var debounceTimer: Timer?
    private var lastPodcastCount: Int = -1
    private var lastQueueCount: Int = -1
    private var lastRecentCount: Int = -1
    private var lastMediaItemId: String?
    private var suppressUpdates = false
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    private override init() { super.init() }
    
    // MARK: - Connection Lifecycle
    
    /// Maximum number of deferred init retries when dependencies aren't ready.
    private static let maxDeferredInitRetries = 5
    /// Counter for deferred init attempts.
    private var deferredInitRetries = 0
    
    func didConnect(interfaceController: CPInterfaceController) {
        logger.info("CarPlay connected")
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        
        // Configure Now Playing template with 5 custom buttons
        updateCarPlayButtons()
        
        // Reset caches to force full refresh
        lastPodcastCount = -1
        lastQueueCount = -1
        lastRecentCount = -1
        lastMediaItemId = nil

        
        // ── Deferred init: if dependencies aren't wired yet (race with app init),
        // retry every 0.5s up to maxDeferredInitRetries times. ──
        if self.podcastManager == nil || self.playerManager == nil || self.audioManager == nil {
            self.deferredInitRetries += 1
            if self.deferredInitRetries <= Self.maxDeferredInitRetries {
                self.logger.info("CarPlay dependencies not ready — deferring init (attempt \(self.deferredInitRetries)/\(Self.maxDeferredInitRetries))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.interfaceController != nil else { return }
                    self.didConnect(interfaceController: self.interfaceController!)
                }
                return
            } else {
                self.logger.warning("CarPlay dependencies still nil after \(Self.maxDeferredInitRetries) retries — proceeding with available state")
            }
        }
        self.deferredInitRetries = 0
        
        // Refresh when queue changes (reorder, add, remove)
        // Wrap existing handler (set by YourPodsApp for watch sync) instead of replacing
        let existingHandler = audioManager?.onQueueChanged
        audioManager?.onQueueChanged = { [weak self] in
            existingHandler?()
            self?.scheduleUpdate()
        }
        
        // Refresh buttons when rate or silence changes from phone side
        audioManager?.onPlaybackRateChanged = { [weak self] _ in
            self?.updateCarPlayButtons()
        }
        audioManager?.onSkipSilenceChanged = { [weak self] _ in
            self?.updateCarPlayButtons()
        }
        
        // Chapters no longer need their own onItemChanged wrap here:
        // ChapterCoordinator.attach(to:), wired once in YourPodsApp.init(),
        // already reloads `chapters` on every item change independent of
        // CarPlay's connection state. seekToPreviousChapter/seekToNextChapter
        // read chapterCoordinator?.visibleChapters directly at the moment the
        // user presses the button, which is always well after the coordinator
        // has resolved the current item — so there is nothing to snapshot or
        // pre-load here.

        updateContent()
    }
    
    func didDisconnect() {
        logger.info("CarPlay disconnected")
        interfaceController = nil
        debounceTimer?.invalidate()
        cancellables.removeAll()
    }
    
    // MARK: - Content Updates
    
    func scheduleUpdate() {
        guard !suppressUpdates else {
            logger.debug("Update suppressed during episode launch")
            return
        }
        // Use a longer debounce for queue reorders/updates to prevent UI jitter
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateContent()
            }
        }
    }
    
    private func updateContent() {
        guard let interfaceController,
              let podcastManager,
              let playerManager else { return }
        
        let subscriptions = podcastManager.subscriptions
        let queueCount = playerManager.audioManager.queue.count
        let currentId = playerManager.currentEpisodeGuid
        let recentEps = recentEpisodes(from: subscriptions)
        
        // Skip if no structural changes
        if subscriptions.count == lastPodcastCount &&
           queueCount == lastQueueCount &&
           currentId == lastMediaItemId &&
           recentEps.count == lastRecentCount {
            logger.debug("Skipping update — no structural changes")
            return
        }
        
        lastPodcastCount = subscriptions.count
        lastQueueCount = queueCount
        lastMediaItemId = currentId
        lastRecentCount = recentEps.count
        
        // Build tabs
        let nowPlayingTab = buildNowPlayingTab()
        let recentTab = buildRecentlyUpdatedTab(episodes: recentEps)
        let podcastsTab = buildPodcastsTab(subscriptions: subscriptions)
        
        let tabBar = CPTabBarTemplate(templates: [nowPlayingTab, recentTab, podcastsTab])
        self.tabBarTemplate = tabBar
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
    }
    
    // MARK: - Recently Updated Episodes (shared logic)
    
    /// Filters and sorts episodes the same way as HomeView.recentEpisodes.
    /// Returns unplayed, non-interacted episodes from the last 2 months,
    /// sorted by pubDate descending, capped at 20.
    private func recentEpisodes(from subscriptions: [Podcast]) -> [Episode] {
        RecentlyUpdatedFilter.filter(
            episodes: subscriptions.flatMap { $0.episodes },
            limit: 20
        ).episodes
    }
    
    // MARK: - Now Playing Tab
    
    private func buildNowPlayingTab() -> CPListTemplate {
        var sections: [CPListSection] = []
        
        // Offline indicator
        if let networkMonitor, !networkMonitor.isConnected {
            let offlineItem = CPListItem(
                text: "No Connection",
                detailText: "Downloaded episodes are still available."
            )
            offlineItem.setImage(UIImage(systemName: "wifi.slash") ?? UIImage())
            sections.append(CPListSection(items: [offlineItem], header: nil, sectionIndexTitle: nil))
        }
        
        // Current item
        if let current = audioManager?.currentItem {
            let detailText: String
            if audioManager?.isBuffering == true {
                detailText = "Connecting… — \(current.podcastTitle)"
            } else if audioManager?.errorMessage != nil {
                detailText = "No connection — \(current.podcastTitle)"
            } else {
                detailText = current.podcastTitle
            }
            let item = CPListItem(text: current.title, detailText: detailText)
            item.isPlaying = audioManager?.isPlaying ?? false
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                
                // Push the Now Playing template IMMEDIATELY — the user tapped
                // "play" and expects to see the Now Playing screen right away.
                // play() now sets MPNowPlayingInfoCenter metadata synchronously
                // (Fix 1 in AudioManager), so the template will have title/artwork
                // available when it appears. Audio starts in the background.
                let nowPlaying = CPNowPlayingTemplate.shared
                self.interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
                
                // Start playback after showing the template. play() handles both
                // hot resume (AVPlayer has item) and cold-start bootstrap.
                if !(self.audioManager?.isPlaying ?? false) {
                    self.audioManager?.play()
                }
                completion()
            }
            loadArtwork(url: current.artworkUrl, into: item)
            sections.append(CPListSection(items: [item], header: "Now Playing", sectionIndexTitle: nil))
        }
        
        // Up Next queue — already upcoming-only, no filter needed
        let upNext = audioManager?.queue ?? []
        
        if !upNext.isEmpty {
            let items = upNext.prefix(20).map { queueItem -> CPListItem in
                var detail = queueItem.podcastTitle
                if queueItem.positionSeconds > 0, let dur = queueItem.durationSeconds, dur > 0 {
                    let remaining = max(0, dur - queueItem.positionSeconds)
                    detail += " • \(DurationFormatting.remaining(TimeInterval(remaining)))"
                }
                
                let item = CPListItem(text: queueItem.title, detailText: detail)
                item.handler = { [weak self] _, completion in
                    self?.playQueueItem(queueItem)
                    completion()
                }
                loadArtwork(url: queueItem.artworkUrl, into: item)
                return item
            }
            sections.append(CPListSection(items: items, header: "Up Next", sectionIndexTitle: nil))
        }
        
        let template = CPListTemplate(title: "Now Playing", sections: sections)
        template.tabSystemItem = .mostRecent
        template.emptyViewTitleVariants = ["Nothing Playing"]
        template.emptyViewSubtitleVariants = ["Select a podcast to start listening."]
        return template
    }
    
    // MARK: - Recently Updated Tab
    
    private func buildRecentlyUpdatedTab(episodes: [Episode]) -> CPListTemplate {
        let items = episodes.map { episode -> CPListItem in
            var detail = episode.podcastTitle ?? ""
            if let date = episode.pubDate {
                let df = DateFormatter()
                df.dateStyle = .short
                detail += " • " + df.string(from: date)
            }
            
            let isPlaying = episode.guid == audioManager?.currentItem?.id && (audioManager?.isPlaying ?? false)
            let item = CPListItem(text: episode.title, detailText: detail)
            item.isPlaying = isPlaying
            item.handler = { [weak self] _, completion in
                guard let self, episode.podcast != nil else { completion(); return }
                self.playEpisode(episode)
                completion()
            }
            loadArtwork(url: episode.imageUrl ?? episode.podcast?.logoUrl, into: item)
            return item
        }
        
        let template = CPListTemplate(
            title: "Recent",
            sections: [CPListSection(items: items, header: "Recently Updated", sectionIndexTitle: nil)]
        )
        template.tabSystemItem = .recents
        template.emptyViewTitleVariants = ["All Caught Up!"]
        template.emptyViewSubtitleVariants = ["No new episodes to play."]
        return template
    }
    
    // MARK: - Podcasts Tab
    
    private func buildPodcastsTab(subscriptions: [Podcast]) -> CPListTemplate {
        // Check if groups are configured
        let profileId = UserDefaults.standard.string(forKey: "activeProfileId") ?? "global"
        let groups = PodcastGroup.loadGroups(forProfileId: profileId)
        
        var sections: [CPListSection] = []
        
        if groups.isEmpty {
            // Flat list — no groups configured
            let items = subscriptions.map { podcast -> CPListItem in
                buildPodcastListItem(podcast)
            }
            sections.append(CPListSection(items: items, header: "Library (\(items.count))", sectionIndexTitle: nil))
        } else {
            // Grouped sections
            let byGroup = Dictionary(grouping: subscriptions.filter { $0.groupId != nil }, by: { $0.groupId! })
            
            for group in groups.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let groupPodcasts = byGroup[group.id] ?? []
                guard !groupPodcasts.isEmpty else { continue }
                let items = groupPodcasts.map { buildPodcastListItem($0) }
                sections.append(CPListSection(items: items, header: group.name, sectionIndexTitle: nil))
            }
            
            // Ungrouped podcasts
            let ungrouped = subscriptions.filter { $0.groupId == nil }
            if !ungrouped.isEmpty {
                let items = ungrouped.map { buildPodcastListItem($0) }
                sections.append(CPListSection(items: items, header: "Other", sectionIndexTitle: nil))
            }
        }
        
        let template = CPListTemplate(title: "Podcasts", sections: sections)
        template.tabSystemItem = .featured
        template.emptyViewTitleVariants = ["No Subscriptions"]
        template.emptyViewSubtitleVariants = ["Add podcasts on your phone"]
        return template
    }
    
    /// Build a CPListItem for a single podcast in the Podcasts tab.
    private func buildPodcastListItem(_ podcast: Podcast) -> CPListItem {
        let item = CPListItem(
            text: podcast.title,
            detailText: "\(podcast.episodes.count) episodes"
        )
        item.handler = { [weak self] _, completion in
            self?.showEpisodes(for: podcast)
            completion()
        }
        loadArtwork(url: podcast.logoUrl, into: item)
        return item
    }
    
    // MARK: - Episode List (pushed)
    
    private func showEpisodes(for podcast: Podcast) {
        let sorted = podcast.episodes.sorted(by: episodesByFeedOrder)
        
        let items = sorted.prefix(50).map { episode -> CPListItem in
            var detail = ""
            if let date = episode.pubDate {
                let df = DateFormatter()
                df.dateStyle = .short
                detail = df.string(from: date)
            }
            
            let isPlaying = episode.guid == audioManager?.currentItem?.id && (audioManager?.isPlaying ?? false)
            let item = CPListItem(text: episode.title, detailText: detail)
            item.isPlaying = isPlaying
            item.handler = { [weak self] _, completion in
                self?.playEpisode(episode)
                completion()
            }
            loadArtwork(url: episode.imageUrl ?? podcast.logoUrl, into: item)
            return item
        }
        
        let template = CPListTemplate(
            title: podcast.title,
            sections: [CPListSection(items: items)]
        )
        
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    // MARK: - Playback Actions
    
    private func playEpisode(_ episode: Episode) {
        suppressUpdates = true
        debounceTimer?.invalidate()
        
        // PlayerManager owns resume vs relisten semantics. Completed episodes
        // restart from zero; in-progress episodes resume normally.
        playerManager?.playEpisode(episode)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let nowPlaying = CPNowPlayingTemplate.shared
            self?.interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.suppressUpdates = false
            self?.lastMediaItemId = self?.playerManager?.currentEpisodeGuid
            self?.lastQueueCount = self?.audioManager?.queue.count ?? 0
            self?.lastPodcastCount = self?.podcastManager?.subscriptions.count ?? 0
            self?.lastRecentCount = -1  // Force recent tab refresh after playing an episode
        }
    }
    
    private func playQueueItem(_ queueItem: QueueItem) {
        suppressUpdates = true
        debounceTimer?.invalidate()
        
        playerManager?.playQueueItem(queueItem)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let nowPlaying = CPNowPlayingTemplate.shared
            self?.interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.suppressUpdates = false
            self?.lastMediaItemId = self?.audioManager?.currentItem?.id
            self?.lastQueueCount = self?.audioManager?.queue.count ?? 0
        }
    }
    
    // MARK: - Now Playing Buttons
    
    /// Builds and sets the 5-button array on the Now Playing template.
    /// Called on connect and whenever rate, silence, or chapter state changes.
    private func updateCarPlayButtons() {
        // 1. Trim Silence toggle
        let silenceOn = audioManager?.skipSilenceEnabled ?? false
        let silenceIcon = silenceOn ? "waveform.path.badge.minus" : "waveform.path"
        let silenceButton = CPNowPlayingImageButton(image: labeledImage(systemName: silenceIcon, label: silenceOn ? "Silence On" : "Silence")) { [weak self] _ in
            self?.toggleTrimSilence()
        }
        
        // 2. Speed Down
        let speedDownButton = CPNowPlayingImageButton(image: labeledImage(systemName: "minus", label: "Slower")) { [weak self] _ in
            self?.decreasePlaybackRate()
        }
        
        // 3. Speed Up
        let speedUpButton = CPNowPlayingImageButton(image: labeledImage(systemName: "plus", label: "Faster")) { [weak self] _ in
            self?.increasePlaybackRate()
        }
        
        // 4. Previous Chapter
        let prevChapterButton = CPNowPlayingImageButton(image: labeledImage(systemName: "backward.end.fill", label: "Prev Ch")) { [weak self] _ in
            self?.seekToPreviousChapter()
        }
        
        // 5. Next Chapter
        let nextChapterButton = CPNowPlayingImageButton(image: labeledImage(systemName: "forward.end.fill", label: "Next Ch")) { [weak self] _ in
            self?.seekToNextChapter()
        }
        
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            silenceButton, speedDownButton, speedUpButton, prevChapterButton, nextChapterButton
        ])
    }
    
    // MARK: - Playback Rate
    
    /// Find the nearest rate index for the current rate (handles non-standard rates)
    private func nearestRateIndex(for rate: Float) -> Int {
        let rates = AudioManager.availableRates
        return rates.enumerated().min(by: { abs($0.element - rate) < abs($1.element - rate) })?.offset ?? 2
    }
    
    private func decreasePlaybackRate() {
        guard let audio = audioManager else { return }
        let rates = AudioManager.availableRates
        let idx = nearestRateIndex(for: audio.playbackRate)
        guard idx > 0 else {
            logger.debug("Already at minimum rate")
            return
        }
        let newRate = rates[idx - 1]
        audio.setPlaybackRate(newRate)
        logger.info("CarPlay rate decreased to \(newRate)×")
    }
    
    private func increasePlaybackRate() {
        guard let audio = audioManager else { return }
        let rates = AudioManager.availableRates
        let idx = nearestRateIndex(for: audio.playbackRate)
        guard idx < rates.count - 1 else {
            logger.debug("Already at maximum rate")
            return
        }
        let newRate = rates[idx + 1]
        audio.setPlaybackRate(newRate)
        logger.info("CarPlay rate increased to \(newRate)×")
    }
    
    // MARK: - Trim Silence
    
    private func toggleTrimSilence() {
        guard let audio = audioManager else { return }
        audio.skipSilenceEnabled.toggle()
        logger.info("CarPlay trim silence: \(audio.skipSilenceEnabled ? "ON" : "OFF")")
        updateCarPlayButtons()
    }
    
    // MARK: - Chapter Navigation
    //
    // Reads straight from ChapterCoordinator.visibleChapters rather
    // than hand-rolling a fallback chain — the old chain here called only
    // `ChapterService.shared.fetchChapters(url:)` then description parsing,
    // silently skipping inline Podlove `chaptersJSON`, so a Podlove-only feed
    // showed no chapters at all in CarPlay. The coordinator's own fallback
    // chain (embedded → podcast:chapters JSON → inline Podlove → description)
    // fixes that. See `chapterCoordinator`'s doc comment above for why no
    // `MainActor.run` is needed here.

    private func seekToPreviousChapter() {
        guard let chapters = chapterCoordinator?.visibleChapters, !chapters.isEmpty,
              let audio = audioManager else {
            logger.debug("CarPlay: no chapters available for previous-chapter seek")
            return
        }
        let pos = audio.currentPosition
        let currentIdx = chapters.lastIndex(where: { $0.startTime <= pos }) ?? 0
        // If within first 3s of current chapter, go to previous; otherwise restart current
        let targetIdx = (pos - chapters[currentIdx].startTime) < 3 ? max(0, currentIdx - 1) : currentIdx
        audio.seek(to: chapters[targetIdx].startTime)
        logger.info("CarPlay seek to chapter: \(chapters[targetIdx].title)")
    }

    private func seekToNextChapter() {
        guard let chapters = chapterCoordinator?.visibleChapters, !chapters.isEmpty,
              let audio = audioManager else {
            logger.debug("CarPlay: no chapters available for next-chapter seek")
            return
        }
        let pos = audio.currentPosition
        let currentIdx = chapters.lastIndex(where: { $0.startTime <= pos }) ?? 0
        guard currentIdx + 1 < chapters.count else {
            logger.debug("Already at last chapter")
            return
        }
        audio.seek(to: chapters[currentIdx + 1].startTime)
        logger.info("CarPlay seek to chapter: \(chapters[currentIdx + 1].title)")
    }
    
    // MARK: - Labeled Button Image
    
    /// Renders an SF Symbol with a text label below it into a single UIImage.
    /// `CPNowPlayingImageButton` doesn't support text labels, so we bake them into the image.
    private func labeledImage(systemName: String, label: String) -> UIImage {
        let size = CGSize(width: 54, height: 54)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            if let icon = UIImage(systemName: systemName, withConfiguration: iconConfig) {
                let iconSize = icon.size
                let iconOrigin = CGPoint(x: (size.width - iconSize.width) / 2, y: 2)
                icon.draw(at: iconOrigin)
            }
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
            let textRect = CGRect(x: 0, y: 36, width: size.width, height: 18)
            (label as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }
    
    // MARK: - Artwork Loading
    
    /// Generates a placeholder artwork image (podcast icon on a tinted background).
    private static let placeholderImage: UIImage = {
        let size = CGSize(width: 44, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.secondarySystemBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            if let icon = UIImage(systemName: "mic.fill", withConfiguration: iconConfig) {
                let iconSize = icon.size
                let origin = CGPoint(x: (size.width - iconSize.width) / 2,
                                     y: (size.height - iconSize.height) / 2)
                icon.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
                    .draw(at: origin)
            }
        }
    }()
    
    /// Load artwork asynchronously and set it on a CPListItem.
    /// Sets a placeholder immediately so artwork always appears on CarPlay,
    /// even when the async download is slow or items have already scrolled.
    private func loadArtwork(url: String?, into item: CPListItem) {
        // Always set a placeholder first — ensures artwork is never blank
        item.setImage(Self.placeholderImage)
        
        guard let urlString = url, let imageUrl = URL(string: urlString) else { return }
        
        let key = urlString as NSString
        
        // 1. Check shared memory cache (fastest, survives CarPlay reconnects)
        if let cached = ImageCacheStore.shared.cache.object(forKey: key) {
            let size = CGSize(width: 44, height: 44)
            let renderer = UIGraphicsImageRenderer(size: size)
            let resized = renderer.image { _ in cached.draw(in: CGRect(origin: .zero, size: size)) }
            item.setImage(resized)
            return
        }
        
        // 2. Check disk cache — critical for offline/low-network CarPlay.
        // Any artwork previously viewed in the phone app is available here.
        if let diskCached = ImageCacheStore.shared.loadFromDisk(key: urlString) {
            ImageCacheStore.shared.cache.setObject(diskCached, forKey: key)
            let size = CGSize(width: 44, height: 44)
            let renderer = UIGraphicsImageRenderer(size: size)
            let resized = renderer.image { _ in diskCached.draw(in: CGRect(origin: .zero, size: size)) }
            item.setImage(resized)
            return
        }
        
        // 3. Network fetch — placeholder stays visible until this completes
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageUrl)
                guard let image = UIImage(data: data) else { return }
                ImageCacheStore.shared.cache.setObject(image, forKey: key)
                ImageCacheStore.shared.saveToDisk(image: image, key: urlString)
                let size = CGSize(width: 44, height: 44)
                let renderer = UIGraphicsImageRenderer(size: size)
                let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                item.setImage(resized)
            } catch {
                logger.debug("Failed to load artwork: \(error.localizedDescription)")
                // Placeholder remains visible — user sees mic icon instead of blank
            }
        }
    }
}

// MARK: - CPInterfaceControllerDelegate

@available(iOS 14.0, *)
extension CarPlayService: CPInterfaceControllerDelegate {
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        logger.debug("Template appearing: \(type(of: aTemplate))")
    }
    
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {}
    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {}
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {}
}

// MARK: - CPTemplateApplicationSceneDelegate (Scene-based CarPlay)

@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayService.shared.didConnect(interfaceController: interfaceController)
    }
    
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayService.shared.didDisconnect()
    }
}
#endif // canImport(CarPlay)
