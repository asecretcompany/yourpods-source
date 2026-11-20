import Foundation
import os

/// Bridges UI interactions with the AudioManager and handles sync logic.
@Observable
@MainActor
final class PlayerManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "PlayerManager")
    
    let audioManager: AudioManager
    /// Setting this also hands the episode-action outbox somewhere to record the versions
    /// its own pushes earn, per the sync contract. This is the wiring point because it is the only one that
    /// has both objects — the outbox flush fires on the playback hot path, long before any
    /// orchestrator runs. The closure keeps `playbackBaselines` lazy.
    var podcastManager: PodcastManager? {
        didSet {
            podcastManager?.episodeActionSync.playbackBaselinesProvider = { [weak self] in
                self?.playbackBaselines
            }
        }
    }
    var settingsManager: SettingsManager?
    var downloadManager: DownloadManager?
    
    // Current playback state (sourced from AudioManager)
    var currentEpisodeGuid: String? { audioManager.currentItem?.id }
    var isPlaying: Bool { audioManager.isPlaying }
    var currentPosition: TimeInterval { audioManager.currentPosition }
    var currentDuration: TimeInterval { audioManager.currentDuration }
    var isBuffering: Bool { audioManager.isBuffering }
    
    /// Upcoming queue — does NOT include the currently playing item.
    var queue: [QueueItem] { audioManager.queue }
    
    /// GUIDs of all episodes in the Up Next queue + currently playing.
    /// Used by library views to show "In Queue" indicators.
    var queuedEpisodeGuids: Set<String> {
        var guids = Set(audioManager.queue.map(\.id))
        if let currentId = audioManager.currentItem?.id {
            guids.insert(currentId)
        }
        return guids
    }


    
    var errorMessage: String? { audioManager.errorMessage }
    
    /// Unresolved sync conflicts waiting for user resolution (populated when strategy = .ask)
    var pendingConflicts: [SyncConflict] = []
    
    /// Centralized conflict delivery.
    /// Merges new conflicts into pendingConflicts by episodeGuid (newer serverTimestamp wins).
    /// Gated on `.ask` strategy unless `bypassStrategyGate` is true.
    func deliverConflicts(_ conflicts: [SyncConflict], strategy: SyncStrategy,
                          bypassStrategyGate: Bool = false) {
        guard !conflicts.isEmpty else { return }
        guard bypassStrategyGate || strategy == .ask else { return }
        
        var merged = pendingConflicts
        for conflict in conflicts {
            if let existingIndex = merged.firstIndex(where: { $0.episodeGuid == conflict.episodeGuid }) {
                // Replace only if the new conflict has a newer server timestamp
                if conflict.serverTimestamp > merged[existingIndex].serverTimestamp {
                    merged[existingIndex] = conflict
                }
            } else {
                merged.append(conflict)
            }
        }
        pendingConflicts = merged
    }

    // MARK: - Playback CAS

    /// Per-episode CAS baselines. Lazy so construction (a file read) happens on first sync
    /// rather than at launch; injectable so tests can drive a temp file.
    @ObservationIgnored
    lazy var playbackBaselines = PlaybackBaselineStore(
        profileId: UserDefaults.standard.string(forKey: "activeProfileId")
    )

    /// Push one episode's playback state under the sync contract's CAS, then act on the answer.
    ///
    /// This is the seam the whole contract runs through. Before it existed, every push
    /// sent `baseVersion: nil` — legacy last-write-wins — and discarded the response, so
    /// `PlaybackReconciler`, `PlaybackSyncCoordinator` and the server's conflict
    /// persistence were all correct and all connected to nothing.
    ///
    /// - Parameters:
    ///   - baseVersionOverride: set only on a resolving re-push, where the baseline is the
    ///     version the *conflict* reported. Valid for that push and nothing else — the
    ///     store still holds the older agreed version, and must, until this push is acked.
    ///   - attempt: 1 for the ordinary push. `PlaybackSyncCoordinator` stops emitting
    ///     re-pushes at `maxAttempts`, which bounds this recursion.
    func pushPlaybackWithCAS(
        item: QueueItem,
        positionSec: Double,
        durationSec: Double? = nil,
        nowPlaying: Bool,
        completed: Bool?,
        client: any SyncClient,
        eventTime: Date?,
        attempt: Int,
        baseVersionOverride: Int64? = nil
    ) async {
        let url = item.audioUrl
        // The local side of row 4 is what this push *asserts*, not whatever the player has
        // drifted to since — that keeps the resolution deterministic for the request it
        // answers. Drift is the next cycle's problem, and the next cycle will see it.
        let snapshot = PlaybackSnapshot(
            positionSec: positionSec,
            completed: completed ?? item.isPlayed,
            nowPlaying: nowPlaying
        )
        let baseVersion = baseVersionOverride
            ?? PlaybackReconciler.baseVersionForPush(baseline: playbackBaselines.baseline(for: url))

        let response: ProPlaybackSyncResponse?
        do {
            response = try await client.syncPlayback(
                podcastUrl: item.podcastUrl,
                episodeUrl: url,
                episodeGuid: item.id,
                positionSec: positionSec,
                durationSec: durationSec ?? item.durationSeconds.map(Double.init),
                nowPlaying: nowPlaying,
                // Sync contract: never `nil` on a versioned push. The CAS branch assigns the value
                // columns verbatim — `completed = EXCLUDED.completed`, no merge, no
                // `GREATEST`, no event-time predicate — and Go decodes an *absent*
                // `completed` as `false`, which `encodeIfPresent` is exactly what produces.
                // So omitting the flag is not silence; it is an assertion that the episode
                // is unfinished, written over whatever another device just marked played.
                //
                // `snapshot.completed` rather than the parameter: it is the same value the
                // reconciler resolves this push against, so the wire and the ladder agree
                // about what was claimed. Passing `nil` meant the server was told `false`
                // while row 4 was evaluated as `item.isPlayed`, and a conflict came back
                // attributed to the wrong side.
                completed: snapshot.completed,
                deviceId: deviceId,
                clientUpdatedAt: eventTime,
                baseVersion: baseVersion
            )
        } catch {
            logger.error("Playback CAS push failed for \(item.title): \(error.localizedDescription)")
            return
        }

        // A deployment predating the sync contract answers with no arrays, and gPodder/Vault clients
        // answer `nil`. Neither is an error — they are servers with nothing to say about CAS.
        guard let response else { return }

        let strategy = settingsManager?.syncConflictStrategy ?? .ask
        let outcome = PlaybackSyncCoordinator.apply(
            response: response,
            pushed: [url: snapshot],
            strategy: strategy,
            store: playbackBaselines,
            attempt: attempt
        )

        for adopt in outcome.adopts {
            applyPlaybackAdopt(adopt)
        }

        if !outcome.prompts.isEmpty {
            deliverConflicts(outcome.prompts.map { conflictRow(for: $0, item: item) }, strategy: strategy)
        }

        for rePush in outcome.rePushes {
            await pushPlaybackWithCAS(
                item: item,
                positionSec: rePush.position,
                durationSec: durationSec,
                nowPlaying: nowPlaying,
                completed: rePush.completed,
                client: client,
                eventTime: eventTime,
                attempt: attempt + 1,
                baseVersionOverride: rePush.baseVersion
            )
        }
    }

    /// Write an adopted server position into the player.
    ///
    /// Guarded on the adopt still describing the episode that is loaded. A response can
    /// land after the user has moved on, and writing episode A's position onto episode B
    /// is precisely the silent corruption the sync contract exists to eliminate. `adoptRemotePosition`
    /// is the single definition of "take a remote position" — it writes `currentPosition`
    /// explicitly (an `AVPlayer.seek` alone is a no-op with no item loaded) and does not
    /// stamp a fresh local event time, because a remote adopt is not a local playback event.
    /// Take the server's state for this episode — **all** of it.
    ///
    /// `PlaybackSyncCoordinator` emits decisions as data rather than effects, which is what
    /// makes the deciding assertable without a network or an `AVPlayer`; this is the other
    /// half, where the decision becomes a write. `Adopt` carries `position` *and*
    /// `completed`, and taking only the position leaves the device holding a position it
    /// agreed to and a completion it did not — while the baseline records that the two
    /// sides agree, so nothing later re-raises it.
    ///
    /// Marked local-only on purpose: this IS the server's answer arriving, so echoing an
    /// `EpisodeAction` back would report its own input as news. Same reason
    /// `applyCompletedChanges` mutates directly (per the sync contract).
    ///
    /// Internal rather than private so the write half can be driven directly in tests; the
    /// decision half already is.
    func applyPlaybackAdopt(_ adopt: PlaybackSyncCoordinator.Adopt) {
        guard let item = audioManager.currentItem, item.audioUrl == adopt.episodeUrl else {
            logger.info("Skipped playback adopt — the loaded episode changed mid-flight")
            return
        }
        audioManager.adoptRemotePosition(adopt.position, eventTime: nil)

        // Until the sync contract was enforced this was partly masked: the position heuristic re-marked
        // anything past 95% played, so an adopted completion near the end looked like it
        // worked. That crutch is gone on Pro — and it never covered the false direction,
        // where nothing else will clear a stale isPlayed.
        if adopt.completed {
            podcastManager?.markEpisodePlayedLocally(podcastUrl: item.podcastUrl, episodeGuid: item.id)
        } else {
            podcastManager?.markEpisodeAsUnplayedLocally(podcastUrl: item.podcastUrl, episodeGuid: item.id)
        }

        logger.info("Adopted server position \(adopt.position) completed=\(adopt.completed) for: \(adopt.episodeUrl)")
    }

    /// `serverTimestamp` is the arrival time, not an event time: a sync-contract conflict payload
    /// carries a `version`, not a clock. `deliverConflicts` uses it only to decide which of
    /// two reports of the same episode to keep, so "most recently observed" is the honest
    /// ordering and it matches how the rest of reconciliation already behaves.
    private func conflictRow(
        for prompt: PlaybackSyncCoordinator.Prompt,
        item: QueueItem
    ) -> SyncConflict {
        SyncConflict(
            episodeGuid: item.id,
            episodeTitle: item.title,
            podcastTitle: item.podcastTitle,
            podcastUrl: item.podcastUrl,
            artworkUrl: item.artworkUrl,
            audioUrl: item.audioUrl,
            localPosition: Int(prompt.localPosition),
            serverPosition: Int(prompt.serverPosition),
            serverTimestamp: Int(Date().timeIntervalSince1970),
            totalDuration: item.durationSeconds,
            occurrenceCount: 1,
            serverConflictId: nil
        )
    }

    /// Unresolved URL rewrite conflicts from server's `update_urls` response.
    var pendingUrlRewrites: [URLRewriteConflict] = []

    /// oldUrls the user explicitly rejected ("Keep local") this session. The server
    /// keeps returning an unresolved rewrite on every sync until some device resolves
    /// it, so without this set the conflict sheet would re-pop forever after a reject.
    private(set) var rejectedUrlRewriteOldUrls: Set<String> = []

    /// Centralized URL-rewrite delivery — the rewrite analogue of `deliverConflicts`.
    /// Gated on `.ask` so it respects `syncConflictStrategy` (serverWins/deviceWins
    /// users opted out of prompts); dedupes by `oldUrl` so a still-unresolved rewrite
    /// returned on every sync is not appended twice (a duplicate `Identifiable` id
    /// breaks the SwiftUI conflict list); skips rewrites already rejected this session.
    func deliverUrlRewrites(_ rewrites: [URLRewriteConflict], strategy: SyncStrategy) {
        guard !rewrites.isEmpty else { return }
        guard strategy == .ask else { return }

        var merged = pendingUrlRewrites
        var seen = Set(merged.map(\.oldUrl))
        for rewrite in rewrites {
            guard !rejectedUrlRewriteOldUrls.contains(rewrite.oldUrl) else { continue }
            guard seen.insert(rewrite.oldUrl).inserted else { continue }
            merged.append(rewrite)
        }
        pendingUrlRewrites = merged
    }

    /// Record that the user rejected ("Keep local") a URL rewrite: drop it from the
    /// pending list and suppress it from re-surfacing on subsequent syncs.
    func recordRejectedUrlRewrite(oldUrl: String) {
        rejectedUrlRewriteOldUrls.insert(oldUrl)
        pendingUrlRewrites.removeAll { $0.oldUrl == oldUrl }
    }

    // Sync state
    private var lastSyncTime = Date.distantPast
    private var lastLocalSaveTime = Date.distantPast
    private var syncClient: (any SyncClient)?
    private(set) var deviceId = "swift-client"
    
    /// True while `syncQueueWithServer()` is running. Used to suppress
    /// `pushQueueToProServerDebounced()` and prevent racing pushes.
    private(set) var isSyncingQueue = false

    // ── YourPods Pro: Stats buffer & segment tracking ────────────────────
    /// Accumulates listening/skip events for async batch upload via Pro API.
    /// `PodcastManager.refreshAndSync` flushes this via `pushStatsEvents`.
    let statsBuffer = StatsEventBuffer()

    /// Tracks the current continuous listening segment.
    /// Opened on play/seek, closed on pause/skip/episode-end.
    private var segmentStartPosition: Double?
    private var segmentStartWallTime: Date?
    
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        
        // Restore persisted queue from last session
        audioManager.restoreQueue()
        
        // Capture the episode being left, at the position it was actually left at,
        // before `currentItem` is replaced and that position is gone.
        audioManager.onItemWillChange = { [weak self] outgoing in
            self?.trackPreviousItem(outgoing)
        }

        // Play-then-sync: when a new episode starts, fire background sync
        audioManager.onItemChanged = { [weak self] item in
            guard let self, let item else { return }
            self.closeAndRecordSegment()
            self.handleItemChanged(item)
            self.beginSegment()
        }
        
        audioManager.onEpisodeCompleted = { [weak self] item in
            self?.closeAndRecordSegment()
            self?.handleEpisodeCompleted(item)
        }

        // Wire playback error telemetry to the Pro server
        audioManager.onPlaybackError = { [weak self] epUrl, epGuid, podUrl, errorDesc, attempt in
            guard let self, let proClient = self.syncClient as? YourPodsProClient else { return }
            Task {
                await proClient.reportPlaybackError(
                    episodeUrl: epUrl,
                    episodeGuid: epGuid,
                    podcastUrl: podUrl,
                    errorDescription: errorDesc,
                    recoveryAttempt: attempt,
                    deviceId: self.deviceId
                )
            }
        }
        
        // Wire settings resolver so AudioManager can re-resolve per-podcast
        // settings at play time (skip intro/outro, speed, skip forward/backward).
        // This ensures stale QueueItem values from enqueue time are replaced
        // with live settings, fixing the bug where setting changes after
        // enqueueing (or from sync) were ignored.
        audioManager.settingsResolver = { [weak self] item in
            guard let self else { return (skipIntro: 0, skipOutro: 0, speed: 1.0, skipForward: 30, skipBackward: 15) }
            let podcast = self.podcastManager?.subscriptions.first { $0.url == item.podcastUrl }
            let podSettings = podcast?.effectiveSettings
            return (
                skipIntro: podSettings?.skipIntroSeconds ?? self.settingsManager?.skipIntroSeconds ?? 0,
                skipOutro: podSettings?.skipOutroSeconds ?? self.settingsManager?.skipOutroSeconds ?? 0,
                speed: Float(podSettings?.playbackSpeed ?? self.settingsManager?.playbackSpeed ?? 1.0),
                skipForward: self.settingsManager?.skipForwardSeconds ?? 30,
                skipBackward: self.settingsManager?.skipBackwardSeconds ?? 15
            )
        }
        
        // Wire auto-flush handler so the buffer can trigger uploads
        // when the 50-event limit or 30s periodic timer fires.
        // This is safe for all account types — flushStatsIfAuthenticated()
        // guards on syncClient as? YourPodsProClient.
        Task { [weak self] in
            guard let self else { return }
            await self.statsBuffer.setFlushHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.flushStatsIfAuthenticated()
                }
            }
        }
    }
    
    /// In-flight login/playback sync task. Tracked so lifecycle handlers can
    /// cancel it — setSyncClient fires on EVERY cold launch (including
    /// BGAppRefreshTask background launches), and an untracked task here
    /// survives BGTask expiration and keeps writing after the background
    /// window closes (0xDEAD10CC exposure).
    private(set) var playbackSyncTask: Task<Void, Never>?

    /// Cancel the in-flight login/playback sync, if any.
    /// Called from the scenePhase .background handler alongside
    /// PodcastManager.cancelActiveSync().
    func cancelInFlightPlaybackSync() {
        playbackSyncTask?.cancel()
    }

    func setSyncClient(_ client: (any SyncClient)?, deviceId: String) {
        self.syncClient = client
        self.deviceId = deviceId

        // Clear queue sync state on logout so a re-login
        // correctly detects "first sync" on this profile
        if client == nil {
            UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
            UserDefaults.standard.removeObject(forKey: Self.proQueueSyncServerGuidsKey)
        }

        // Initial sync on login — cancel-and-replace so a profile switch
        // doesn't leave the previous profile's sync racing the new one.
        playbackSyncTask?.cancel()
        playbackSyncTask = Task {
            await syncPlaybackState()
            guard !Task.isCancelled else { return }
            // If no episode is loaded, try to restore the now-playing episode from another device
            await restoreNowPlayingFromProServer()
        }
    }
    
    // MARK: - Playback Controls (forwarded to AudioManager)
    
    func play() {
        audioManager.play()
        beginSegment()
        Task { await statsBuffer.startPeriodicFlush() }
        pushWidgetUpdate()
    }
    func pause() {
        closeAndRecordSegment()
        audioManager.pause()
        forceSyncProgress()
        Task { await statsBuffer.stopPeriodicFlush() }
        // Tell the Pro server we're still on this episode (paused)
        syncNowPlayingToProServer(nowPlaying: true)
        flushStatsIfAuthenticated()
        pushWidgetUpdate()
    }
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    func seek(to seconds: TimeInterval) {
        closeAndRecordSegment()
        audioManager.seek(to: seconds)
        beginSegment()
    }
    func seekRelative(seconds: TimeInterval) {
        closeAndRecordSegment()
        audioManager.seekRelative(seconds: seconds)
        beginSegment()
    }
    func skipToNext() {
        closeAndRecordSegment()
        if let item = audioManager.currentItem {
            let from = currentPosition
            let event = ProStatsEvent(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                eventType: .skipManual,
                fromPosSec: from,
                toPosSec: 0,
                durationSec: 0,
                contentSec: 0,
                speed: Double(audioManager.playbackRate),
                deviceId: deviceId
            )
            Task { await statsBuffer.record(event) }
        }
        // The player's next button and Siri's "next episode". Moving on is not finishing:
        // completing here marks the episode played and pushes its full duration to every
        // other device. The outgoing position still travels, via onItemWillChange.
        audioManager.skipToNext(completingCurrent: false)
    }
    func skipToPrevious() {
        closeAndRecordSegment()
        if let item = audioManager.currentItem {
            let from = currentPosition
            let event = ProStatsEvent(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                eventType: .skipManual,
                fromPosSec: from,
                toPosSec: 0,
                durationSec: 0,
                contentSec: 0,
                speed: Double(audioManager.playbackRate),
                deviceId: deviceId
            )
            Task { await statsBuffer.record(event) }
        }
        audioManager.skipToPrevious()
    }
    
    func setPlaybackRate(_ rate: Float) {
        audioManager.setPlaybackRate(rate)
        settingsManager?.playbackSpeed = Double(rate)
    }
    
    // MARK: - Queue Operations
    
    func addToQueue(_ episode: Episode, playNext: Bool = false) {
        guard var item = QueueItem.from(episode: episode) else { return }
        // Capture played state BEFORE any mutation — needed to decide whether to
        // issue the relisten server call below.
        let wasPlayed = episode.isPlayed
        // Apply global fallbacks for skip/speed if per-podcast isn't set
        item = applyEffectiveSettings(item, episode: episode)
        // Attach local file URL if this episode has been downloaded
        item.localFileUrl = downloadManager?.localUrl(for: episode.guid)
        if playNext {
            audioManager.insertNext([item])
        } else {
            audioManager.appendToQueue([item])
        }
        // Mark interacted so episode is removed from Recently Updated
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
        // Re-add of a previously-played episode = relisten: un-play locally so the
        // queue's played-filters don't immediately drop it, then tell the server
        // additively (/queue/add clears completed + tombstone + resets position
        // server-side — do NOT also call uncompletePlayback, that would double-POST).
        if wasPlayed {
            podcastManager?.markEpisodeAsUnplayedLocally(podcastUrl: item.podcastUrl, episodeGuid: item.id)
            if let syncClient {
                let syncItem = QueueSyncItem(
                    podcastUrl: item.podcastUrl,
                    episodeUrl: item.audioUrl,
                    episodeGuid: item.id,
                    sortOrder: 0,
                    positionSec: 0,
                    title: item.title,
                    podcastTitle: item.podcastTitle,
                    artworkUrl: item.artworkUrl,
                    durationSec: item.durationSeconds.map { Double($0) }
                )
                Task {
                    guard await syncClient.supportsQueueSync else { return }
                    do { try await syncClient.addToQueue(item: syncItem, addToTop: playNext) }
                    catch { logger.error("addToQueue server call failed: \(error.localizedDescription)") }
                }
            }
        }
    }
    
    /// Batch add episodes to the queue, preserving their order.
    /// When `playNext` is true, uses a single `insertNext` call so episodes
    /// appear at the top in the correct order (not reversed).
    func addToQueue(_ episodes: [Episode], playNext: Bool = false) {
        let items = episodes.compactMap { ep -> QueueItem? in
            guard var item = QueueItem.from(episode: ep) else { return nil }
            item = applyEffectiveSettings(item, episode: ep)
            // Attach local file URL if this episode has been downloaded
            item.localFileUrl = downloadManager?.localUrl(for: ep.guid)
            return item
        }
        guard !items.isEmpty else { return }
        if playNext {
            audioManager.insertNext(items)
        } else {
            audioManager.appendToQueue(items)
        }
        for item in items {
            podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
        }
    }
    
    func removeFromQueue(_ item: QueueItem) {
        audioManager.removeFromQueue(item)

        // Durable suppression so auto-queue won't re-add this episode next refresh.
        // Pro relies on the server tombstone below; gPodder/Vault rely on this flag.
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)

        // Notify Pro server of the deletion (tombstone) to prevent re-addition.
        // No-op for gPodder / Vault via the protocol default extension.
        if let syncClient {
            let episodeUrl = item.audioUrl
            Task {
                do {
                    guard await syncClient.supportsQueueSync else { return }
                    try await syncClient.deleteQueueItem(episodeUrl: episodeUrl)
                    logger.info("Deleted queue item on server: \(item.title)")
                } catch {
                    logger.error("Failed to delete queue item on server: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Mark the currently-playing episode as played.
    ///
    /// User-initiated (`fromSync == false`) with episodes in Up Next: advances to the
    /// next episode through the same machinery as the next-track command — audio keeps
    /// playing if it was playing, or the next episode loads paused if it wasn't. On
    /// this branch the `onEpisodeCompleted` pipeline (`handleEpisodeCompleted`) performs
    /// ALL played-marking and server sync; do NOT also call `markEpisodeAsPlayed` here
    /// or the server receives a duplicate 'play' EpisodeAction (see the note at the
    /// top of `handleEpisodeCompleted`).
    ///
    /// Empty queue, or sync-initiated: marks played and stops. Sync callers run during
    /// background reconciliation (`clearPlayedEpisodesFromQueue`, `reconcileNowPlaying`
    /// Cases 1/4) — an advance there could start audio the user never asked for.
    ///
    /// - Parameter fromSync: When `true`, uses `markEpisodePlayedLocally` (no outbound
    ///   `EpisodeAction`) to prevent redundant server echoes during reconciliation.
    func markCurrentEpisodeAsPlayed(fromSync: Bool = false) {
        // Re-entrancy guard: a queue advance (skipToNext, via the branch below) may
        // already be mid-flight — e.g. a double-tap where the first tap's advance Task
        // is suspended at URL resolution. Without this, a second call would set
        // isPlayed on the item the in-flight advance is about to swap in as
        // currentItem, then stop() or re-advance underneath it. Covers both branches
        // since it runs before the isPlayed mutation below. Safe for fromSync callers:
        // a skipped reconcile-clear is caught on the next sync cycle.
        guard !audioManager.isAdvancingQueue else {
            logger.debug("markCurrentEpisodeAsPlayed ignored: queue advance in progress")
            return
        }
        guard let item = audioManager.currentItem else { return }

        // Set isPlayed on the QueueItem BEFORE any transition, so that if
        // playEpisode(preserveCurrent:) is reached during the switch, the
        // played episode can never be re-inserted into the queue.
        var playedItem = item
        playedItem.isPlayed = true
        audioManager.currentItem = playedItem

        if !fromSync && !audioManager.queue.isEmpty {
            // Advance like a manual skip. skipToNext fires onEpisodeCompleted →
            // handleEpisodeCompleted, which marks played + syncs the completion
            // (exactly one pipeline). autoPlay mirrors the current playback state
            // so marking-played while paused never starts audio (D2).
            audioManager.skipToNext(autoPlay: audioManager.isPlaying)
            return
        }

        if fromSync {
            // Sync-initiated: mark played locally only (no outbound EpisodeAction).
            // The server already told us this episode is complete — don't echo it back.
            podcastManager?.markEpisodePlayedLocally(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
        } else {
            // User-initiated with nothing queued: mark played (SwiftData + gPodder
            // action + durable Pro completion) and stop.
            podcastManager?.markEpisodeAsPlayed(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
        }

        // Stop playback — the episode is done and there is nothing to advance to.
        audioManager.stop()
    }
    
    /// Remove the currently-playing episode from the queue without marking it as played.
    /// Saves progress, stops playback, and clears the current item.
    /// Unlike `markCurrentEpisodeAsPlayed()`, this preserves the episode's unplayed status.
    func removeCurrentEpisodeFromQueue() {
        guard let current = audioManager.currentItem else { return }

        // Save current progress before stopping so no position data is lost
        forceSyncProgress()

        // Durable suppression so auto-queue won't re-add this episode next refresh
        // (gPodder/Vault have no server queue). Does NOT mark played — the episode
        // keeps its unplayed status. Must run before stop() clears currentItem.
        podcastManager?.markEpisodeAsInteracted(current.podcastUrl, current.id)

        // Fix D (iOS→web): clear the server now-playing so other devices (e.g. the
        // web mini player) stop showing this as the current episode. We do NOT mark
        // it completed — the episode keeps its unplayed status. Must run before
        // stop() clears currentItem (syncNowPlayingToProServer reads currentItem).
        syncNowPlayingToProServer(nowPlaying: false)

        // Stop current playback — clears currentItem, position, and now-playing info
        audioManager.stop()
    }
    
    /// Mark an Up Next queued episode as played: remove from queue (with server tombstone) and mark played.
    func markQueuedEpisodeAsPlayed(_ item: QueueItem) {
        removeFromQueue(item)  // Uses self.removeFromQueue which sends server tombstone
        podcastManager?.markEpisodeAsPlayed(
            podcastUrl: item.podcastUrl,
            episodeGuid: item.id
        )
    }
    
    /// Clear everything from the queue: stop playback, remove the currently playing
    /// item, and remove all upcoming episodes. Optionally marks episodes as played
    /// based on the user's queue removal preference. Sends server tombstones for
    /// Pro sync users.
    func clearAllQueue() {
        // Capture all items BEFORE clearing so we can send tombstones and mark played
        var allItems: [QueueItem] = audioManager.queue
        if let current = audioManager.currentItem {
            allItems.append(current)
        }
        
        // Respect the user's queue removal preference
        let shouldMarkPlayed = settingsManager?.queueRemovalAction == .removeAndMarkPlayed
        if shouldMarkPlayed {
            for item in allItems {
                podcastManager?.markEpisodeAsPlayed(
                    podcastUrl: item.podcastUrl,
                    episodeGuid: item.id
                )
            }
        } else {
            // Remove-only: mark interacted (not played) so auto-queue won't re-add
            // these episodes next refresh (gPodder/Vault have no server queue).
            for item in allItems {
                podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
            }
        }
        
        // Clear everything: upcoming queue + stop playback (clears currentItem,
        // position, duration, and now-playing info)
        audioManager.clearQueue()
        audioManager.stop()
        LiveActivityService.shared.clearWidgetData()
        
        // Send server tombstones for Pro sync users
        if let syncClient {
            for item in allItems {
                let episodeUrl = item.audioUrl
                Task {
                    do {
                        guard await syncClient.supportsQueueSync else { return }
                        try await syncClient.deleteQueueItem(episodeUrl: episodeUrl)
                        logger.info("Deleted queue item on server (clear all): \(item.title)")
                    } catch {
                        logger.error("Failed to delete queue item on server: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        audioManager.moveQueueItems(from: source, to: destination)
    }

    /// Play an existing QueueItem selected by the user.
    ///
    /// A stale queue item can still carry its last position after the corresponding
    /// Episode has been marked played. Treat explicit selection as a relisten:
    /// clear completion through the normal sync path and restart from the beginning.
    func playQueueItem(_ queueItem: QueueItem, position: TimeInterval? = nil) {
        var item = queueItem
        let wasPlayed = item.isPlayed || podcastManager?.isEpisodePlayed(
            podcastUrl: item.podcastUrl,
            guid: item.id
        ) == true

        if wasPlayed {
            podcastManager?.markEpisodeAsUnplayed(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
            item.isPlayed = false
        }

        // No explicit position means ordinary replay/resume semantics:
        // completed -> 0, unfinished -> saved position. An explicit position is
        // deliberate user intent (e.g. "Play from 12:34" on a shared episode),
        // so preserve it while still clearing completed state.
        let initialPosition = position ?? TimeInterval(wasPlayed ? 0 : item.positionSeconds)
        item.positionSeconds = Int(initialPosition)

        Task {
            await audioManager.playEpisode(
                item,
                initialPosition: initialPosition,
                preserveCurrent: true
            )
        }
    }
    
    /// Play an Episode selected by the user.
    ///
    /// Explicitly selecting a completed episode always means "relisten": clear the
    /// completed state through the normal sync path and restart from zero. This rule
    /// lives here so every Episode-based surface (library, search results, Siri,
    /// deeplinks, CarPlay, etc.) gets identical behavior.
    func playEpisode(_ episode: Episode, position: TimeInterval? = nil) {
        let wasPlayed = episode.isPlayed
        if wasPlayed, let podcastUrl = episode.podcastUrl {
            podcastManager?.markEpisodeAsUnplayed(
                podcastUrl: podcastUrl,
                episodeGuid: episode.guid
            )
        }

        guard var item = QueueItem.from(episode: episode) else { return }
        let initialPosition: TimeInterval? = wasPlayed ? 0 : position
        
        // Mark interacted so episode is removed from Recently Updated
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
        
        // Apply per-podcast settings with global fallbacks
        item = applyEffectiveSettings(item, episode: episode)
        
        // Attach local file URL if this episode has been downloaded
        item.localFileUrl = downloadManager?.localUrl(for: episode.guid)
        
        // Also set instance-level settings for backward compatibility
        if let podcast = episode.podcast {
            let settings = podcast.effectiveSettings
            audioManager.skipIntroSeconds = settings.skipIntroSeconds ?? settingsManager?.skipIntroSeconds ?? 0
            audioManager.skipOutroSeconds = settings.skipOutroSeconds ?? settingsManager?.skipOutroSeconds ?? 0
            
            let speed = settings.playbackSpeed ?? settingsManager?.playbackSpeed ?? 1.0
            audioManager.setPlaybackRate(Float(speed))
        }
        
        // Apply headphone/remote command actions from settings
        audioManager.nextTrackAction = settingsManager?.nextTrackAction ?? .nextEpisode
        audioManager.previousTrackAction = settingsManager?.previousTrackAction ?? .skipBack
        
        Task {
            await audioManager.playEpisode(item, initialPosition: initialPosition, preserveCurrent: true)
        }
    }
    
    /// Resolve effective skip/speed settings for a QueueItem, applying global fallbacks.
    private func applyEffectiveSettings(_ item: QueueItem, episode: Episode) -> QueueItem {
        var result = item
        let podSettings = episode.podcast?.effectiveSettings
        result.skipIntroSeconds = podSettings?.skipIntroSeconds ?? settingsManager?.skipIntroSeconds ?? 0
        result.skipOutroSeconds = podSettings?.skipOutroSeconds ?? settingsManager?.skipOutroSeconds ?? 0
        result.playbackSpeed = Float(podSettings?.playbackSpeed ?? settingsManager?.playbackSpeed ?? 1.0)
        // P3: per-podcast privacyMode overrides global p3Enabled
        result.privacyMode = podSettings?.privacyMode ?? settingsManager?.p3Enabled ?? false
        return result
    }
    
    // MARK: - Play-Then-Sync
    
    private func handleItemChanged(_ item: QueueItem) {
        logger.info("Episode changed to: \(item.title). Triggering background sync...")
        
        // Fire sync in background — don't block playback
        Task {
            await syncPlaybackState()
        }
        
        // Bug 2 fix: Clear previous episode's nowPlaying before setting new one.
        // This prevents the server from showing stale "now playing" state for
        // the episode the user just left (especially when they skip at 50%).
        let previous = previousItemForSync
        syncNowPlayingToProServer(nowPlaying: true, clearingPrevious: previous)

        // Consumed. `onItemWillChange` sets the next one at the next switch, from the
        // outgoing episode rather than from this incoming one — leaving it set would
        // re-clear an episode that has already been cleared.
        previousItemForSync = nil
        
        pushWidgetUpdate()
    }
    
    /// Sync playback state with the server. If the server has a later position, seek forward.
    func syncPlaybackState() async {
        guard let podcastManager else { return }
        
        do {
            let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
            // P1-1: Use incremental sync (force: false) on track changes.
            // Only pulls actions since the last sync timestamp, not the entire history.
            // Full pulls (force: true) are reserved for manual refresh and orchestrators.
            let conflicts = try await podcastManager.syncEpisodeActions(force: false, strategy: strategy)
            
            // Surface unresolved conflicts for user resolution
            deliverConflicts(conflicts, strategy: strategy)
            
            // If the current episode has a server position ahead of ours, seek to it.
            // Only auto-seek when strategy is .serverWins — for .deviceWins/.ask,
            // the device position is authoritative and should not be overridden.
            if strategy == .serverWins, let currentGuid = currentEpisodeGuid {
                let isConflicted = conflicts.contains { $0.episodeGuid == currentGuid }
                if !isConflicted, let action = podcastManager.getLatestAction(for: currentGuid),
                   let serverPos = action.position {
                    let localPos = Int(currentPosition)
                    if serverPos > localPos + SyncThresholds.liveForwardSeekGapSeconds {
                        logger.info("Server position ahead (\(localPos) → \(serverPos)), seeking...")
                        audioManager.seek(to: TimeInterval(serverPos))
                    }
                }
            }
        } catch {
            logger.error("Background sync failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Episode Completion
    
    private func handleEpisodeCompleted(_ item: QueueItem) {
        guard let podcastManager else { return }
        
        // Capture duration BEFORE any transition resets it (playEpisode resets currentDuration to 0)
        let totalDuration = item.durationSeconds ?? Int(audioManager.currentDuration)
        
        // Mark as played on server
        let action = EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: totalDuration,
            started: 0,
            total: totalDuration,
            device: deviceId
        )
        
        Task {
            await podcastManager.sendEpisodeAction(action)
        }
        
        // Mark as played locally — must happen synchronously before
        // handleItemChanged triggers sync, so the conflict detector sees
        // isPlayed = true and skips the episode.
        // Note: we do NOT call markEpisodeAsPlayed() because that sends
        // a duplicate EpisodeAction to the server. We only need the local flag.
        podcastManager.markEpisodePlayedLocally(podcastUrl: item.podcastUrl, episodeGuid: item.id)
        
        // Flush progress to disk — episode just completed, position must be persisted
        // before auto-advance loads the next episode and potentially resets state.
        podcastManager.flushProgressToDisk()
        
        // Tell the Pro server this episode is finished.
        // Bug 1 fix: Use syncCompletedEpisodeToProServer which takes the completed
        // item explicitly, instead of syncNowPlayingToProServer which reads
        // audioManager.currentItem (already changed by auto-advance).
        syncCompletedEpisodeToProServer(item)
        
        // Flush stats immediately on episode completion
        flushStatsIfAuthenticated()
    }

    // MARK: - Segment-Based Stats Tracking

    /// Opens a new listening segment at the current playback position.
    /// Call at the START of continuous playback: play(), seek(), episode change.
    private func beginSegment() {
        guard audioManager.currentItem != nil else { return }
        segmentStartPosition = currentPosition
        segmentStartWallTime = Date()
    }

    /// Closes the current segment and records it as a listen event in the stats buffer.
    /// Call at the END of continuous playback: pause(), seek(), skip, episode end.
    ///
    /// The recorded event captures:
    /// - `fromPosSec` / `toPosSec` — content position range
    /// - `contentSec` — absolute content distance covered (toPos - fromPos)
    /// - `durationSec` — wall-clock time elapsed
    /// - `speed` — playback rate at close time
    ///
    /// Sub-threshold events (< 1s content OR < 0.5s wall-clock) are silently
    /// dropped by `StatsEventBuffer.recordIfMeetsThreshold`.
    private func closeAndRecordSegment() {
        guard let item = audioManager.currentItem,
              let startPos = segmentStartPosition,
              let startWall = segmentStartWallTime else {
            return
        }

        let endPos = currentPosition
        let contentSec = abs(endPos - startPos)
        let durationSec = Date().timeIntervalSince(startWall)

        // Clear segment state immediately
        segmentStartPosition = nil
        segmentStartWallTime = nil

        let event = ProStatsEvent(
            podcastUrl: item.podcastUrl,
            episodeUrl: item.audioUrl,
            episodeGuid: item.id,
            eventType: .listen,
            fromPosSec: startPos,
            toPosSec: endPos,
            durationSec: durationSec,
            contentSec: contentSec,
            speed: Double(audioManager.playbackRate),
            deviceId: deviceId
        )
        Task { await statsBuffer.recordIfMeetsThreshold(event) }
    }

    // MARK: - Home Screen Widget Updates
    
    /// Push the current playback state and Up Next queue to the Home Screen widget.
    /// Called on play, pause, episode change, position tick, and stop.
    private func pushWidgetUpdate(reloadTimeline: Bool = true) {
        let item = audioManager.currentItem
        let queueItems = audioManager.queue
        
        if let item {
            LiveActivityService.shared.updateWidgetData(
                episodeTitle: item.title,
                podcastName: item.podcastTitle,
                artworkPath: nil,
                artworkUrl: item.artworkUrl,
                episodeId: item.id,
                isPlaying: audioManager.isPlaying,
                positionSeconds: Int(currentPosition),
                durationSeconds: item.durationSeconds ?? Int(currentDuration),
                upNextItems: queueItems.prefix(4).map { q in
                    (title: q.title, podcastTitle: q.podcastTitle, artworkPath: nil as String?, artworkUrl: q.artworkUrl, episodeId: q.id as String?)
                },
                reloadTimeline: reloadTimeline
            )
        } else {
            LiveActivityService.shared.clearWidgetData()
        }
    }



    // MARK: - Progress Tracking

    /// P0: Update local model with current playback position.
    /// Called frequently (every ~5s) to keep Episode.listenedSeconds and
    /// QueueItem.positionSeconds accurate for UI, queue restore, and watch sync.
    func updateLocalProgress() {
        // Guard: don't sync stale position data during episode transitions
        guard !audioManager.isInEpisodeTransition else { return }
        guard let podcastManager, let item = audioManager.currentItem else { return }
        let pos = Int(currentPosition)
        guard pos > 0 else { return }
        
        // Throttle local writes to every 5 seconds
        let now = Date()
        guard now.timeIntervalSince(lastLocalSaveTime) >= 5 else { return }
        lastLocalSaveTime = now
        
        // Update QueueItem.positionSeconds on the current item
        if var updated = audioManager.currentItem, updated.positionSeconds != pos {
            updated.positionSeconds = pos
            audioManager.currentItem = updated
        }
        
        // Update SwiftData Episode.listenedSeconds
        podcastManager.updateEpisodeProgress(
            podcastUrl: item.podcastUrl,
            episodeGuid: item.id,
            position: pos
        )
        
        pushWidgetUpdate(reloadTimeline: false)
    }
    
    /// P1: Sync playback position to server at the user-configured interval (10–60s, default 30s).
    /// Also updates local model via updateLocalProgress().
    func syncProgress() {
        // Guard: don't sync stale position data during episode transitions
        guard !audioManager.isInEpisodeTransition else { return }
        guard let podcastManager, let item = audioManager.currentItem else { return }
        
        // Always update local state first
        updateLocalProgress()
        
        // Server sync at configured interval
        let now = Date()
        let interval = settingsManager?.syncInterval ?? 60
        guard now.timeIntervalSince(lastSyncTime) >= TimeInterval(interval) else { return }
        lastSyncTime = now
        
        let action = EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: Int(currentPosition),
            started: 0,
            total: item.durationSeconds ?? Int(currentDuration),
            device: deviceId
        )
        
        Task {
            await podcastManager.sendEpisodeAction(action)
        }
    }
    
    /// Force-save current position to local model, bypassing all throttles.
    /// Call on pause and app backgrounding to ensure no position data is lost.
    ///
    /// **0xDEAD10CC fix:** This method intentionally does NOT push to the server.
    /// The previous fire-and-forget `Task { sendEpisodeAction() }` outlived the
    /// background task assertion in the app's background handler, allowing a
    /// `modelContext.save()` to hold a SQLite file lock during suspension.
    /// The episode action is queued in the `actionMap` and flushed to disk by
    /// `forcePersistActionMap()` (called immediately after this method).
    /// Server push happens on next foreground sync.
    func forceSyncProgress() {
        guard let item = audioManager.currentItem else { return }
        let pos = Int(currentPosition)
        guard pos > 0 else { return }
        
        // Cancel any pending seek debounce — we're about to flush the position
        // immediately, so the stale debounce task would be a duplicate.
        seekSyncTask?.cancel()
        seekSyncTask = nil
        
        // Force-update QueueItem.positionSeconds immediately (no throttle)
        if var updated = audioManager.currentItem, updated.positionSeconds != pos {
            updated.positionSeconds = pos
            audioManager.currentItem = updated
        }
        
        // Force-update SwiftData Episode.listenedSeconds (no throttle)
        podcastManager?.updateEpisodeProgress(
            podcastUrl: item.podcastUrl,
            episodeGuid: item.id,
            position: pos
        )
        // Flush dirty progress to disk immediately — bypasses the 60s throttle.
        // This is a critical save point: the app may be killed after backgrounding.
        podcastManager?.flushProgressToDisk()
        lastLocalSaveTime = Date()
        
        // Persist queue to disk immediately
        audioManager.persistQueueToDisk()
        
        // Queue the episode action for deferred server push (no Task spawned).
        // The actionMap is persisted by forcePersistActionMap() in the background
        // handler and pushed on the next foreground sync cycle.
        podcastManager?.queueEpisodeAction(EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: pos,
            started: 0,
            total: item.durationSeconds ?? Int(currentDuration),
            device: deviceId
        ))
    }
    
    // MARK: - Seek Sync (P0-3)
    
    private static let seekSyncDebounceInterval: TimeInterval = 1.5
    private var seekSyncTask: Task<Void, Never>?
    
    /// Seek and schedule a debounced server sync.
    /// Debounce (1.5s) prevents spam during scrubbing — only the final position syncs.
    func seekAndSync(to positionSeconds: Int) {
        let position = TimeInterval(positionSeconds)
        audioManager.seek(to: position)
        
        // Cancel any pending debounce — restart timer from the latest seek
        seekSyncTask?.cancel()
        seekSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.seekSyncDebounceInterval))
            guard !Task.isCancelled, let self else { return }
            
            guard let item = self.audioManager.currentItem,
                  let podcastManager = self.podcastManager else { return }
            
            let action = EpisodeAction(
                podcast: item.podcastUrl,
                episode: item.audioUrl,
                guid: item.id,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: positionSeconds,
                started: 0,
                total: item.durationSeconds ?? Int(self.currentDuration),
                device: self.deviceId
            )
            
            await podcastManager.sendEpisodeAction(action)
        }
    }
    
    // MARK: - Play Latest Episode (Siri / Watch)
    
    /// Finds a podcast by name and plays its most recent episode.
    func playLatest(podcastName: String) {
        guard let podcastManager else { return }
        
        let match = podcastManager.subscriptions.first {
            $0.title.localizedCaseInsensitiveContains(podcastName)
        }
        
        guard let podcast = match else {
            logger.warning("playLatest: no podcast matching '\(podcastName)'")
            return
        }
        
        let sorted = podcast.episodes.sorted(by: episodesByFeedOrder)
        guard let latest = sorted.first else {
            logger.warning("playLatest: no episodes for '\(podcast.title)'")
            return
        }
        
        logger.info("playLatest: playing '\(latest.title)' from '\(podcast.title)'")
        playEpisode(latest)
    }
    
    // MARK: - Update Progress (Watch sync)
    
    /// Applies a position update from the watch for a specific episode.
    func updateProgress(episodeId: String, position: Int) {
        // (1) Always persist — forward-only so a stale/behind watch value never rewinds.
        //     This is what makes Watch→iPhone resume work even when the episode isn't loaded.
        podcastManager?.updateEpisodeProgressByGuid(episodeGuid: episodeId, position: position, forwardOnly: true)

        // (2) Live-seek only when this episode is the loaded one and the watch is ahead.
        guard let item = audioManager.currentItem, item.id == episodeId else { return }
        if position > Int(currentPosition) + 5 {
            audioManager.seek(to: TimeInterval(position))
        }
    }
    
    // MARK: - Pro Queue Sync
    
    /// Full bidirectional queue sync: pull → merge → push → adopt.
    /// This is the correct cross-device sync flow.
    /// Returns any position conflicts for the `.ask` strategy.
    /// No-op for gPodder clients or Vault mode.
    @discardableResult
    func syncQueueWithServer(attempt: Int = 0) async -> [SyncConflict] {
        guard let syncClient, await syncClient.supportsQueueSync else { return [] }
        
        // Cancel any in-flight debounced push — we're about to do a full sync.
        // This prevents racing pushes where the debounced push and the sync's
        // Step 3 PUSH both call syncQueue() concurrently.
        queuePushTask?.cancel()
        queuePushTask = nil
        isSyncingQueue = true
        defer { isSyncingQueue = false }
        
        let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
        var conflicts: [SyncConflict] = []
        
        // Track in-flight additions — items added to the queue during async
        // suspension points (network calls) that aren't in the server response.
        var inFlightAdds: [QueueItem] = []
        
        do {
            // Step 1: PULL — get the server's current queue + version
            let pullResult = try await syncClient.getQueueWithVersion()
            let serverItems = pullResult.items
            lastKnownQueueVersion = pullResult.version
            logger.info("Queue sync: pulled \(serverItems.count) items from server (version=\(pullResult.version.map(String.init) ?? "nil"))")
            for (i, si) in serverItems.enumerated() {
                logger.info("  PULL[\(i)]: \(si.title ?? "nil") guid=\(si.episodeGuid ?? "nil") url=\(si.episodeUrl.prefix(60))")
            }
            
            // Step 2: MERGE — local items first, append server-new items
            let currentId = audioManager.currentItem?.id
            let localItems = audioManager.queue
            
            // Bug 3 fix: Fresh device detection.
            // If local queue is empty AND no currentItem, this is a new device.
            // Adopt the server queue wholesale — don't merge or push back.
            // This prevents auto-queued episodes (from processNewEpisodes) from
            // flooding the server with 1,400+ items.
            let isFreshDevice = localItems.isEmpty && currentId == nil
            if isFreshDevice && !serverItems.isEmpty {
                let sorted = serverItems.sorted { $0.sortOrder < $1.sortOrder }
                logger.info("Queue sync: fresh device detected — adopting \(sorted.count) items from server")

                // Sync contract: the queue is Up Next ONLY. Restore the
                // now-playing episode from the authoritative playback channel
                // (/playback/current) — NEVER from the queue. A sortOrder-0 item is a
                // valid Up Next position (web "add to top of queue" inserts there via
                // the server's AddToQueue/addToTop), so it must not be mistaken for
                // the now-playing episode. Restoring here also preserves cross-device
                // handoff on a fresh device that is not coming through login.
                await restoreNowPlayingFromProServer()
                let nowPlayingId = audioManager.currentItem?.id

                // Adopt every server item as Up Next, minus (a) the now-playing
                // episode if a (legacy) client also left it in the queue, and
                // (b) episodes already played locally — a played episode does not
                // belong in Up Next (mirrors the non-fresh adopt's played filter).
                let localEpisodesForFresh = buildLocalEpisodeLookup(for: sorted)
                let queueItems: [QueueItem] = sorted.compactMap { syncItem in
                    let item = buildQueueItemFromSyncItem(syncItem)
                    if let nowPlayingId, item.id == nowPlayingId { return nil }
                    if let localEp = localEpisodesForFresh[item.id], localEp.isPlayed {
                        logger.info("Queue sync: fresh adopt skipping played episode: \(item.title)")
                        return nil
                    }
                    return item
                }
                audioManager.replaceQueue(queueItems)
                logger.info("Queue sync: fresh device adopted \(queueItems.count) Up Next items")

                return conflicts
            }
            
            // Build a map of server items by guid for position lookup
            var serverPositionMap: [String: Double] = [:]
            var serverMetadataMap: [String: QueueSyncItem] = [:]
            for item in serverItems {
                let guid = item.episodeGuid ?? item.episodeUrl
                if let pos = item.positionSec {
                    serverPositionMap[guid] = pos
                }
                serverMetadataMap[guid] = item
            }
            
            // Build a set of local episode identifiers for dedup
            var localIds = Set<String>()
            for item in localItems {
                localIds.insert(item.id)
            }
            if let currentId {
                localIds.insert(currentId)
            }
            
            // Step 1.5: GUID-aware pruning
            // Only prune items that were in the PREVIOUS sync's server response
            // but are now absent — they were removed/completed on another device.
            // Items the server has never seen (locally added since last sync)
            // are preserved until the push in Step 3 uploads them.
            //
            // Bug fix: The old logic pruned ALL items not on the current server
            // response, which killed locally-added items before their push landed.
            let serverGuids = Set(serverItems.map { $0.episodeGuid ?? $0.episodeUrl })
            let hasCompletedQueueSync = UserDefaults.standard.bool(forKey: "proQueueSyncCompleted")
            let previousServerGuids = Set(UserDefaults.standard.stringArray(forKey: Self.proQueueSyncServerGuidsKey) ?? [])
            
            var prunedLocalItems = localItems
            if hasCompletedQueueSync && !isFreshDevice && !previousServerGuids.isEmpty {
                // "Stale" = was on the server last time, but is NOT on the server now.
                // These were removed/completed on another device.
                let removedFromServer = previousServerGuids.subtracting(serverGuids)
                let staleItems = localItems.filter { removedFromServer.contains($0.id) }
                if !staleItems.isEmpty {
                    prunedLocalItems = localItems.filter { !removedFromServer.contains($0.id) }
                    logger.info("Queue sync: pruned \(staleItems.count) stale local items (removed from server since last sync)")
                    audioManager.replaceQueue(prunedLocalItems)
                    
                    // Update localIds after pruning
                    localIds = Set(prunedLocalItems.map(\.id))
                    if let currentId {
                        localIds.insert(currentId)
                    }
                }
            }
            
            // Step 2a: Reconcile positions for SHARED items (exist in both local and server)
            // Track conflicted items' server positions for the push step
            var conflictedServerPositions: [String: Double] = [:]
            var reconciledQueue: [QueueItem] = []
            for item in prunedLocalItems {
                let serverPos = serverPositionMap[item.id]
                let localPos = item.positionSeconds
                
                var resolvedPosition = localPos
                
                if let serverPosition = serverPos {
                    let serverPosInt = Int(serverPosition)
                    
                    switch strategy {
                    case .serverWins:
                        // Always adopt server position
                        resolvedPosition = serverPosInt
                    case .deviceWins:
                        // Keep local position (already set)
                        break
                    case .ask:
                        // If both have non-zero positions that differ, generate a conflict
                        if localPos > 0 && serverPosInt > 0 && abs(localPos - serverPosInt) > SyncThresholds.reconcilePositionGapSeconds {
                            let serverItem = serverMetadataMap[item.id]
                            conflicts.append(SyncConflict(
                                episodeGuid: item.id,
                                episodeTitle: item.title,
                                podcastTitle: item.podcastTitle,
                                podcastUrl: item.podcastUrl,
                                artworkUrl: item.artworkUrl,
                                audioUrl: item.audioUrl,
                                localPosition: localPos,
                                serverPosition: serverPosInt,
                                serverTimestamp: 0,
                                totalDuration: item.durationSeconds ?? serverItem?.durationSec.map { Int($0) },
                                occurrenceCount: 1
                            ))
                            // Track server position so the push preserves it
                            conflictedServerPositions[item.id] = serverPosition
                            // Keep local position for now — conflict wizard will resolve
                        } else if localPos == 0 {
                            // Never played locally — silently adopt server
                            resolvedPosition = serverPosInt
                        }
                        // If server is 0, keep local
                    }
                }
                
                // Create updated item with reconciled position
                if resolvedPosition != localPos {
                    reconciledQueue.append(QueueItem(
                        id: item.id,
                        title: item.title,
                        podcastTitle: item.podcastTitle,
                        audioUrl: item.audioUrl,
                        artworkUrl: item.artworkUrl,
                        durationSeconds: item.durationSeconds,
                        positionSeconds: resolvedPosition,
                        podcastUrl: item.podcastUrl,
                        pubDate: item.pubDate,
                        podcastAuthor: item.podcastAuthor,
                        episodeDescription: item.episodeDescription
                    ))
                } else {
                    reconciledQueue.append(item)
                }
            }
            
            // Reconcile order: The server's order is the canonical source of truth for items that exist on both.
            var serverSortMap: [String: Int] = [:]
            for (index, item) in serverItems.enumerated() {
                let guid = item.episodeGuid ?? item.episodeUrl
                serverSortMap[guid] = index
            }
            
            reconciledQueue.sort { a, b in
                let aOrder = serverSortMap[a.id] ?? Int.max
                let bOrder = serverSortMap[b.id] ?? Int.max
                if aOrder == bOrder {
                    // Fall back to existing local order if both were added offline and lack a server sortOrder
                    let aLocal = prunedLocalItems.firstIndex(where: { $0.id == a.id }) ?? Int.max
                    let bLocal = prunedLocalItems.firstIndex(where: { $0.id == b.id }) ?? Int.max
                    return aLocal < bLocal
                }
                return aOrder < bOrder
            }
            
            // Replace local queue with reconciled positions
            audioManager.replaceQueue(reconciledQueue)
            logger.info("Queue sync: reconciledQueue has \(reconciledQueue.count) items")
            for (i, ri) in reconciledQueue.enumerated() {
                logger.info("  RECONCILED[\(i)]: \(ri.title) id=\(ri.id.prefix(40))")
            }
            
            // Step 2b: Find server items NOT already in local queue and append
            let newFromServer = serverItems
                .filter { item in
                    let guid = item.episodeGuid ?? item.episodeUrl
                    return !localIds.contains(guid) && guid != currentId
                }
                .sorted { $0.sortOrder < $1.sortOrder }
            
            // Build a lookup of local episodes for metadata enrichment
            let localEpisodes = buildLocalEpisodeLookup(for: newFromServer)
            
            // Convert server-new items to QueueItems and append to local queue
            // Filter out episodes that are marked as played locally — they were
            // removed from the queue on this device and should not be re-added.
            let newQueueItems: [QueueItem] = newFromServer.compactMap { syncItem in
                let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
                
                // Skip episodes that are already played locally
                if let local = localEpisodes[guid], local.isPlayed {
                    logger.info("Queue sync: skipping played episode from server: \(syncItem.title ?? guid)")
                    return nil
                }
                
                let serverPos = Int(syncItem.positionSec ?? 0)
                
                // Try local episode first (has richest metadata)
                if let local = localEpisodes[guid] {
                    return QueueItem(
                        id: guid,
                        title: local.title,
                        podcastTitle: local.podcast?.title ?? syncItem.podcastTitle ?? "",
                        audioUrl: local.audioUrl ?? syncItem.episodeUrl,
                        artworkUrl: local.imageUrl ?? local.podcast?.logoUrl ?? syncItem.artworkUrl,
                        durationSeconds: local.durationSeconds ?? syncItem.durationSec.map { Int($0) },
                        positionSeconds: serverPos,
                        podcastUrl: syncItem.podcastUrl,
                        pubDate: local.pubDate,
                        podcastAuthor: local.podcast?.author,
                        episodeDescription: local.episodeDescription
                    )
                }
                
                // Fall back to server-provided metadata
                return QueueItem(
                    id: guid,
                    title: syncItem.title ?? "Unknown Episode",
                    podcastTitle: syncItem.podcastTitle ?? "",
                    audioUrl: syncItem.episodeUrl,
                    artworkUrl: syncItem.artworkUrl,
                    durationSeconds: syncItem.durationSec.map { Int($0) },
                    positionSeconds: serverPos,
                    podcastUrl: syncItem.podcastUrl,
                    pubDate: nil
                )
            }
            
            // Append new items to local queue
            if !newQueueItems.isEmpty {
                audioManager.appendToQueue(newQueueItems)
                logger.info("Queue sync: merged \(newQueueItems.count) new items from server")
            }
            
            // Step 3: PUSH — send the merged Up Next queue to server.
            // Sync contract: the now-playing item is NOT part of the
            // queue — it syncs via the playback channel (playback_states.now_playing).
            // Push Up Next only, 1-based; sortOrder 0 is reserved for legacy leaks.
            var syncItems: [QueueSyncItem] = []

            let pushQueueCount = audioManager.queue.count
            let pushCurrentTitle = audioManager.currentItem?.title ?? "nil"
            logger.info("Queue sync PUSH: audioManager.queue has \(pushQueueCount) items, currentItem=\(pushCurrentTitle)")
            for (index, item) in audioManager.queue.enumerated() {
                // For conflicted items, push the SERVER position to preserve
                // server state until the user resolves the conflict
                let pushPosition = conflictedServerPositions[item.id] ?? Double(item.positionSeconds)
                syncItems.append(QueueSyncItem(
                    podcastUrl: item.podcastUrl,
                    episodeUrl: item.audioUrl,
                    episodeGuid: item.id,
                    sortOrder: index + 1,
                    positionSec: pushPosition,
                    title: item.title,
                    podcastTitle: item.podcastTitle,
                    artworkUrl: item.artworkUrl,
                    durationSec: item.durationSeconds.map { Double($0) }
                ))
            }
            logger.info("Queue sync PUSH: built \(syncItems.count) syncItems (before dedup)")
            for (i, si) in syncItems.enumerated() {
                logger.info("  PUSH[\(i)]: \(si.title ?? "nil") guid=\(si.episodeGuid ?? "nil") sortOrder=\(si.sortOrder) url=\(si.episodeUrl)")
            }
            
            // Deduplicate by episodeUrl
            var seenUrls = Set<String>()
            let deduped = syncItems.filter { seenUrls.insert($0.episodeUrl).inserted }
            
            // API spec: the server caps at 200 items — truncate locally
            // to avoid server-side silent truncation and sync loops.
            let truncated = Array(deduped.prefix(Self.maxQueueSyncItems))
            if deduped.count > Self.maxQueueSyncItems {
                logger.warning("Queue sync: truncated \(deduped.count) → \(truncated.count) items (API limit)")
            }
            
            // Snapshot the queue BEFORE the push await — any items added to the
            // queue during this await are "in-flight" and will be lost when
            // Step 4 ADOPT replaces the queue with the server response.
            let prePushQueueIds = Set(audioManager.queue.map(\.id))
            
            // Send the base version for CAS. On the final allowed
            // attempt force baseVersion=nil (unconditional) so the retry can't loop.
            let pushBaseVersion = attempt < Self.maxQueueSyncRetries ? lastKnownQueueVersion : nil
            logger.info("Queue sync: pushing \(truncated.count) items to server (deduped from \(syncItems.count), baseVersion=\(pushBaseVersion.map(String.init) ?? "nil"), attempt=\(attempt))")
            let syncResult = try await syncClient.syncQueue(items: truncated, baseVersion: pushBaseVersion)
            if let v = syncResult.version { lastKnownQueueVersion = v }
            let responseItems = syncResult.items
            let droppedItemsFromServer = syncResult.droppedItems
            logger.info("Queue sync: pushed \(truncated.count) items, got \(responseItems.count) back (explicitly dropped \(droppedItemsFromServer.count))")
            for (i, ri) in responseItems.enumerated() {
                logger.info("  RESPONSE[\(i)]: \(ri.title ?? "nil") guid=\(ri.episodeGuid ?? "nil") sortOrder=\(ri.sortOrder)")
            }
            
            // Detect items added locally while the push was in flight.
            // These items are NOT in the server response (the server only knows
            // about what was pushed). We must preserve them after adopt.
            let currentQueueAfterPush = audioManager.queue
            inFlightAdds = currentQueueAfterPush.filter { !prePushQueueIds.contains($0.id) }
            if !inFlightAdds.isEmpty {
                logger.info("Queue sync: detected \(inFlightAdds.count) items added during push — will preserve")
            }
            
            // Step 4: ADOPT — use the server's response as the final queue
            // Trust the server response array order as canonical — do NOT re-sort
            // by sortOrder integers (which may be stale or broken on the server).
            
            var seenAdoptedIds = Set<String>()
            let responseFiltered = responseItems
                .filter { ($0.episodeGuid ?? $0.episodeUrl) != currentId }
                .filter { item in
                    let guid = item.episodeGuid ?? item.episodeUrl
                    if seenAdoptedIds.contains(guid) { return false }
                    seenAdoptedIds.insert(guid)
                    return true
                }
            
            let localEpisodesForResponse = buildLocalEpisodeLookup(for: responseFiltered)
            
            // Build a set of GUIDs we explicitly pushed so we can trust them in ADOPT
            let adoptPushedGuids = Set(truncated.map { $0.episodeGuid ?? $0.episodeUrl })
            
            let finalQueue: [QueueItem] = responseFiltered.compactMap { syncItem in
                let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
                
                // Only filter played episodes that we did NOT push. If we pushed it,
                // the user intentionally has it in their queue (e.g., they marked it
                // as unplayed and re-added it). The episode action sync may have
                // re-marked it as played from stale server data — don't trust that.
                if !adoptPushedGuids.contains(guid),
                   let localEp = localEpisodesForResponse[guid], localEp.isPlayed {
                    logger.info("Queue sync adopt: skipping played episode (not in push): \(syncItem.title ?? guid)")
                    return nil
                }
                
                // Use the reconciled local queue for position lookup
                let localItem = audioManager.queue.first { $0.id == guid }
                let serverPos = Int(syncItem.positionSec ?? 0)
                let resolvedPosition: Int
                
                switch strategy {
                case .serverWins:
                    resolvedPosition = serverPos
                case .deviceWins:
                    if let localPos = localItem?.positionSeconds, localPos > 0 {
                        resolvedPosition = localPos
                    } else {
                        resolvedPosition = serverPos
                    }
                case .ask:
                    // For .ask, use the already-reconciled local position (from Step 2a)
                    // The conflict wizard will update later if the user chooses server
                    if let localPos = localItem?.positionSeconds, localPos > 0 {
                        resolvedPosition = localPos
                    } else {
                        resolvedPosition = serverPos
                    }
                }
                
                if let local = localEpisodesForResponse[guid] {
                    return QueueItem(
                        id: guid,
                        title: local.title,
                        podcastTitle: local.podcast?.title ?? syncItem.podcastTitle ?? "",
                        audioUrl: local.audioUrl ?? syncItem.episodeUrl,
                        artworkUrl: local.imageUrl ?? local.podcast?.logoUrl ?? syncItem.artworkUrl,
                        durationSeconds: local.durationSeconds ?? syncItem.durationSec.map { Int($0) },
                        positionSeconds: resolvedPosition,
                        podcastUrl: syncItem.podcastUrl,
                        pubDate: local.pubDate,
                        podcastAuthor: local.podcast?.author,
                        episodeDescription: local.episodeDescription
                    )
                }
                
                return QueueItem(
                    id: guid,
                    title: syncItem.title ?? localItem?.title ?? "Unknown Episode",
                    podcastTitle: syncItem.podcastTitle ?? localItem?.podcastTitle ?? "",
                    audioUrl: syncItem.episodeUrl,
                    artworkUrl: syncItem.artworkUrl ?? localItem?.artworkUrl,
                    durationSeconds: syncItem.durationSec.map { Int($0) } ?? localItem?.durationSeconds,
                    positionSeconds: resolvedPosition,
                    podcastUrl: syncItem.podcastUrl,
                    pubDate: localItem?.pubDate
                )
            }
            
            logger.info("Queue sync ADOPT: finalQueue has \(finalQueue.count) items (from \(responseFiltered.count) responseFiltered)")
            for (i, fq) in finalQueue.enumerated() {
                logger.info("  ADOPT[\(i)]: \(fq.title) id=\(fq.id.prefix(40))")
            }
            audioManager.replaceQueue(finalQueue)
            logger.info("Queue sync: adopted \(finalQueue.count) items from server response")
            
            // Re-append items that were added locally during the push await.
            // These were never part of the push payload, so they aren't in the
            // server response. They'll be pushed on the next debounced push.
            if !inFlightAdds.isEmpty {
                let adoptedIds = Set(finalQueue.map(\.id))
                let stillMissing = inFlightAdds.filter { !adoptedIds.contains($0.id) }
                if !stillMissing.isEmpty {
                    audioManager.appendToQueue(stillMissing)
                    logger.info("Queue sync: re-appended \(stillMissing.count) in-flight items after adopt")
                }
            }
            
            // Process items explicitly dropped by the server
            for dropped in droppedItemsFromServer {
                if dropped.reason == "web_deleted" {
                    logger.info("Queue sync: item deleted via web, dropping locally: \(dropped.title ?? "")")
                } else if dropped.reason == "capped" {
                    logger.warning("Queue sync: server capped queue at 200 items, dropping locally: \(dropped.title ?? "")")
                } else {
                    logger.info("Queue sync: server dropped item (\(dropped.reason)), dropping locally: \(dropped.title ?? "")")
                }
            }
            
            // Detect items we PUSHED but the server did NOT return AND did not report as explicitly dropped.
            // This happens when the server silently drops items (e.g., unique
            // constraint violation, INSERT failure, or server-side bug).
            // Preserve the local queue items so they aren't lost — the next
            // debounced push will retry sending them to the server.
            let pushedGuids = Set(truncated.compactMap(\.episodeGuid))
            let pushedUrls = Set(truncated.map(\.episodeUrl))
            let explicitDroppedGuids = Set(droppedItemsFromServer.compactMap(\.guid))
            let explicitDroppedUrls = Set(droppedItemsFromServer.map(\.episodeUrl))
            
            let serverReturnedIds = Set(serverItems.compactMap(\.episodeGuid))
            let serverReturnedUrls = Set(serverItems.map(\.episodeUrl))
            
            let silentlyDroppedItems = currentQueueAfterPush.filter { item in
                let wasPushed = pushedGuids.contains(item.id) || pushedUrls.contains(item.audioUrl)
                if !wasPushed { return false }
                
                // If the server returned it, it wasn't SILENTLY dropped by the server.
                // We might have chosen not to adopt it locally (e.g. because it is played),
                // but the server did its job.
                let returnedByServer = serverReturnedIds.contains(item.id) || serverReturnedUrls.contains(item.audioUrl)
                if returnedByServer { return false }
                
                let explicitlyDropped = explicitDroppedGuids.contains(item.id) || explicitDroppedUrls.contains(item.audioUrl)
                if explicitlyDropped { return false }
                
                return item.id != currentId  // Don't re-add current item
            }
            
            if !silentlyDroppedItems.isEmpty {
                audioManager.appendToQueue(silentlyDroppedItems)
                logger.warning("Queue sync: SERVER SILENTLY DROPPED \(silentlyDroppedItems.count) items — preserved locally: \(silentlyDroppedItems.map(\.title).joined(separator: ", "))")
            }
            
            // Mark that a queue sync has completed — enables stale item pruning
            // on subsequent syncs (Step 1.5). Without this flag, the first sync
            // on a new device would incorrectly prune legitimately queued episodes.
            UserDefaults.standard.set(true, forKey: "proQueueSyncCompleted")
            
            // Persist what the SERVER acknowledged holding — and nothing else.
            //
            // This set is read back as "the server had these last time", and an
            // id in it that is absent from the next response is pruned as
            // removed-on-another-device. Membership is therefore a liability,
            // never a protection: adding an id here can only expose it to
            // pruning. Two ids used to be appended in the name of protecting
            // them, and both were guaranteed to be absent next time —
            //
            //  - the now-playing episode, which is deliberately never pushed to
            //    the queue (Up Next only, owned by the playback channel). It
            //    survived while it played — the prune only looks at queue items
            //    — and was deleted the instant `preserveCurrent` returned it to
            //    Up Next behind a newly tapped episode;
            //  - items the server silently dropped, which are re-added locally
            //    precisely because the server does not have them, so they were
            //    pruned before the retry push could land.
            //
            // `finalQueue` is built from the server's own response, so it is the
            // honest answer to "what does the server hold".
            let allServerGuids = finalQueue.map(\.id)
            UserDefaults.standard.set(allServerGuids, forKey: Self.proQueueSyncServerGuidsKey)
            
        } catch let proError as YourPodsProError where proError == .conflict {
            // Another device wrote the queue between our PULL and PUSH.
            // Re-pull (fresh version) → re-MERGE current local intent → re-PUSH.
            // Bounded: the final attempt pushed with baseVersion=nil, so this branch
            // can only fire while attempt < maxQueueSyncRetries.
            logger.info("Queue sync: 409 version conflict (attempt \(attempt)) — re-pulling and retrying")
            return await syncQueueWithServer(attempt: attempt + 1)
        } catch {
            logger.error("Queue sync failed: \(error.localizedDescription)")
        }

        // If items were added during sync, trigger a debounced push so they
        // reach the server on the next cycle. isSyncingQueue is still true
        // here (cleared by defer), so we schedule via Task to let defer run first.
        if !inFlightAdds.isEmpty {
            Task { [weak self] in
                self?.pushQueueToProServerDebounced()
            }
        }
        
        return conflicts
    }
    
    /// Maximum number of queue items to sync with the server.
    /// API spec: the server silently truncates at 200.
    static let maxQueueSyncItems = 200
    
    /// UserDefaults key storing the GUIDs from the last successful server sync.
    /// Used by Step 1.5 pruning to distinguish "server-removed" items (should prune)
    /// from "locally-added, not yet pushed" items (should preserve).
    /// Versioned because every installed device already holds a snapshot
    /// written by the old rule — one that names the now-playing episode and any
    /// server-dropped items as things "the server had". Reading that back once
    /// more would spend the upgrade on exactly the deletion this fix exists to
    /// prevent. A key it has never seen reads as empty, which the prune treats
    /// as "no history yet" and skips, so the baseline is rebuilt from the next
    /// server response instead of inherited poisoned.
    static let proQueueSyncServerGuidsKey = "proQueueSyncServerGuidsV2"

    /// Server's last-known queue version for optimistic concurrency.
    /// Captured on every PULL and successful PUSH and sent as `baseVersion` on the
    /// next push. Persisted (survives relaunch) so the debounced push — which does
    /// not PULL first — still carries a token. A stale persisted value just yields
    /// one 409 + re-pull, so correctness doesn't depend on persistence.
    private static let queueVersionKey = "proQueueVersion"
    private var lastKnownQueueVersion: Int64? {
        get { (UserDefaults.standard.object(forKey: Self.queueVersionKey) as? NSNumber)?.int64Value }
        set {
            if let newValue { UserDefaults.standard.set(NSNumber(value: newValue), forKey: Self.queueVersionKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.queueVersionKey) }
        }
    }

    /// Max CAS retries on a 409 before falling back to an unconditional push
    /// (last-write-wins). Bounded like the audio-retry hard rule.
    private static let maxQueueSyncRetries = 3

    /// Debounce work item for queue push — prevents spamming the server
    /// when the user rapidly reorders or adds/removes queue items.
    private static let queuePushDebounceInterval: TimeInterval = 2.0
    private var queuePushTask: Task<Void, Never>?
    
    /// Push the full queue (currentItem + upcoming) to the Pro server.
    /// No-op for gPodder clients or Vault mode.
    func pushQueueToProServer() async {
        guard let syncClient, await syncClient.supportsQueueSync else { return }
        
        // Build the sync payload: Up Next ONLY (sortOrder 1, 2, ...).
        // Sync contract: the queue carries Up Next only — the now-playing
        // episode is owned by the playback channel (playback_states.now_playing /
        // /playback/current) and is NEVER injected into the queue. sortOrder is
        // 1-based; sortOrder 0 is reserved for legacy now-playing leaks that
        // clients must keep out of Up Next.
        var syncItems: [QueueSyncItem] = []

        for (index, item) in audioManager.queue.enumerated() {
            syncItems.append(QueueSyncItem(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                sortOrder: index + 1,
                positionSec: Double(item.positionSeconds),
                title: item.title,
                podcastTitle: item.podcastTitle,
                artworkUrl: item.artworkUrl,
                durationSec: item.durationSeconds.map { Double($0) }
            ))
        }

        // Deduplicate by episodeUrl — server warned about duplicate entries.
        var seenUrls = Set<String>()
        let deduped = syncItems.filter { seenUrls.insert($0.episodeUrl).inserted }
        
        // API spec: the server caps at 200 items — truncate locally.
        let truncated = Array(deduped.prefix(Self.maxQueueSyncItems))
        if deduped.count > Self.maxQueueSyncItems {
            logger.warning("pushQueue: truncated \(deduped.count) → \(truncated.count) items (API limit)")
        }
        
        do {
            let standaloneQueueCount = audioManager.queue.count
            let standaloneCurrentTitle = audioManager.currentItem?.title ?? "nil"
            logger.info("pushQueueToProServer: pushing \(truncated.count) items (queue=\(standaloneQueueCount), currentItem=\(standaloneCurrentTitle))")
            for (i, si) in truncated.enumerated() {
                logger.info("  STANDALONE_PUSH[\(i)]: \(si.title ?? "nil") guid=\(si.episodeGuid ?? "nil") sortOrder=\(si.sortOrder)")
            }
            let result = try await syncClient.syncQueue(items: truncated, baseVersion: lastKnownQueueVersion)
            if let v = result.version { lastKnownQueueVersion = v }
            logger.info("Pushed \(truncated.count) queue items to Pro server")
        } catch let proError as YourPodsProError where proError == .conflict {
            // The debounced push raced another device's write. Fall
            // back to a full sync (PULL → re-MERGE → PUSH with a fresh base version).
            logger.info("pushQueue: 409 version conflict — running a full re-sync")
            await syncQueueWithServer()
        } catch {
            logger.error("Failed to push queue to Pro server: \(error.localizedDescription)")
        }
    }
    
    /// Push queue to Pro server with debouncing — call this from rapid-fire
    /// queue mutation callbacks (e.g., `onQueueChanged`).
    func pushQueueToProServerDebounced() {
        // Suppress debounced pushes while a full sync is running.
        // The sync's Step 3 PUSH handles the server update; concurrent
        // debounced pushes would race with it and could overwrite state.
        guard !isSyncingQueue else {
            logger.info("pushQueueToProServerDebounced: SUPPRESSED (isSyncingQueue=true)")
            return
        }
        logger.info("pushQueueToProServerDebounced: scheduling push in \(Self.queuePushDebounceInterval)s")
        
        queuePushTask?.cancel()
        queuePushTask = Task {
            try? await Task.sleep(for: .seconds(Self.queuePushDebounceInterval))
            guard !Task.isCancelled else { return }
            await pushQueueToProServer()
        }
    }
    
    /// Pull the server queue and REPLACE the local queue with it.
    /// After push-then-pull, the server is the source of truth.
    /// The currently-playing episode is preserved (not replaced from queue).
    /// No-op for gPodder clients or Vault mode.
    func pullQueueFromProServer() async {
        guard let syncClient, await syncClient.supportsQueueSync else { return }
        
        do {
            let serverItems = try await syncClient.getQueue()
            logger.info("Pulled \(serverItems.count) queue items from Pro server")
            
            // Filter out the currently-playing episode (don't re-add it to queue)
            let currentId = audioManager.currentItem?.id
            let filteredItems = serverItems
                .filter { $0.episodeGuid != currentId }
                .sorted { $0.sortOrder < $1.sortOrder }
            
            // Build a lookup of local episodes by guid for metadata enrichment
            let localEpisodes = buildLocalEpisodeLookup(for: filteredItems)
            
            // Respect the user's conflict strategy for position resolution
            let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
            
            // Build the complete replacement queue from server items
            let replacementQueue: [QueueItem] = filteredItems.compactMap { syncItem in
                let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
                
                // Determine position: server vs local
                let localItem = audioManager.queue.first { $0.id == guid }
                let serverPos = Int(syncItem.positionSec ?? 0)
                let resolvedPosition: Int
                
                switch strategy {
                case .serverWins:
                    resolvedPosition = serverPos
                case .deviceWins, .ask:
                    // Prefer local position if the item exists locally and has been played
                    if let localPos = localItem?.positionSeconds, localPos > 0 {
                        resolvedPosition = localPos
                    } else {
                        resolvedPosition = serverPos
                    }
                }
                
                // Try local episode first (has the richest metadata)
                if let local = localEpisodes[guid] {
                    return QueueItem(
                        id: guid,
                        title: local.title,
                        podcastTitle: local.podcast?.title ?? syncItem.podcastTitle ?? "",
                        audioUrl: local.audioUrl ?? syncItem.episodeUrl,
                        artworkUrl: local.imageUrl ?? local.podcast?.logoUrl ?? syncItem.artworkUrl,
                        durationSeconds: local.durationSeconds ?? syncItem.durationSec.map { Int($0) },
                        positionSeconds: resolvedPosition,
                        podcastUrl: syncItem.podcastUrl,
                        pubDate: local.pubDate,
                        podcastAuthor: local.podcast?.author,
                        episodeDescription: local.episodeDescription
                    )
                }
                
                // Fall back to server-provided metadata
                return QueueItem(
                    id: guid,
                    title: syncItem.title ?? "Unknown Episode",
                    podcastTitle: syncItem.podcastTitle ?? "",
                    audioUrl: syncItem.episodeUrl,
                    artworkUrl: syncItem.artworkUrl,
                    durationSeconds: syncItem.durationSec.map { Int($0) },
                    positionSeconds: resolvedPosition,
                    podcastUrl: syncItem.podcastUrl,
                    pubDate: nil
                )
            }
            
            // Full replacement: clear local queue and set server state as canonical
            audioManager.replaceQueue(replacementQueue)
            
            logger.info("Replaced queue with \(replacementQueue.count) items from server")
        } catch {
            logger.error("Failed to pull queue from Pro server: \(error.localizedDescription)")
        }
    }
    
    /// Build a lookup dictionary of local episodes by GUID and audioUrl for the given sync items.
    /// Uses PodcastManager's subscription data to find matching episodes.
    /// Indexes by both GUID and audioUrl so server items using either identifier can match.
    private func buildLocalEpisodeLookup(for syncItems: [QueueSyncItem]) -> [String: Episode] {
        guard let podcastManager else { return [:] }
        
        var lookup: [String: Episode] = [:]
        let guidSet = Set(syncItems.compactMap { $0.episodeGuid })
        let urlSet = Set(syncItems.map(\.episodeUrl))
        
        for podcast in podcastManager.subscriptions {
            for episode in podcast.episodes {
                if guidSet.contains(episode.guid) {
                    lookup[episode.guid] = episode
                }
                // Also index by audioUrl for lookups when episodeGuid is nil
                if let audioUrl = episode.audioUrl, urlSet.contains(audioUrl) {
                    lookup[audioUrl] = episode
                }
            }
        }
        return lookup
    }

    /// Convert a server `QueueSyncItem` into a local `QueueItem`.
    /// Used by the fresh-device adoption path to build the queue from server data.
    private func buildQueueItemFromSyncItem(_ syncItem: QueueSyncItem) -> QueueItem {
        let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
        var item = QueueItem(
            id: guid,
            title: syncItem.title ?? "Unknown Episode",
            podcastTitle: syncItem.podcastTitle ?? "",
            audioUrl: syncItem.episodeUrl,
            artworkUrl: syncItem.artworkUrl,
            durationSeconds: syncItem.durationSec.map { Int($0) },
            positionSeconds: Int(syncItem.positionSec ?? 0),
            podcastUrl: syncItem.podcastUrl,
            pubDate: nil
        )
        
        // Apply per-podcast settings so server-synced queue items aren't left
        // with default 0/0/1.0 skip/speed values. The settingsResolver in
        // AudioManager will re-resolve at play time anyway, but this ensures
        // the QueueItem carries correct values for UI display and persistence.
        if let podcast = podcastManager?.subscriptions.first(where: { $0.url == syncItem.podcastUrl }),
           let episode = podcast.episodes.first(where: { $0.guid == guid }) {
            item = applyEffectiveSettings(item, episode: episode)
        }
        
        return item
    }

    
    // MARK: - Sync Conflict Resolution
    
    /// If the resolved conflict's episode is currently loaded, seek the player
    /// **and** explicitly update the position metadata so that:
    /// 1. Cold-start play() uses the resolved position (not the stale local one)
    /// 2. The progress tracker doesn't overwrite Episode.listenedSeconds with stale data
    /// 3. Queue persistence saves the resolved position for app relaunch
    ///
    /// Called by SyncConflictSheet after resolving a conflict via PodcastManager.
    func resolveConflictIfPlaying(_ conflict: SyncConflict, chosenPosition: Int) {
        guard currentEpisodeGuid == conflict.episodeGuid else {
            // Not the currently-playing episode — no seek needed
            return
        }
        logger.info("Seeking to resolved position \(chosenPosition) for currently-playing episode \(conflict.episodeGuid)")
        
        // Explicitly update position metadata BEFORE seeking.
        // AVPlayer.seek() is a no-op when there's no loaded player item (cold start),
        // and the periodic time observer won't fire to update currentPosition.
        // Without these explicit updates, play() → cold-start path uses the stale local position.
        audioManager.currentPosition = TimeInterval(chosenPosition)
        audioManager.currentItem?.positionSeconds = chosenPosition
        
        seek(to: TimeInterval(chosenPosition))
    }
    
    /// Resolve a queue-level sync conflict by updating the queue item's position.
    /// Called from the SyncConflictSheet when the user picks "Use Device" or "Use Server"
    /// for queue items.
    func resolveQueueConflict(_ conflict: SyncConflict, chosenPosition: Int) {
        // Update the queue item's position
        let queue = audioManager.queue
        if let index = queue.firstIndex(where: { $0.id == conflict.episodeGuid }) {
            let item = queue[index]
            let updated = QueueItem(
                id: item.id,
                title: item.title,
                podcastTitle: item.podcastTitle,
                audioUrl: item.audioUrl,
                artworkUrl: item.artworkUrl,
                durationSeconds: item.durationSeconds,
                positionSeconds: chosenPosition,
                podcastUrl: item.podcastUrl,
                pubDate: item.pubDate,
                podcastAuthor: item.podcastAuthor,
                episodeDescription: item.episodeDescription
            )
            var newQueue = queue
            newQueue[index] = updated
            audioManager.replaceQueue(newQueue)
            logger.info("Resolved queue conflict for \(conflict.episodeGuid) → position \(chosenPosition)")
        }
        
        // Also update the current item if it matches — both seek AND metadata
        if let current = audioManager.currentItem, current.id == conflict.episodeGuid {
            audioManager.currentPosition = TimeInterval(chosenPosition)
            audioManager.currentItem?.positionSeconds = chosenPosition
            seek(to: TimeInterval(chosenPosition))
        }
        
        // Push the resolved position to the server
        Task {
            await pushQueueToProServer()
        }
    }
    
    // MARK: - Post-Sync Queue Cleanup
    
    /// Removes episodes from the AudioManager queue (and currentItem) that have been
    /// marked as `isPlayed` in SwiftData by episode action sync.
    ///
    /// Called after `applyEpisodeActions` in the sync orchestrator to bridge the gap
    /// between SwiftData updates and AudioManager state.
    ///
    /// Guards:
    /// - Skips items with no matching SwiftData Episode (server-only queue items)
    /// - Skips items whose Episode is not played
    /// - Uses `markCurrentEpisodeAsPlayed(fromSync: true)` for the current item
    ///   to prevent outbound action echo
    func clearPlayedEpisodesFromQueue(podcastManager: PodcastManager) {
        // Check currentItem first — query SwiftData for played status
        if let current = audioManager.currentItem,
           podcastManager.isEpisodePlayed(guid: current.id) {
            logger.info("clearPlayedEpisodesFromQueue: clearing played currentItem '\(current.title)'")
            markCurrentEpisodeAsPlayed(fromSync: true)
        }
        
        // Remove played items from the Up Next queue
        let beforeCount = audioManager.queue.count
        let filtered = audioManager.queue.filter { !podcastManager.isEpisodePlayed(guid: $0.id) }
        if filtered.count < beforeCount {
            audioManager.replaceQueue(filtered)
            logger.info("clearPlayedEpisodesFromQueue: removed \(beforeCount - filtered.count) played items from queue")
        }
    }
    
    // MARK: - Pro: Now Playing Sync
    
    /// Pushes the currently-playing episode to the Pro server with `nowPlaying` flag.
    /// This tells the web player (and other devices) which episode is active.
    /// No-op for gPodder clients or Vault mode.
    func syncNowPlayingToProServer(nowPlaying: Bool = true, completed: Bool? = nil) {
        guard let item = audioManager.currentItem,
              let syncClient else { return }
        
        let pos = currentPosition
        let dur = item.durationSeconds.map { Double($0) } ?? (currentDuration > 0 ? currentDuration : nil)
        // Stamp the TRUE playback event time, not `Date()`.
        // `playbackEventTimeForSync` is `now` while actively playing (this device
        // is the live source → wins) but the FROZEN last-change time while paused
        // (stale device → loses). User-initiated callers (play/pause/seek/stop)
        // re-stamp the event time immediately before this, so for them it equals
        // `now`. The one caller that is NOT a user action — the scenePhase
        // `.background` lifecycle flush — must NOT stamp `now`: doing so let a
        // paused, stale device (e.g. the iOS-app-on-Mac on every window focus-loss)
        // re-assert its old episode with a fresh timestamp and clobber a newer
        // device's now-playing on the server.
        let eventTime = audioManager.playbackEventTimeForSync

        Task {
            // Sync contract: goes out with this episode's CAS baseline and consumes the answer —
            // acks advance the baseline, conflicts route through the reconciler, and a
            // divergence neither side can settle silently reaches the conflict sheet.
            await pushPlaybackWithCAS(
                item: item,
                positionSec: pos,
                durationSec: dur,
                nowPlaying: nowPlaying,
                completed: completed,
                client: syncClient,
                eventTime: eventTime,
                attempt: 1
            )
            logger.info("Synced nowPlaying=\(nowPlaying) completed=\(String(describing: completed)) for: \(item.title)")
        }
    }
    
    /// Overload that also clears the previous episode's nowPlaying state.
    /// Called when the user manually switches episodes or auto-advance fires.
    func syncNowPlayingToProServer(nowPlaying: Bool = true, clearingPrevious previousItem: QueueItem?) {
        // Bug 2 fix: Clear the previous episode's nowPlaying before setting the new one
        if let previousItem, let syncClient {
            let prevPos = Double(previousItem.positionSeconds)
            let prevDur = previousItem.durationSeconds.map { Double($0) }
            Task {
                // Also a position assertion, so it carries a baseline like any other. An
                // adopt landing here is skipped by `applyPlaybackAdopt` — this episode is
                // by definition no longer the loaded one — which is the correct outcome:
                // the server's value stands and the baseline records the agreement.
                await pushPlaybackWithCAS(
                    item: previousItem,
                    positionSec: prevPos,
                    durationSec: prevDur,
                    nowPlaying: false,
                    completed: nil,
                    client: syncClient,
                    eventTime: Date(),
                    attempt: 1
                )
                logger.info("Cleared nowPlaying for previous: \(previousItem.title)")
            }
        }
        // Now set the new episode as nowPlaying
        syncNowPlayingToProServer(nowPlaying: nowPlaying)
    }
    
    /// Sends `completed: true, nowPlaying: false` for a specific finished episode.
    /// Unlike `syncNowPlayingToProServer`, this takes the completed item explicitly
    /// rather than reading `audioManager.currentItem` (which may have already
    /// auto-advanced to the next episode).
    ///
    /// Bug 1 fix: The old code called `syncNowPlayingToProServer(completed: true)`
    /// which read `audioManager.currentItem` — but auto-advance had already changed
    /// it to the NEXT episode, so `completed: true` was sent for the wrong episode.
    func syncCompletedEpisodeToProServer(_ item: QueueItem) {
        // Enqueue into the durable completion outbox instead of fire-and-forget Task.
        // App Check 403 / network failures / background cancellation previously silently
        // dropped the push; the outbox retries it on the next sync cycle.
        guard syncClient != nil else { return }

        let pending = PendingCompletion(
            podcastUrl: item.podcastUrl,
            episodeUrl: item.audioUrl,
            episodeGuid: item.id,
            durationSec: item.durationSeconds.map { Double($0) },
            eventTime: Date(),
            // The episode finished, so its end is the position — unless the feed never
            // declared one, in which case the playhead this item was left at is the only
            // thing actually observed. See `PendingCompletion.positionSec`.
            positionSec: item.durationSeconds.map(Double.init)
                ?? Double(item.positionSeconds)
        )
        podcastManager?.enqueueCompletion(pending)
        logger.info("Enqueued completion for finished episode: \(item.title)")
    }
    
    /// The episode most recently left, carrying the position it was actually left at.
    ///
    /// Read by `handleItemChanged` to clear that episode's `nowPlaying` on the server.
    /// Written only by `trackPreviousItem`, from `AudioManager.onItemWillChange` — the one
    /// moment the outgoing episode and its live position both still exist.
    ///
    /// It used to be a copy of the *incoming* item, stamped when that episode became
    /// current, so by the time it was read it held a resume position rather than a
    /// listened-to one. `QueueItem` is a struct: the 5-second progress tracker updates
    /// `audioManager.currentItem`, and this copy never saw any of it.
    private(set) var previousItemForSync: QueueItem?

    /// Store the outgoing item as "previous" before an episode switch, at its true position.
    ///
    /// `forceSyncProgress` first: it writes the exact `currentPosition` into
    /// `audioManager.currentItem`, the Episode model and disk, bypassing the 5-second and
    /// 60-second throttles. Without it the recorded position is up to five seconds behind,
    /// and — on a manual skip, which no longer reports a completion — nothing else would
    /// flush the outgoing episode's place before the next episode loads over it.
    func trackPreviousItem(_ item: QueueItem) {
        forceSyncProgress()
        previousItemForSync = audioManager.currentItem ?? item
    }
    
    /// Immediately flushes any pending stats events to the Pro server.
    ///
    /// Called on:
    /// - App entering background (`.scenePhase == .background`)
    /// - Playback pause
    /// - Episode end / auto-advance
    ///
    /// No-op if the user is not authenticated with a YourPods Pro client,
    /// or if there are no pending events to upload.
    func flushStatsIfAuthenticated() {
        guard let proClient = syncClient as? YourPodsProClient else { return }
        
        Task {
            let events = await statsBuffer.flush()
            guard !events.isEmpty else { return }
            
            do {
                try await proClient.pushStatsEvents(events)
                logger.info("Flushed \(events.count) stats events on trigger")
            } catch {
                logger.error("Stats flush failed — restoring \(events.count) events: \(error.localizedDescription)")
                await statsBuffer.restore(events)
            }
        }
    }

    /// Overload that accepts a pre-fetched server state captured BEFORE the
    /// nowPlaying push (Step 5b). This prevents the push from overwriting the
    /// server's `completed: true` flag before reconciliation can read it.
    ///
    /// - Parameter preFetchedState: The server state captured before Step 5b pushed.
    ///   This method uses it directly instead of calling `getCurrentPlayback()`.
    func reconcileNowPlayingWithServer(preFetchedState: ProPlaybackState?) async {
        // No early-return on an empty player: performReconciliation now adopts the
        // server's now-playing episode into an empty mini player (web→iOS handoff,
        // Case 0). Use the pre-fetched state directly — no network call.
        await performReconciliation(with: preFetchedState)
    }

    /// Reconciles the local now-playing state with the Pro server during foreground sync.
    ///
    /// Called as Step 5c in `ProSyncOrchestrator`, after pushing nowPlaying (Step 5b).
    /// Uses the server's `completed` flag as the authoritative signal — no client-side
    /// heuristics (95% threshold, action map, etc.).
    ///
    /// Cases:
    /// 0. Local player is empty → adopt the server's now-playing episode (web→iOS
    ///    handoff): load it paused at the server position. Never interrupts audio.
    /// 1. Server's current episode is `completed: true` → mark played, advance
    /// 2. Server's current episode is different from local → load server's episode
    ///    (do NOT mark local as played — it may be legitimately in progress on this device)
    /// 3. Server returns nil (no active playback) → no-op (nil ≠ completed;
    ///    server may not have received our nowPlaying push yet, or may have no state)
    /// 4. Same episode, different position → reconcile using syncConflictStrategy
    /// 5. Not a Pro client → no-op
    ///
    /// The `isPlaying` guard is applied per-case rather than globally:
    /// - `completed: true` + playing → defer (never mark playing episode as completed)
    /// - Different episode + playing → log and defer to queue sync
    /// - Same episode + playing → no-op (don't seek during active playback)
    /// - All cases when paused → full reconciliation
    func reconcileNowPlayingWithServer() async {
        // Guard: Only supported for clients that implement playback reconciliation.
        // gPodder/Vault default to false — they don't have the /playback/current endpoint.
        // (No empty-player early-return: an empty player is a valid adopt case — the
        // server may hold a now-playing episode set on another device. See Case 0.)
        guard let client = syncClient else {
            return
        }
        
        let supportsReconciliation = await client.supportsPlaybackReconciliation
        guard supportsReconciliation else {
            return
        }
        
        do {
            let serverState = try await client.getCurrentPlayback()
            await performReconciliation(with: serverState)
        } catch {
            logger.error("reconcileNowPlaying failed: \(error.localizedDescription)")
        }
    }
    
    /// Shared reconciliation logic used by both the parameterless and pre-fetched overloads.
    /// Accepts the server state directly — no network calls.
    private func performReconciliation(with serverState: ProPlaybackState?) async {
        // Diagnostic boundary log (cross-device handoff): records the exact inputs
        // to the adopt decision so a "device stayed stale" report can be pinned to a
        // specific branch from the field log alone. Public fields are non-PII
        // discriminators (presence + does-server-differ-from-local, which is the
        // Case 2 trigger); the human-readable titles are default-private (redacted
        // in archived/exported logs).
        let localItem = self.audioManager.currentItem
        logger.info("reconcileNowPlaying: ENTER localPresent=\(localItem != nil, privacy: .public) playing=\(self.audioManager.isPlaying, privacy: .public) serverPresent=\(serverState != nil, privacy: .public) serverDiffersFromLocal=\(serverState?.episodeUrl != localItem?.audioUrl, privacy: .public) serverNowPlaying=\(serverState?.nowPlaying.map(String.init) ?? "nil", privacy: .public) serverCompleted=\(serverState?.completed.map(String.init) ?? "nil", privacy: .public) local='\(localItem?.title ?? "nil")' server='\(serverState?.title ?? "nil")'")
        // Case 0: Empty player — adopt the server's now-playing episode if present.
        // This is the per-sync analogue of restoreNowPlayingFromProServer (which runs
        // only at login / fresh-device). Without it, a web-set now-playing never reaches
        // an iOS device whose player is empty (queue consumed, or nothing started this
        // session): the server state would be fetched and silently discarded — the user
        // picks up iOS to an empty mini player. Safe by construction: an empty player is
        // never actively playing, so this can't interrupt audio.
        guard let currentItem = audioManager.currentItem else {
            await adoptServerNowPlayingIntoEmptyPlayer(serverState)
            return
        }
        let isPlaying = audioManager.isPlaying
        
        if let state = serverState {
            if state.completed == true {
                // Case 1: Server says the current episode is finished
                guard !isPlaying else {
                    logger.info("reconcileNowPlaying: server=completed but playing — deferring")
                    return
                }
                logger.info("reconcileNowPlaying: server reports completed — marking as played")
                markCurrentEpisodeAsPlayed(fromSync: true)
            } else if state.episodeUrl != currentItem.audioUrl {
                // Case 2: Server is playing a different episode
                guard !isPlaying else {
                    // Log and defer — queue sync will handle item membership.
                    // Don't interrupt active playback.
                    logger.info("reconcileNowPlaying: server has '\(state.title ?? "?")' but playing '\(currentItem.title)' — deferring to queue sync")
                    return
                }
                // Paused → safe to switch to server's episode
                logger.info("reconcileNowPlaying: server playing different episode — switching (local preserved)")
                
                let item = QueueItem(
                    id: state.episodeGuid ?? state.episodeUrl,
                    title: state.title ?? "Unknown Episode",
                    podcastTitle: state.podcastTitle ?? "",
                    audioUrl: state.episodeUrl,
                    artworkUrl: state.artUrl,
                    durationSeconds: state.durationSec.map { Int($0) },
                    positionSeconds: Int(state.positionSec),
                    podcastUrl: state.podcastUrl,
                    pubDate: nil
                )
                // Load the server's episode at its position WITHOUT starting
                // playback. autoPlay:false avoids the old play()→pause() flicker
                // (transient isPlaying=true, audio-session grab, FigFilePlayer
                // err=-12864 on the not-yet-ready item) on this paused handoff.
                await audioManager.playEpisode(item, initialPosition: state.positionSec, preserveCurrent: false, autoPlay: false)
            } else {
                // Case 3: Same episode — reconcile position if needed
                guard !isPlaying else { return }
                
                let serverPos = Int(state.positionSec)
                let localPos = currentItem.positionSeconds
                let diff = abs(serverPos - localPos)
                
                // Skip noise — position differences ≤10s are not worth reconciling
                guard diff > SyncThresholds.reconcilePositionGapSeconds else { return }

                // Freshness gate (the sync contract, apply side). Adopt a pulled
                // position only when the server row is NOT meaningfully older than this
                // device's own last local change. The gate is what keeps the adopt from
                // clobbering a fresh local seek: syncPlaybackChain reconciles against a
                // snapshot taken BEFORE our own push (Step 5b pre-fetch → 5d push →
                // 5e reconcile), so without it a seek-then-sync would be pushed,
                // accepted by the server, and then overwritten by the stale pre-fetch.
                //
                // Two caveats:
                // - `updatedAt` is the server's ARRIVAL time, bumped even when the merge
                //   rejects the incoming position — an upper bound on the true event
                //   time, so this leans toward adopting. That is the safe direction:
                //   the sync contract is explicit that declining strands two devices at different
                //   playheads with no path to converge.
                // - The two stamps come from DIFFERENT clocks (server vs device), so the
                //   comparison carries a small skew allowance. Small is load-bearing —
                //   see `remoteEventTimeSkewSeconds` for why a generous one silently
                //   destroys a backward local seek.
                // Swap `updatedAtDate` for the row's `clientUpdatedAt` once the server
                // exposes it on /playback/current; the predicate keeps its shape, and
                // the skew allowance can go away entirely.
                let serverEventTime = state.updatedAtDate
                if let serverEventTime,
                   serverEventTime < audioManager.playbackEventTime.addingTimeInterval(-Double(SyncThresholds.remoteEventTimeSkewSeconds)) {
                    logger.info("reconcileNowPlaying: not adopting \(serverPos)s — server row predates this device's last local change")
                    return
                }

                let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
                switch strategy {
                case .serverWins:
                    // Adopts BACKWARD as readily as forward — the sync contract: "A backward move
                    // under a newer event time is not corruption — it is another device
                    // reporting where the user actually stopped."
                    logger.info("reconcileNowPlaying: adopting server position \(serverPos)s (was \(localPos)s)")
                    audioManager.adoptRemotePosition(state.positionSec, eventTime: serverEventTime)
                case .deviceWins:
                    // Keep local position
                    break
                case .ask:
                    // Silently adopt if one side is 0 (never played); otherwise defer
                    if localPos == 0 || serverPos == 0 {
                        let adoptPos = max(serverPos, localPos)
                        // Carry the server's event time only when we actually took the
                        // server's value; keeping our own must not rewrite our ordering.
                        audioManager.adoptRemotePosition(
                            Double(adoptPos),
                            eventTime: adoptPos == serverPos ? serverEventTime : nil
                        )
                    }
                }
            }
        } else {
            // Case 4: No active playback on server.
            // Nil is ambiguous — the server filters completed rows out of
            // /playback/current, so nil means EITHER "no state" OR "the active
            // episode was just completed elsewhere." Default to PRESERVING the
            // local item, EXCEPT when it is already marked played locally (e.g.
            // Fix A applied the server's authoritative `completed` flag earlier
            // this cycle). A known-finished, not-actively-playing item must be
            // cleared, not preserved forever.
            if !isPlaying, podcastManager?.isEpisodePlayed(guid: currentItem.id) == true {
                logger.info("reconcileNowPlaying: server nil but current item already played — clearing")
                markCurrentEpisodeAsPlayed(fromSync: true)
            } else {
                // Common benign causes: nowPlaying not pushed yet (sync ordering),
                // server transient error, or the user just started listening.
                logger.info("reconcileNowPlaying: no server playback state — preserving local item (nil ≠ completed)")
            }
        }
    }

    /// Checks the Pro server for a `nowPlaying` episode from another device.
    /// If found and no episode is currently loaded locally, loads it into the player
    /// at the server's last position. The episode loads ready to play — the user
    /// presses play when ready, just like any queue-restored episode.
    ///
    /// Guards:
    /// - No-op if an episode is already loaded locally (queue restore takes priority)
    /// - No-op for gPodder clients or Vault mode (protocol default returns nil)
    /// - Skips stale states (updatedAt > 24h ago)
    /// - Skips completed episodes
    func restoreNowPlayingFromProServer() async {
        guard audioManager.currentItem == nil,
              let client = syncClient else { return }

        do {
            let state = try await client.getCurrentPlayback()
            await adoptServerNowPlayingIntoEmptyPlayer(state)
        } catch {
            logger.error("Failed to restore nowPlaying: \(error.localizedDescription)")
        }
    }

    /// Loads the server's now-playing episode into an EMPTY player at its last
    /// position, paused. Shared by the login/fresh-device restore
    /// (`restoreNowPlayingFromProServer`) and the per-sync reconcile Case 0
    /// (`performReconciliation`), so the web→iOS handoff behaves identically whether
    /// it fires at launch or on a routine sync.
    ///
    /// Guards (caller guarantees `currentItem == nil`, so this never interrupts audio):
    /// - Adopts only a fresh state the server marks `nowPlaying == true`
    /// - Never resurrects a completed episode (`completed != true`)
    /// - Skips stale states (updatedAt > 24h ago) — a day-old web session must not
    ///   silently surface on a phone the user just picked up
    private func adoptServerNowPlayingIntoEmptyPlayer(_ serverState: ProPlaybackState?) async {
        guard let state = serverState,
              state.nowPlaying == true,
              state.completed != true else {
            logger.info("adoptEmptyPlayer: skip — server=\(serverState == nil ? "nil" : "present", privacy: .public) nowPlaying=\(serverState?.nowPlaying.map(String.init) ?? "nil", privacy: .public) completed=\(serverState?.completed.map(String.init) ?? "nil", privacy: .public)")
            return
        }

        // Staleness guard: don't restore episodes from more than 24 hours ago
        if let updatedAt = state.updatedAtDate {
            let age = Date().timeIntervalSince(updatedAt)
            if age > 24 * 3600 {
                logger.info("Skipping stale nowPlaying state (age: \(Int(age / 3600))h)")
                return
            }
        }

        // Build a QueueItem directly from server fields — the episode need not exist
        // in local SwiftData (it may be from a podcast only ever played on the web).
        let item = QueueItem(
            id: state.episodeGuid ?? state.episodeUrl,
            title: state.title ?? "Unknown Episode",
            podcastTitle: state.podcastTitle ?? "",
            audioUrl: state.episodeUrl,
            artworkUrl: state.artUrl,
            durationSeconds: state.durationSec.map { Int($0) },
            positionSeconds: Int(state.positionSec),
            podcastUrl: state.podcastUrl,
            pubDate: nil
        )

        logger.info("Adopting server nowPlaying into empty player: \(item.title) at \(Int(state.positionSec))s")
        await audioManager.playEpisode(item, initialPosition: state.positionSec, preserveCurrent: false)
        audioManager.pause()  // Load at position but don't auto-play
    }
    
    // MARK: - Progress Calculation
    
    /// Calculates playback progress as a fraction clamped to [0, 1].
    /// Use this everywhere progress is displayed to avoid overflow/underflow.
    nonisolated static func playbackProgress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
    
    // MARK: - Formatting Helpers
    
    /// Formats seconds as `m:ss` or `h:mm:ss` for time-position display.
    ///
    /// Retained as a forwarding shim: views and tests across the app call this
    /// name. See `DurationFormatting.timestamp(_:)` for why the clock is
    /// deliberately locale-independent.
    nonisolated static func formatTimestamp(_ seconds: TimeInterval) -> String {
        DurationFormatting.timestamp(seconds)
    }
    
    /// Approximate duration for row subtitles — see `DurationFormatting.compact(_:)`.
    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        DurationFormatting.compact(seconds)
    }
    
    nonisolated static func formatProgress(position: TimeInterval, duration: TimeInterval, showPercent: Bool = true) -> String {
        guard duration > 0 else { return "0%" }
        let pct = Int((position / duration * 100).clamped(to: 0...100))
        return showPercent
            ? DurationFormatting.percentListened(pct)
            : DurationFormatting.percentLeft(100 - pct)
    }
}

// MARK: - Comparable clamped extension
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

