import SwiftUI
import AVKit
import MediaPlayer

@main
struct FreeStreamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { HomeView().preferredColorScheme(.dark) } }
}

struct HomeView: View {
    @StateObject private var library = StreamLibrary.shared
    @ObservedObject private var playback = Playback.shared
    @State private var credentials = Vault.load()
    @State private var source = 0
    @State private var hls = true
    @State private var playlist = ""
    @State private var search = ""
    @State private var filter = "All"
    @State private var busy = false
    @State private var message = ""
    @State private var settings = false
    @State private var selected: Channel?
    @State private var selectedSeries: Series?
    @State private var remember = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]
    private func matches(_ name: String, _ group: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search) || group.localizedCaseInsensitiveContains(search)
    }
    private var channels: [Channel] {
        library.items.filter { matches($0.name, $0.group) && (filter == "All" || (filter == "Live" && $0.live) || (filter == "Movies" && !$0.live)) }
    }
    private var shows: [Series] {
        library.series.filter { (filter == "All" || filter == "Series") && matches($0.name, $0.group) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Your entertainment").font(.largeTitle.bold())
                            Text("Live TV, movies and series in one place").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if busy { ProgressView() }
                    }
                    Picker("Content", selection: $filter) {
                        ForEach(["All", "Live", "Movies", "Series"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    if !message.isEmpty { Text(message).foregroundStyle(.orange).font(.footnote) }
                    if library.items.isEmpty && library.series.isEmpty {
                        ContentUnavailableView("Add your media source", systemImage: "play.rectangle", description: Text("Open Sources to load live channels, movies and series."))
                        Button("Sources") { settings = true }.buttonStyle(.borderedProminent)
                    }
                    Text("\(channels.count + shows.count) results").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(channels) { item in
                            Button { playback.open(item); selected = item } label: {
                                MediaCard(name: item.name, subtitle: item.group, kind: item.live ? "LIVE" : "MOVIE", symbol: item.live ? "tv" : "film", artwork: item.artwork)
                            }.buttonStyle(.plain)
                        }
                        ForEach(shows) { show in
                            Button { selectedSeries = show } label: {
                                MediaCard(name: show.name, subtitle: show.group, kind: "SERIES", symbol: "rectangle.stack", artwork: show.artwork)
                            }.buttonStyle(.plain)
                        }
                    }
                    Text(library.carStatus).font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .background(Color(red: 0.035, green: 0.045, blue: 0.075))
            .navigationTitle("MahmoudTV")
            .searchable(text: $search, prompt: "Search live TV, movies and series")
            .toolbar { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") } }
            .safeAreaInset(edge: .bottom) {
                if let current = playback.channel {
                    HStack {
                        Button { selected = current } label: {
                            VStack(alignment: .leading) { Text(current.name).lineLimit(1); Text(playback.state).font(.caption) }
                        }
                        Spacer()
                        Button { if playback.player.rate == 0 { playback.player.play() } else { playback.player.pause() } } label: { Image(systemName: playback.player.rate == 0 ? "play.fill" : "pause.fill") }
                        Button { playback.stop() } label: { Image(systemName: "stop.fill") }
                    }.padding().background(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: $settings) {
                NavigationStack {
                    Form {
                        Section("Source") {
                            Picker("Type", selection: $source) { Text("Xtream").tag(0); Text("M3U URL").tag(1) }.pickerStyle(.segmented)
                            if source == 0 {
                                TextField("Server URL, including port", text: $credentials.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                TextField("Username", text: $credentials.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                                SecureField("Password", text: $credentials.password)
                                Toggle("Use HLS for live TV", isOn: $hls)
                                Toggle("Remember login in Keychain", isOn: $remember)
                            } else {
                                SecureField("M3U playlist URL", text: $playlist).textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                            Button(busy ? "Loading…" : "Load all content") { Task { await load() } }.disabled(busy)
                            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.orange) }
                        }
                        Section("CarPlay") {
                            Toggle("Save catalog for access from car", isOn: $library.rememberCatalog)
                            Text(library.carStatus).font(.footnote)
                            Text("Saved catalogs include stream credentials and are stored in this device’s Keychain. Series episode lists require a network connection. Video availability is controlled by CarPlay.").font(.footnote)
                        }
                        Section {
                            Button("Forget login and catalog", role: .destructive) { Vault.clear(); library.clear(); credentials = Credentials(); remember = false; playback.stop() }.disabled(busy)
                        }
                    }.navigationTitle("Sources").toolbar { Button("Done") { settings = false } }
                }
            }
            .sheet(item: $selected) { PlaybackView(channel: $0) }
            .sheet(item: $selectedSeries) { SeriesView(series: $0) }
        }.tint(.cyan)
    }
    @MainActor private func load() async {
        busy = true; message = ""
        defer { busy = false }
        do {
            if source == 0 {
                // Each catalog can fail independently; keep the successful content types.
                var loaded: [Channel] = []; var shows: [Series] = []; var missing: [String] = []
                async let live = Catalog.xtream(credentials, movie: false, hls: hls)
                async let movies = Catalog.xtream(credentials, movie: true, hls: hls)
                async let series = Catalog.series(credentials)
                do { loaded += try await live } catch { missing.append("live TV") }
                do { loaded += try await movies } catch { missing.append("movies") }
                do { shows = try await series } catch { missing.append("series") }
                guard !loaded.isEmpty || !shows.isEmpty else { throw CatalogError.rejected }
                if remember { try Vault.save(credentials) } else { Vault.clear() }
                library.replace(loaded, series: shows)
                if !missing.isEmpty { message = "Could not load: " + missing.joined(separator: ", ") }
            } else {
                let raw = playlist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw CatalogError.invalidURL }
                let data = try await Catalog.fetch(url)
                guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else { throw CatalogError.malformed }
                library.replace(Catalog.m3u(text, base: url))
                message = "M3U items appear as live TV. Use Xtream for movies and series catalogs."
            }
        } catch { message = (error as? CatalogError)?.errorDescription ?? "Could not load catalog. Check network and login." }
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
            }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(name).font(.headline).lineLimit(2).frame(height: 44, alignment: .topLeading)
            Text(subtitle.isEmpty ? kind.capitalized : subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(10).background(.white.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SeriesView: View {
    let series: Series
    @State private var episodes: [Channel] = []
    @State private var episodeMessage = ""
    @State private var loading = true
    @State private var search = ""
    @State private var selected: Channel?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Loading episodes") }
                if !episodeMessage.isEmpty { Text(episodeMessage).foregroundStyle(.orange) }
                ForEach(episodes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }) { episode in
                    Button { Playback.shared.open(episode); selected = episode } label: {
                        VStack(alignment: .leading) { Text(episode.name); Text(episode.group).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.navigationTitle(series.name).searchable(text: $search, prompt: "Search episodes or seasons")
                .toolbar { Button("Done") { dismiss() } }
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
        register(center.pauseCommand) { [weak self] in self?.player.pause() }
        register(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            if self.player.rate == 0 { self.player.play() } else { self.player.pause() }
        }
        register(center.stopCommand) { [weak self] in self?.stop() }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishNowPlaying() }
        }
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
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var retries = 0
    private var retryTask: Task<Void, Never>?

    func open(_ channel: Channel) {
        retryTask?.cancel(); retryTask = nil; diagnostic = ""
        self.channel = channel; retries = 0
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
                    if let error = item.error as NSError? {
                        self.diagnostic = "Player error: \(error.domain), code \(error.code). Try HLS for live TV; VOD may use an unsupported codec."
                    }
                    self.reconnect()
                }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing: self.state = "Playing"
                case .waitingToPlayAtSpecifiedRate: self.state = "Buffering"
                case .paused: self.state = "Paused"
                @unknown default: self.state = "Unknown"
                }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.channel?.live == true { self.reconnect() } else { self.state = "Finished" }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconnect() }
        })
        player.play()
        publishNowPlaying()
    }
    private func reconnect() {
        guard channel?.live == true else { state = "Playback failed"; return }
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
    func retry() { retryTask?.cancel(); retryTask = nil; retries = 0; diagnostic = ""; replaceItem() }
    func stop() {
        retryTask?.cancel(); retryTask = nil; detach()
        player.pause(); player.replaceCurrentItem(with: nil); channel = nil
        state = "Stopped"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct PlaybackView: View {
    let channel: Channel
    @ObservedObject private var playback = Playback.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: playback.player).frame(minHeight: 240)
                Text(playback.state).font(.headline)
                if !playback.diagnostic.isEmpty { Text(playback.diagnostic).font(.footnote).padding(.horizontal) }
                HStack {
                    Button("Retry") { playback.retry() }.buttonStyle(.borderedProminent)
                    AirPlayPicker().frame(width: 44, height: 44)
                }
                Text(StreamLibrary.shared.carStatus)
                    .font(.footnote).foregroundStyle(.secondary).padding()
                Spacer()
            }
            .navigationTitle(playback.channel?.name ?? channel.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Stop") { playback.stop(); dismiss() }
                Button("Close") { dismiss() } }
        }
        .onAppear { if playback.channel?.id != channel.id { playback.open(channel) } }
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
