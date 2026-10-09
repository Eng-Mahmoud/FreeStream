import SwiftUI
import AVKit
import MediaPlayer

@main
struct FreeStreamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { LibraryTabs().preferredColorScheme(.dark) } }
}

struct HomeView: View {
    var favoritesOnly = false
    @Binding var selectedTab: Int
    @ObservedObject private var library = StreamLibrary.shared
    @ObservedObject private var favorites = Favorites.shared
    @State private var search = ""
    @State private var filter = "All"
    @State private var selected: Channel?
    @State private var selectedSeries: Series?
    private var groups: [MediaGroup] {
        MediaGroup.make(items: library.items, shows: library.series).compactMap { group in
            guard filter == "All" || filter == group.kind.filterName else { return nil }
            let channels = group.channels.filter {
                (!favoritesOnly || favorites.contains($0)) && matches($0.name, $0.group)
            }
            let shows = group.shows.filter {
                (!favoritesOnly || favorites.contains($0)) && matches($0.name, $0.group)
            }
            guard !channels.isEmpty || !shows.isEmpty else { return nil }
            return MediaGroup(id: group.id, name: group.name, kind: group.kind, channels: channels, shows: shows)
        }
    }
    private func matches(_ name: String, _ group: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search) || group.localizedCaseInsensitiveContains(search)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    Text("MahmoudTV").font(.largeTitle.bold())
                    Picker("Content", selection: $filter) {
                        ForEach(["All", "Live", "Movies", "Series"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    if library.items.isEmpty && library.series.isEmpty {
                        ContentUnavailableView("Add your media source", systemImage: "play.rectangle", description: Text("Open Settings to load live TV, movies and series."))
                        Button("Open Settings") { selectedTab = 2 }.buttonStyle(.borderedProminent)
                    } else if groups.isEmpty {
                        ContentUnavailableView(favoritesOnly ? "No favorites found" : "No results", systemImage: favoritesOnly ? "heart" : "magnifyingglass", description: Text(favoritesOnly ? "Tap a heart while browsing or watching. Try another filter or search." : "Try another filter or search."))
                    }
                    ForEach(groups) { group in
                        MediaGroupRow(group: group, favoritesOnly: favoritesOnly, play: { item in
                            Playback.shared.open(item, queue: item.live ? group.channels : [item]); selected = item
                        }, openSeries: { selectedSeries = $0 })
                    }
                }.padding()
            }
            .background(Color(red: 0.035, green: 0.045, blue: 0.075))
            .navigationTitle(favoritesOnly ? "Favorites" : "Home")
            .searchable(text: $search, prompt: "Search media or source groups")
            .safeAreaInset(edge: .bottom) {
                MiniPlayer { selected = $0 }
            }
            .sheet(item: $selected) { PlaybackView(channel: $0) }
            .sheet(item: $selectedSeries) { SeriesView(series: $0) }
        }.tint(.cyan)
    }
}

