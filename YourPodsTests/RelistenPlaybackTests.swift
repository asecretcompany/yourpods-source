import XCTest
import SwiftData
@testable import YourPods

/// Regression coverage for explicit replay/relisten behavior across playback surfaces.
@MainActor
final class RelistenPlaybackTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        context = nil
        container = nil
        super.tearDown()
    }

    private func makeQueueItem(
        guid: String,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 0
    ) -> QueueItem {
        QueueItem(
            id: guid,
            title: "Episode \(guid)",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(guid).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    private func makeEpisode(
        guid: String,
        isPlayed: Bool,
        listenedSeconds: Int
    ) -> (Podcast, Episode) {
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Test Podcast")
        context.insert(podcast)

        let episode = Episode(
            guid: guid,
            title: "Episode \(guid)",
            audioUrl: "https://example.com/\(guid).mp3",
            durationSeconds: 3600,
            podcast: podcast
        )
        episode.isPlayed = isPlayed
        episode.listenedSeconds = listenedSeconds
        context.insert(episode)
        try! context.save()

        return (podcast, episode)
    }

    func test_playQueueItem_playedEpisode_restartsAtZeroAndClearsPlayedState() async {
        let (podcast, episode) = makeEpisode(
            guid: "ep-relisten-from-queue",
            isPlayed: true,
            listenedSeconds: 3600
        )

        let podcastManager = PodcastManager(modelContext: context)
        podcastManager.subscriptions = [podcast]

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        let staleQueueItem = makeQueueItem(
            guid: episode.guid,
            positionSeconds: 3600
        )
        audioManager.appendToQueue([staleQueueItem])

        playerManager.playQueueItem(staleQueueItem)

        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)

        let started = await relistenPollUntil { audioManager.currentItem?.id == episode.guid }
        XCTAssertTrue(started)
        XCTAssertEqual(audioManager.currentPosition, 0)
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0)
    }

    /// Episode-based playback is shared by library, Siri, deep links and CarPlay.
    /// A stale explicit end position must not override relisten-at-zero semantics.
    func test_playEpisode_playedEpisode_ignoresExplicitEndPositionAndRelistens() async {
        let (podcast, episode) = makeEpisode(
            guid: "ep-relisten-from-episode",
            isPlayed: true,
            listenedSeconds: 3600
        )

        let podcastManager = PodcastManager(modelContext: context)
        podcastManager.subscriptions = [podcast]

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        playerManager.playEpisode(episode, position: 3600)

        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)

        let started = await relistenPollUntil { audioManager.currentItem?.id == episode.guid }
        XCTAssertTrue(started)
        XCTAssertEqual(audioManager.currentPosition, 0)
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0)
    }

    /// Deliberate positions such as a shared "Play from 12:34" link stay authoritative
    /// even when starting a relisten.
    func test_playQueueItem_playedEpisode_honorsExplicitUserPosition() async {
        let (podcast, episode) = makeEpisode(
            guid: "ep-relisten-explicit-position",
            isPlayed: true,
            listenedSeconds: 3600
        )

        let podcastManager = PodcastManager(modelContext: context)
        podcastManager.subscriptions = [podcast]

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        let staleQueueItem = makeQueueItem(
            guid: episode.guid,
            positionSeconds: 3600
        )

        playerManager.playQueueItem(staleQueueItem, position: 754)

        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)

        let started = await relistenPollUntil { audioManager.currentItem?.id == episode.guid }
        XCTAssertTrue(started)
        XCTAssertEqual(audioManager.currentPosition, 754)
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 754)
    }

    func test_playEpisode_unplayedEpisode_preservesPosition() async {
        let (podcast, episode) = makeEpisode(
            guid: "ep-resume-from-episode",
            isPlayed: false,
            listenedSeconds: 900
        )

        let podcastManager = PodcastManager(modelContext: context)
        podcastManager.subscriptions = [podcast]

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        playerManager.playEpisode(episode)

        let started = await relistenPollUntil { audioManager.currentItem?.id == episode.guid }
        XCTAssertTrue(started)
        XCTAssertEqual(audioManager.currentPosition, 900)
        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 900)
    }

    func test_playQueueItem_sameGuidInDifferentPodcast_doesNotFalseRelisten() async {
        let sharedGuid = "shared-guid"

        let playedPodcast = Podcast(url: "https://example.com/played.xml", title: "Played")
        context.insert(playedPodcast)
        let playedEpisode = Episode(
            guid: sharedGuid,
            title: "Played",
            audioUrl: "https://example.com/played.mp3",
            durationSeconds: 3600,
            podcast: playedPodcast
        )
        playedEpisode.isPlayed = true
        playedEpisode.listenedSeconds = 3600
        context.insert(playedEpisode)

        let targetPodcast = Podcast(url: "https://example.com/target.xml", title: "Target")
        context.insert(targetPodcast)
        let targetEpisode = Episode(
            guid: sharedGuid,
            title: "Target",
            audioUrl: "https://example.com/target.mp3",
            durationSeconds: 3600,
            podcast: targetPodcast
        )
        targetEpisode.isPlayed = false
        targetEpisode.listenedSeconds = 900
        context.insert(targetEpisode)
        try! context.save()

        let podcastManager = PodcastManager(modelContext: context)
        podcastManager.subscriptions = [playedPodcast, targetPodcast]

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        let queuedItem = QueueItem(
            id: sharedGuid,
            title: targetEpisode.title,
            podcastTitle: targetPodcast.title,
            audioUrl: targetEpisode.audioUrl!,
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 900,
            podcastUrl: targetPodcast.url,
            pubDate: nil
        )

        playerManager.playQueueItem(queuedItem)

        let started = await relistenPollUntil { audioManager.currentItem?.audioUrl == queuedItem.audioUrl }
        XCTAssertTrue(started)
        XCTAssertEqual(audioManager.currentPosition, 900)
        XCTAssertFalse(targetEpisode.isPlayed)
        XCTAssertEqual(targetEpisode.listenedSeconds, 900)
        XCTAssertTrue(playedEpisode.isPlayed)
    }

    func test_playQueueItem_unplayedEpisode_preservesPosition() async {
        let (podcast, episode) = makeEpisode(
            guid: "ep-resume-from-queue",
            isPlayed: false,
            listenedSeconds: 900
        )

        let podcastManager = PodcastManager(modelContext: context)
        podcastManager.subscriptions = [podcast]

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        let queuedItem = makeQueueItem(
            guid: episode.guid,
            positionSeconds: 900
        )
        audioManager.appendToQueue([queuedItem])

        playerManager.playQueueItem(queuedItem)

        let started = await relistenPollUntil { audioManager.currentItem?.id == episode.guid }
        XCTAssertTrue(started)
        XCTAssertEqual(audioManager.currentPosition, 900)
        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 900)
    }
}

@MainActor
private func relistenPollUntil(
    timeout: TimeInterval = 2.0,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        await Task.yield()
    }
    return condition()
}
