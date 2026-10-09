import SwiftUI
import AVKit

// Presentation only. This view never opens a URL, replaces a player item,
// seeks, starts/stops playback, changes buffering, or schedules recovery.
enum VideoDisplayMode: String, CaseIterable, Identifiable {
    case fit = "Fit", fill = "Fill", stretch = "Stretch"
    case wide = "16:9", classic = "4:3", cinema = "21:9", ultrawide = "19:6"
    var id: String { rawValue }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        default: return .resize
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .wide: return 16.0 / 9.0
        case .classic: return 4.0 / 3.0
        case .cinema: return 21.0 / 9.0
        case .ultrawide: return 19.0 / 6.0
        default: return nil
        }
    }
}

struct NativeVideoView: View {
    let player: AVPlayer
    let mode: VideoDisplayMode
    var body: some View {
        GeometryReader { geometry in
            let width = mode.ratio.map { min(geometry.size.width, geometry.size.height * $0) } ?? geometry.size.width
            let height = mode.ratio.map { width / $0 } ?? geometry.size.height
            ZStack {
                Color.black
                NativeVideoController(player: player, gravity: mode.gravity)
                    .frame(width: max(0, width), height: max(0, height))
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

private struct NativeVideoController: UIViewControllerRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.updatesNowPlayingInfoCenter = false
        controller.videoGravity = gravity
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Preserve controller/player identity when a mode changes or the clock ticks.
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil // Detach this view; never pause the shared player.
    }
}
