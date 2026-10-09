import SwiftUI
import AVKit

struct PlayerPanel: View {
    @Binding var displayMode: String
    @Binding var fullscreen: Bool
    let isFullscreen: Bool
    @ObservedObject private var playback = Playback.shared
    @ObservedObject private var favorites = Favorites.shared
    @State private var controlsVisible = true
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    private let modes = ["Fit", "Fill", "Stretch", "16:9", "4:3", "21:9", "19:6"]
    private var gravity: AVLayerVideoGravity {
        switch displayMode {
        case "Fill": return .resizeAspectFill
        case "Fit": return .resizeAspect
        default: return .resize
        }
    }
    private var ratio: CGFloat? {
        switch displayMode {
        case "16:9": return 16.0 / 9
        case "4:3": return 4.0 / 3
        case "21:9": return 21.0 / 9
        case "19:6": return 19.0 / 6
        default: return nil
        }
    }
    private var isFavorite: Bool {
        if let series = playback.series { return favorites.contains(series) }
        if let channel = playback.channel { return favorites.contains(channel) }
        return false
    }
    private func toggleFavorite() {
        if let series = playback.series { favorites.toggle(series) }
        else if let channel = playback.channel { favorites.toggle(channel) }
    }
    private func clock(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(value)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                let available = geometry.size
                let width = ratio.map { min(available.width, available.height * $0) } ?? available.width
                let height = ratio.map { width / $0 } ?? available.height
                PlayerSurface(player: playback.player, gravity: gravity)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { controlsVisible.toggle() } }
                if controlsVisible {
                    VStack(spacing: 12) {
                        HStack {
                            Text(playback.channel?.name ?? "MahmoudTV").font(.headline).lineLimit(1)
                            Spacer(minLength: 8)
                            FavoriteButton(selected: isFavorite, action: toggleFavorite)
                            if isFullscreen {
                                Button { fullscreen = false } label: { Image(systemName: "xmark").padding(10) }
                                    .accessibilityLabel("Exit fullscreen")
                            }
                        }
                        Spacer()
                        if playback.state == "Buffering" || playback.state == "Connecting" || playback.state.hasPrefix("Reconnecting") {
                            HStack { ProgressView(); Text(playback.state).font(.caption) }
                        }
                        if playback.channel?.live == false, playback.duration > 0 {
                            HStack {
                                Text(clock(scrubbing ? scrubPosition : playback.elapsed)).font(.caption.monospacedDigit())
                                Slider(value: Binding(get: {
                                    scrubbing ? scrubPosition : min(playback.elapsed, playback.duration)
                                }, set: { scrubPosition = $0 }), in: 0...max(1, playback.duration)) { editing in
                                    if editing { scrubPosition = playback.elapsed; scrubbing = true }
                                    else { playback.seek(scrubPosition); scrubbing = false }
                                }.accessibilityLabel("Playback position")
                                Text(clock(playback.duration)).font(.caption.monospacedDigit())
                            }
                        }
                        HStack(spacing: 16) {
                            Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                                .disabled(!playback.canGoPrevious).accessibilityLabel("Previous episode or channel")
                            Button { playback.togglePause() } label: {
                                Image(systemName: playback.playing || playback.state == "Buffering" ? "pause.fill" : "play.fill")
                            }.accessibilityLabel(playback.playing ? "Pause" : "Play")
                            Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                                .disabled(!playback.canGoNext).accessibilityLabel("Next episode or channel")
                            Spacer(minLength: 0)
                            Menu {
                                Picker("Video size", selection: $displayMode) {
                                    ForEach(modes, id: \.self) { Text($0).tag($0) }
                                }
                            } label: { Text(displayMode).font(.caption.bold()) }
                                .accessibilityLabel("Video size: \(displayMode)")
                            AirPlayPicker().frame(width: 30, height: 30)
                            Button { fullscreen.toggle() } label: {
                                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            }.accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Fullscreen")
                        }.font(.title3)
                    }.padding().background {
                        LinearGradient(colors: [.black.opacity(0.65), .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
                }
            }.foregroundStyle(.white)
        }
        .onChange(of: playback.channel?.id) { _, _ in scrubbing = false; controlsVisible = true }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }
    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) { view.playerLayer.player = nil }
}
