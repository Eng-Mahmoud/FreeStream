import SwiftUI
import AVKit

@main
struct FreeStreamApp: App {
    var body: some Scene { WindowGroup { HomeView().preferredColorScheme(.dark) } }
}

struct HomeView: View {
    @State private var credentials = Vault.load()
    @State private var source = 0
    @State private var movies = false
    @State private var hls = true
    @State private var playlist = ""
    @State private var items: [Channel] = []
    @State private var search = ""
    @State private var busy = false
    @State private var message = ""
    @State private var selected: Channel?
    @State private var remember = false
    var visible: [Channel] { items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            List {
                Section("Source") {
                    Picker("Type", selection: $source) {
                        Text("Xtream").tag(0)
                        Text("M3U URL").tag(1)
                    }.pickerStyle(.segmented)
                    if source == 0 {
                        TextField("Server URL, including port", text: $credentials.server)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Username", text: $credentials.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $credentials.password)
                        Toggle("Movies instead of live channels", isOn: $movies)
                        if !movies { Toggle("Use HLS (.m3u8)", isOn: $hls) }
                        Toggle("Remember credentials in Keychain", isOn: $remember)
                    } else {
                        SecureField("Provider M3U playlist URL", text: $playlist)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button(busy ? "Loading…" : "Load catalog") { Task { await load() } }
                        .disabled(busy)
                    Button("Forget saved login", role: .destructive) {
                        Vault.clear(); credentials = Credentials(); items = []; remember = false
                    }.disabled(busy)
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                Section("\(visible.count) items") {
                    ForEach(visible) { item in
                        Button { selected = item } label: {
                            HStack {
                                Image(systemName: item.live ? "tv" : "film").foregroundStyle(.cyan)
                                VStack(alignment: .leading) {
                                    Text(item.name).foregroundStyle(.primary)
                                    if !item.group.isEmpty { Text(item.group).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").foregroundStyle(.cyan)
                            }
                        }
                    }
                }
                Section {
                    Text("Prototype 0.1 • Native iPhone playback and AirPlay. No native CarPlay app icon or full-screen mirroring. Test car video only while parked. Series, EPG and favorites are planned.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("FreeStream")
            .searchable(text: $search, prompt: "Search names or groups")
            .sheet(item: $selected) { item in PlaybackView(channel: item) }
        }
    }
    @MainActor private func load() async {
        busy = true; message = ""; items = []
        defer { busy = false }
        do {
            if source == 0 {
                items = try await Catalog.xtream(credentials, movie: movies, hls: hls)
                if remember { try Vault.save(credentials) }
                else { Vault.clear() }
            } else {
                let raw = playlist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw CatalogError.invalidURL }
                let data = try await Catalog.fetch(url)
                guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else { throw CatalogError.malformed }
                items = Catalog.m3u(text, base: url)
            }
            if items.isEmpty { message = "No items returned. Check your provider's catalog or selected source." }
        } catch {
            // Avoid localized network errors: these can disclose URLs containing passwords.
            message = (error as? CatalogError)?.errorDescription ?? "Could not load catalog. Check network, server URL and login."
        }
    }
}

@MainActor
final class Playback: ObservableObject {
    let player = AVPlayer()
    @Published var state = "Preparing"
    @Published var diagnostic = ""
    private var channel: Channel?
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var retries = 0
    private var retryTask: Task<Void, Never>?

    func open(_ channel: Channel) {
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct PlaybackView: View {
    let channel: Channel
    @StateObject private var playback = Playback()
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
                Text("AirPlay targets depend on the receiver. A working CarTV connection does not guarantee this prototype can send video to your Kia.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                Spacer()
            }
            .navigationTitle(channel.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Close") { dismiss() } }
        }
        .onAppear { playback.open(channel) }
        .onDisappear { playback.stop() }
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
