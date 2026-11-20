import SwiftUI
import SwiftData

/// Root content view with tab navigation and persistent mini-player.
///
/// The TabView **always** renders immediately to prevent any black screen.
/// First-launch onboarding shows a profile setup sheet for new installs.
struct ContentView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioManager.self) private var audioManager
    @Environment(DownloadManager.self) private var downloadManager
    
    /// Show onboarding profile setup for fresh installs.
    @State private var showOnboarding = false
    @State private var showTranslationDisclosure = false
    
    var body: some View {
        @Bindable var nav = navigationState
        
        // ── TabView always renders — no black screen possible ──
        ZStack(alignment: .bottom) {
            TabView(selection: $nav.selectedTab) {
                HomeView()
                    .tabItem {
                        tabLabel("Home", systemImage: "house.fill")
                    }
                    .tag(0)
                
                LibraryView()
                    .tabItem {
                        tabLabel("Library", systemImage: "books.vertical.fill")
                    }
                    .tag(1)
                
                QueueView()
                    .tabItem {
                        tabLabel("Up Next", systemImage: "list.bullet")
                    }
                    .tag(2)
                
                PodcastSearchView()
                    .tabItem {
                        tabLabel("Add Podcasts", systemImage: "plus.circle")
                    }
                    .tag(3)
                
                SettingsView()
                    .tabItem {
                        tabLabel("Settings", systemImage: "gear")
                    }
                    .tag(4)
            }
            .id(settingsManager.tabBarDisplayMode)
            #if os(iOS)
            .onAppear { applyTabBarTitlePosition() }
            .onChange(of: settingsManager.tabBarDisplayMode) { applyTabBarTitlePosition() }
            #endif
            .padding(.bottom, playerManager.currentEpisodeGuid != nil ? 90 : 0)
            
            // Persistent mini-player
            if playerManager.currentEpisodeGuid != nil {
                NowPlayingBar()
                    .transition(.move(edge: .bottom))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Mini player")
            }
        }
        // ── Onboarding: show profile setup on fresh installs ──
        .task {
            if !settingsManager.hasCompletedOnboarding {
                showOnboarding = true
            }
            showTranslationDisclosure = TranslationDisclosurePolicy.shouldPresent(
                resolvedLocalization: TranslationDisclosurePolicy.resolvedLocalization(),
                hasCompletedOnboarding: settingsManager.hasCompletedOnboarding,
                seenLanguages: settingsManager.translationDisclosureSeenLanguages)
        }
        // ── AI-translation disclosure: once per language, non-English only ──
        //
        // iOS relaunches the app when its Preferred Language changes, so this
        // `.task` runs again with the new localization resolved and the sheet
        // appears for a language the user has not yet been told about.
        .sheet(isPresented: $showTranslationDisclosure, onDismiss: {
            // Recorded on dismiss rather than on present: a user who force-quits
            // mid-sheet has not been told anything, and should be next launch.
            settingsManager.markTranslationDisclosureSeen(
                for: TranslationDisclosurePolicy.languageCode(
                    of: TranslationDisclosurePolicy.resolvedLocalization()))
        }) {
            TranslationDisclosureSheet(onChangeLanguage: {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
            })
        }
        // ── First-launch onboarding: multi-page flow ──
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
                .environment(settingsManager)
                .environment(podcastManager)
                .environment(navigationState)
                .interactiveDismissDisabled()
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environment(settingsManager)
                .environment(podcastManager)
                .environment(navigationState)
                .interactiveDismissDisabled()
                .frame(minWidth: 500, minHeight: 600)
        }
        #endif
        // ── Sync conflict resolution (shown when strategy = .ask) ──
        .sheet(isPresented: Binding(
            get: { !playerManager.pendingConflicts.isEmpty || !playerManager.pendingUrlRewrites.isEmpty },
            set: { if !$0 { playerManager.pendingConflicts.removeAll(); playerManager.pendingUrlRewrites.removeAll() } }
        )) {
            SyncConflictSheet()
                .environment(podcastManager)
                .environment(playerManager)
        }
        // ── Deep-link share presentation ──
        .sheet(item: $nav.pendingSharedEpisode) { shared in
            SharedEpisodePreviewSheet(shared: shared, playerManager: playerManager, podcastManager: podcastManager)
        }
        .sheet(item: $nav.pendingSharedPodcast) { shared in
            SharedPodcastPreviewSheet(shared: shared, podcastManager: podcastManager)
        }
        .sheet(item: $nav.deepLinkEpisode) { item in
            if let ep = podcastManager.subscriptions.flatMap(\.episodes).first(where: { $0.guid == item.id }) {
                EpisodeDetailSheet(episode: ep)
                    .environment(playerManager).environment(podcastManager).environment(downloadManager)
                    .environment(settingsManager).environment(navigationState).modelContext(modelContext)
            } else {
                NavigationStack {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("This episode isn't available.").font(.headline)
                        Text("It may have been removed from your library.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { nav.deepLinkEpisode = nil } } }
                }
            }
        }
        .onChange(of: nav.knownPodcastFeedToOpen) { _, feed in
            navigationState.knownPodcastFeedToOpen = nil
            guard let feed, let podcast = podcastManager.subscriptions.first(where: { $0.url == feed }) else { return }
            navigationState.navigateToLibrary(podcast: podcast)
        }
        .alert("Couldn't open this share", isPresented: $nav.deepLinkFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The episode or podcast couldn't be loaded. It may have moved or the link may be invalid.")
        }
    }
    
    // MARK: - Tab Bar Display Mode
    
    @ViewBuilder
    private func tabLabel(_ title: String, systemImage: String) -> some View {
        switch settingsManager.tabBarDisplayMode {
        case .textOnly:
            Text(title)
        case .iconOnly:
            Image(systemName: systemImage)
        case .textAndIcon:
            Label(title, systemImage: systemImage)
        }
    }
    
    /// Adjust tab bar title position — center text vertically when in text-only mode.
    #if os(iOS)
    private func applyTabBarTitlePosition() {
        let appearance = UITabBarItem.appearance()
        if settingsManager.tabBarDisplayMode == .textOnly {
            appearance.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -8)
        } else {
            appearance.titlePositionAdjustment = .zero
        }
    }
    #endif
}
