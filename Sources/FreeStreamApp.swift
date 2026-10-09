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
        retryTask?.cancel(); retryTask = nil
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

    func open(_ channel: Channel, queue: [Channel]? = nil, series: Series? = nil) {
        self.queue = queue ?? (channel.live ? StreamLibrary.shared.items.filter { $0.live } : [channel])
        self.series = series
        elapsed = 0; duration = 0
        retryTask?.cancel(); retryTask = nil; diagnostic = ""
        self.channel = channel; retries = 0; recoveryExhausted = false; eventLog = []
        let ext = channel.url.pathExtension.lowercased()
        let format = ["m3u8", "ts", "mp4", "mkv", "mov", "m4v", "avi"].contains(ext) ? ext : "other"
        record("Opened " + (channel.live ? "live" : "VOD") + " • " + format)
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
        state = "Connecting"
        let item = AVPlayerItem(url: channel.url)
        item.preferredForwardBufferDuration = channel.live ? 8 : 15
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.captureFailure(item, error: item.error as NSError?)
                    self.reconnect()
                }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                guard self.retryTask == nil, item.status != .failed, !self.recoveryExhausted else { return }
                switch player.timeControlStatus {
                case .playing: self.playing = true; self.state = "Playing"
                case .waitingToPlayAtSpecifiedRate:
                    self.playing = false
                    self.state = "Buffering"
                case .paused: self.playing = false; self.state = "Paused"
                @unknown default: self.state = "Unknown"
                }
                self.record(self.state)
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if self.channel?.live == true { self.reconnect() } else { self.state = "Finished" }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.captureFailure(item, error: error ?? item.error as NSError?)
                self.reconnect()
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.record("Stream stalled; waiting for the existing connection")
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item,
                      let event = item.errorLog()?.events.last else { return }
                self.diagnostic = "Stream error code: \(event.errorStatusCode)"
                self.record(self.diagnostic)
            }
        })
        player.play()
        publishNowPlaying()
    }
    private var recoveryExhausted = false
    @Published private(set) var eventLog: [String] = []
    private func record(_ message: String) {
        // Messages below contain only state, format and numeric codes; never URLs or credentials.
        let seconds = player.currentTime().seconds
        let position = seconds.isFinite ? String(format: "%.1fs", seconds) : "--"
        eventLog.append("[\(position)] \(message)")
        if eventLog.count > 24 { eventLog.removeFirst(eventLog.count - 24) }
    }
    private func captureFailure(_ item: AVPlayerItem, error: NSError?) {
        var codes: [String] = []
        var current = error
        for _ in 0..<4 {
            guard let value = current else { break }
            let allowed = ["AVFoundationErrorDomain", "NSURLErrorDomain", "NSOSStatusErrorDomain", "CoreMediaErrorDomain"]
            let domain = allowed.contains(value.domain) ? value.domain : "Player"
            codes.append("\(domain): \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let event = item.errorLog()?.events.last { codes.append("Stream: \(event.errorStatusCode)") }
        diagnostic = codes.isEmpty ? "Playback failed without an error code." : codes.joined(separator: " • ")
        record(diagnostic)
    }
    private func reconnect() {
        guard channel != nil, !recoveryExhausted else { return }
        // Match the earlier working release: only live playback automatically reconnects.
        // VOD waits for an explicit Retry, with no timer and no seek back into the failed range.
        guard channel?.live == true else {
            recoveryExhausted = true; playing = false
            state = "Playback failed. Tap Retry to restart."
            player.pause()
            record(state)
            return
        }
        guard retryTask == nil else { return }
        guard retries < 3 else {
            recoveryExhausted = true; playing = false
            state = "Stopped after 3 retries. Tap Retry."
            player.pause(); record(state)
            return
        }
        retries += 1
        state = "Reconnecting (\(retries)/3)"
        record(state)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.replaceItem()
        }
    }
    func retry() {
        retryTask?.cancel(); retryTask = nil; retries = 0; recoveryExhausted = false
        record("Manual restart from beginning")
        replaceItem()
    }
    func stop() {
        retryTask?.cancel(); retryTask = nil; detach()
        player.pause(); player.replaceCurrentItem(with: nil); channel = nil
        queue = []; series = nil; playing = false; elapsed = 0; duration = 0
        recoveryExhausted = false
        state = "Stopped"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct PlaybackView: View {
    let channel: Channel
    @ObservedObject private var playback = Playback.shared
    @State private var fullscreen = false
    @ObservedObject private var favorites = Favorites.shared
    @Environment(\.dismiss) private var dismiss
    private var isFavorite: Bool {
        if let show = playback.series { return favorites.contains(show) }
        if let item = playback.channel { return favorites.contains(item) }
        return false
    }
    private var playbackActions: some View {
        HStack(spacing: 24) {
            Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                .disabled(!playback.canGoPrevious).accessibilityLabel("Previous")
            FavoriteButton(selected: isFavorite) {
                if let show = playback.series { favorites.toggle(show) }
                else if let item = playback.channel { favorites.toggle(item) }
            }
            Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                .disabled(!playback.canGoNext).accessibilityLabel("Next")
            AirPlayPicker().frame(width: 32, height: 32)
            Button { fullscreen.toggle() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.accessibilityLabel("Toggle fullscreen")
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !fullscreen {
                        VideoPlayer(player: playback.player)
                            .frame(height: 300)
                    } else { Color.black.frame(height: 300) }
                    playbackActions
                    Text(playback.state).font(.headline)
                    if !playback.diagnostic.isEmpty { Text(playback.diagnostic).font(.footnote).padding(.horizontal) }
                    Button("Retry from beginning") { playback.retry() }.buttonStyle(.borderedProminent)
                    DisclosureGroup("Playback details • 0.3.2") {
                        Text(playback.eventLog.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.horizontal)
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
            VStack {
                HStack { Spacer(); Button("Done") { fullscreen = false } }.padding(.horizontal)
                VideoPlayer(player: playback.player)
                playbackActions.padding(.bottom)
            }.background(.black).preferredColorScheme(.dark)
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