struct MediaCard: View {
    let name: String
    let subtitle: String
    let kind: String
    let symbol: String
    let artwork: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.cyan.opacity(0.3), .indigo.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                AsyncImage(url: artwork) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { Image(systemName: symbol).font(.system(size: 42)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(kind).font(.caption2.bold()).padding(6).background(.black.opacity(0.5)).clipShape(Capsule()).padding(8)
            }.frame(height: kind == "MOVIE" || kind == "SERIES" ? 205 : 110).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(name).font(.headline).lineLimit(2).frame(height: 44, alignment: .topLeading)
            Text(subtitle.isEmpty ? kind.capitalized : subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(10).background(.white.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SeriesView: View {
    let series: Series
    @ObservedObject private var favorites = Favorites.shared
    @State private var episodes: [Channel] = []
    @State private var episodeMessage = ""
    @State private var loading = true
    @State private var search = ""
    @State private var selected: Channel?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading { ProgressView("Loading episodes") }
                    if !episodeMessage.isEmpty { Text(episodeMessage).foregroundStyle(.orange) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(episodes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }) { episode in
                            Button { Playback.shared.open(episode, queue: episodes, series: series); selected = episode } label: {
                                MediaCard(name: episode.name, subtitle: episode.group, kind: "EPISODE", symbol: "play.rectangle", artwork: episode.artwork ?? series.artwork)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding()
            }.navigationTitle(series.name).searchable(text: $search, prompt: "Search episodes or seasons")
                .toolbar { FavoriteButton(selected: favorites.contains(series)) { favorites.toggle(series) }; Button("Done") { dismiss() } }
                .task {
                    do { episodes = try await Catalog.episodes(series); if episodes.isEmpty { episodeMessage = "No episodes returned." } }
                    catch { episodeMessage = "Could not load episodes. Check provider and connection." }
                    loading = false
                }
                .sheet(item: $selected) { PlaybackView(channel: $0) }
        }
    }
}

@MainActor
final class Playback: ObservableObject {
    static let shared = Playback()
    let player = AVPlayer()
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var timeObserver: Any?
    private var stallMonitor: Task<Void, Never>?

    private init() {
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            let token = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            remoteTargets.append((command, token))
        }
        register(center.playCommand) { [weak self] in self?.player.play() }
        register(center.pauseCommand) { [weak self] in self?.pause() }
        register(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            self.togglePause()
        }
        register(center.nextTrackCommand) { [weak self] in self?.next() }
        register(center.previousTrackCommand) { [weak self] in self?.previous() }
        register(center.stopCommand) { [weak self] in self?.stop() }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.publishNowPlaying()
                self?.updateTimeline()
            }
        }
    }
    private func updateTimeline() {
        let value = player.currentTime().seconds
        elapsed = value.isFinite ? max(0, value) : 0
        let total = player.currentItem?.duration.seconds ?? 0
        duration = total.isFinite ? max(0, total) : 0
    }
    private func publishNowPlaying() {
        guard let channel else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: channel.name,
            MPMediaItemPropertyArtist: channel.group,
            MPNowPlayingInfoPropertyIsLiveStream: channel.live,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate]
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    @Published var state = "Preparing"
    @Published var diagnostic = ""
    @Published private(set) var channel: Channel?
    @Published private(set) var queue: [Channel] = []
    @Published private(set) var series: Series?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    private var queueIndex: Int? { queue.firstIndex { $0.id == channel?.id } }
    var canGoNext: Bool { guard let index = queueIndex else { return false }; return index + 1 < queue.count }
    var canGoPrevious: Bool { guard let index = queueIndex else { return false }; return index > 0 }
    func next() { guard let index = queueIndex, canGoNext else { return }; open(queue[index + 1], queue: queue, series: series) }
    func previous() { guard let index = queueIndex, canGoPrevious else { return }; open(queue[index - 1], queue: queue, series: series) }
    func pause() {
        retryTask?.cancel(); retryTask = nil; waitingSince = nil
        player.pause()
    }
    func togglePause() {
        if player.timeControlStatus == .paused { player.play() } else { pause() }
    }
    func seek(_ seconds: Double) {
        guard channel?.live == false, duration > 0 else { return }
        player.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600))
    }
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var retries = 0
    private var retryTask: Task<Void, Never>?
    private var waitingSince: Date?
    private var resumePosition: Double = 0

    func open(_ channel: Channel, queue: [Channel]? = nil, series: Series? = nil) {
        self.queue = queue ?? (channel.live ? StreamLibrary.shared.items.filter { $0.live } : [channel])
        self.series = series
        elapsed = 0; duration = 0
        stallMonitor?.cancel()
        stallMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                guard let self else { return }
                self.checkForStall()
            }
        }
        retryTask?.cancel(); retryTask = nil; diagnostic = ""
        self.channel = channel; retries = 0; resumePosition = 0; waitingSince = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { diagnostic = "Audio session could not be activated." }
        replaceItem()
    }
    private func detach() {
        observations.removeAll()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
    private func replaceItem() {
        guard let channel else { return }
        detach()
        waitingSince = nil
        state = "Connecting"
        let item = AVPlayerItem(url: channel.url)
        item.preferredForwardBufferDuration = channel.live ? 8 : 15
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .readyToPlay, !channel.live, self.resumePosition > 0 {
                    let position = self.resumePosition
                    self.resumePosition = 0
                    self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { [weak self] completed in
                        Task { @MainActor in
                            guard completed, let self, self.player.currentItem === item else { return }
                            self.player.play()
                        }
                    }
                }
                if item.status == .failed {
                    if let error = item.error as NSError? {
                        self.diagnostic = "Player error: \(error.domain), code \(error.code). Try HLS for live TV; VOD may use an unsupported codec."
                    }
                    self.reconnect()
                }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                switch player.timeControlStatus {
                case .playing: self.playing = true; self.waitingSince = nil; self.state = "Playing"
                case .waitingToPlayAtSpecifiedRate:
                    self.playing = false
                    if self.waitingSince == nil { self.waitingSince = Date() }
                    self.state = "Buffering"
                case .paused: self.playing = false; self.waitingSince = nil; self.state = "Paused"
                @unknown default: self.state = "Unknown"
                }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if self.channel?.live == true { self.reconnect() } else { self.state = "Finished" }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.reconnect()
            }
        })
        player.play()
        publishNowPlaying()
    }
    private func reconnect() {
        guard channel != nil else { return }
        rememberPosition()
        guard retryTask == nil else { return }
        guard retries < 3 else { state = "Stopped after 3 retries. Tap Retry."; return }
        retries += 1
        state = "Reconnecting (\(retries)/3)"
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.replaceItem()
        }
    }
    private func rememberPosition() {
        guard channel?.live == false else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds > 0 { resumePosition = seconds }
    }
    private func checkForStall() {
        guard channel?.live == false, retryTask == nil, retries < 3,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              let since = waitingSince, Date().timeIntervalSince(since) >= 12 else { return }
        reconnect()
    }
    func retry() {
        rememberPosition()
        retryTask?.cancel(); retryTask = nil; retries = 0; diagnostic = ""; replaceItem()
    }
    func stop() {
        stallMonitor?.cancel(); stallMonitor = nil
        retryTask?.cancel(); retryTask = nil; detach()
        player.pause(); player.replaceCurrentItem(with: nil); channel = nil
        queue = []; series = nil; playing = false; elapsed = 0; duration = 0
        state = "Stopped"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct PlaybackView: View {
    let channel: Channel
    @ObservedObject private var playback = Playback.shared
    @State private var fullscreen = false
    @AppStorage("MahmoudTV.displayMode") private var displayMode = "Fit"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !fullscreen {
                        PlayerPanel(displayMode: $displayMode, fullscreen: $fullscreen, isFullscreen: false)
                            .frame(height: 300)
                    } else { Color.black.frame(height: 300) }
                    Text(playback.state).font(.headline)
                    if !playback.diagnostic.isEmpty { Text(playback.diagnostic).font(.footnote).padding(.horizontal) }
                    Button("Retry") { playback.retry() }.buttonStyle(.borderedProminent)
                    if playback.queue.count > 1 {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text(playback.series?.name ?? "Live channels").font(.title2.bold())
                            ForEach(playback.queue) { item in
                                Button {
                                    playback.open(item, queue: playback.queue, series: playback.series)
                                } label: {
                                    HStack {
                                        Image(systemName: item.id == playback.channel?.id ? "speaker.wave.2.fill" : "play.circle")
                                        Text(item.name).lineLimit(2)
                                        Spacer()
                                    }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                }.tint(item.id == playback.channel?.id ? .green : .primary)
                            }
                        }.padding(.horizontal)
                    }
                    Text(StreamLibrary.shared.carStatus).font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle(playback.channel?.name ?? channel.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Stop") { playback.stop(); dismiss() }
                Button("Close") { dismiss() }
            }
        }
        .fullScreenCover(isPresented: $fullscreen) {
            PlayerPanel(displayMode: $displayMode, fullscreen: $fullscreen, isFullscreen: true)
                .background(.black).preferredColorScheme(.dark)
        }
    }
}

struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .systemCyan
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
