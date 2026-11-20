import SwiftUI

/// Preview of a shared episode the user doesn't follow. Actions: Play,
/// Play from M:SS (timestamp shares), Add to Queue, Follow. Dependencies are
/// passed explicitly (macOS sheets don't inherit @Observable environments).
///
/// The append button said "Add to Up Next" while the identical action said
/// "Add to Queue" in every context menu in the app (and in the VoiceOver action
/// on episode rows). "Up Next" is the queue's *screen* name; the action is
/// "Add to Queue" everywhere, so this sheet no longer disagrees with it.
struct SharedEpisodePreviewSheet: View {
    let shared: SharedEpisode
    let playerManager: PlayerManager
    let podcastManager: PodcastManager
    @Environment(\.dismiss) private var dismiss
    @State private var isFollowing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CachedAsyncImage(url: shared.artworkUrl.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.2))
                    }
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                    Text(shared.title).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(shared.podcastTitle).font(.subheadline).foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        Button { play(from: 0) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Play \(shared.title)")

                        if let t = shared.startSec, t > 0 {
                            Button { play(from: t) } label: {
                                Label("Play from \(PlayerManager.formatTimestamp(TimeInterval(t)))", systemImage: "clock")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Play \(shared.title) from \(PlayerManager.formatTimestamp(TimeInterval(t)))")
                        }

                        Button {
                            playerManager.audioManager.appendToQueue([shared.toQueueItem()])
                            dismiss()
                        } label: {
                            Label("Add to Queue", systemImage: "text.append").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Add \(shared.title) to Queue")

                        Button { Task { @MainActor in await follow() } } label: {
                            Label(isFollowing ? "Following" : "Follow Show",
                                  systemImage: isFollowing ? "checkmark" : "plus").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isFollowing)
                        .accessibilityLabel(isFollowing ? "Following \(shared.podcastTitle)" : "Follow \(shared.podcastTitle)")
                    }
                    .padding(.horizontal)

                    if let desc = shared.episodeDescription, !desc.isEmpty {
                        Text(desc.strippingHTML()).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Shared Episode")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func play(from seconds: Int) {
        playerManager.playQueueItem(
            shared.toQueueItem(positionSeconds: seconds),
            position: TimeInterval(seconds)
        )
        dismiss()
    }

    private func follow() async {
        do {
            try await podcastManager.addSubscription(url: shared.feedUrl)
            isFollowing = true
        } catch {
            // Subscription failed — leave the button actionable so the user can retry.
        }
    }
}
