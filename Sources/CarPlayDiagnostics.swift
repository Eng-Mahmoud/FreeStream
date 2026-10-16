import SwiftUI
import CarPlay

@MainActor
final class CarPlayDiagnostics: ObservableObject {
    static let shared = CarPlayDiagnostics()
    private static let eventsKey = "MahmoudTV.carPlayDiagnosticEvents"
    @Published private(set) var events: [String] = []
    @Published private(set) var connected = false
    @Published private(set) var receivedConnection = false
    @Published private(set) var requestedScene = false
    @Published private(set) var supportsVideo: Bool?
    @Published private(set) var signed = CarPlayPermissionReadout.unknown("Not inspected yet.")
    @Published private(set) var profile = CarPlayPermissionReadout.unknown("Not inspected yet.")
    @Published private(set) var manifestPresent = false
    @Published private(set) var delegateResolves = false
    @Published private(set) var iconMetadataPresent = false
    @Published private(set) var activeCarScenes = 0

    private init() {
        events = Array((UserDefaults.standard.stringArray(forKey: Self.eventsKey) ?? []).suffix(40))
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }
    var mode: String {
        Bundle.main.object(forInfoDictionaryKey: "MahmoudTVCarPlayTestMode") as? String ?? "standard"
    }
    var videoSDK: String {
        #if FREESTREAM_VIDEO_SDK
        return "Included"
        #else
        return "Not included; audio browsing can still be tested"
        #endif
    }
    var assessment: String {
        if connected { return "CarPlay connected. Open Connection test on the car to verify its interface." }
        if receivedConnection { return "CarPlay connected earlier this launch and is now disconnected. See the event log." }
        if !manifestPresent || !delegateResolves { return "CarPlay registration check failed. Share this report before changing signing." }
        if signed.audio == false && signed.video == false {
            return "The installed app's signature has neither CarPlay permission. iOS cannot use the source declarations as authorization."
        }
        if profile.audio == false && profile.video == false {
            return "The embedded profile lists neither CarPlay permission. Adding scene code cannot grant those permissions."
        }
        if signed.audio == true && profile.audio == false {
            return "The app requests CarPlay audio, but the embedded profile does not list it."
        }
        if requestedScene { return "iOS requested the CarPlay scene, but its connection callback has not arrived. Share the event log." }
        return "No CarPlay connection callback this launch. Connect to the car and check its app list; share the report if the icon is missing."
    }

    func refresh() {
        let bundle = Bundle.main
        if let url = bundle.executableURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            signed = CarPlayInstallationReader.signedPermissions(in: data)
        } else { signed = .unknown("Installed executable could not be read.") }
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            profile = CarPlayInstallationReader.profilePermissions(in: data)
        } else { profile = .unknown("No readable embedded provisioning profile is available.") }
        let manifest = bundle.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        let configurations = manifest?["UISceneConfigurations"] as? [String: Any]
        let carScenes = configurations?[UISceneSession.Role.carTemplateApplication.rawValue] as? [[String: Any]] ?? []
        manifestPresent = carScenes.contains { $0["UISceneClassName"] as? String == "CPTemplateApplicationScene" }
        delegateResolves = carScenes.contains {
            guard let name = $0["UISceneDelegateClassName"] as? String,
                  let type = NSClassFromString(name) else { return false }
            return ObjectIdentifier(type) == ObjectIdentifier(CarPlaySceneDelegate.self)
        }
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        iconMetadataPresent = primaryIcon?["CFBundleIconName"] as? String != nil
            || !(primaryIcon?["CFBundleIconFiles"] as? [String] ?? []).isEmpty
        activeCarScenes = UIApplication.shared.connectedScenes.filter { $0.session.role == .carTemplateApplication }.count
    }

    func appLaunched() {
        refresh()
        record("App launched: \(version); mode: \(mode).")
    }
    func sceneRequested() {
        requestedScene = true
        record("iOS requested the CarPlay scene configuration.")
    }
    func didConnect(supportsVideo: Bool?) {
        connected = true; receivedConnection = true; self.supportsVideo = supportsVideo
        record("CarPlay didConnect callback received.")
        record("Vehicle video capability: \(Self.capability(supportsVideo)).")
    }
    func didDisconnect() {
        connected = false
        record("CarPlay didDisconnect callback received.")
    }
    func record(_ message: String) {
        // Callers provide fixed lifecycle messages or numeric errors only.
        // Do not pass media names, URLs, profile contents, or account identifiers.
        let stamp = ISO8601DateFormatter().string(from: Date())
        events.append("\(stamp)  \(message)")
        if events.count > 40 { events.removeFirst(events.count - 40) }
        UserDefaults.standard.set(events, forKey: Self.eventsKey)
    }
    func clearEvents() {
        events = []
        UserDefaults.standard.removeObject(forKey: Self.eventsKey)
    }
    static func capability(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Present" : "Absent"
    }
    var report: String {
        var lines = [
            "MahmoudTV CarPlay connection test",
            "Version: \(version)", "Mode: \(mode)",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "CarPlay manifest: \(manifestPresent ? "Present" : "Missing")",
            "CarPlay delegate class: \(delegateResolves ? "Resolves" : "Not resolved")",
            "Icon metadata: \(iconMetadataPresent ? "Present" : "Not found")",
            "Signed audio: \(Self.capability(signed.audio))",
            "Signed video: \(Self.capability(signed.video))", signed.note,
            "Profile audio: \(Self.capability(profile.audio))",
            "Profile video: \(Self.capability(profile.video))", profile.note,
            "Video SDK: \(videoSDK)",
            "Scene requested this launch: \(requestedScene ? "Yes" : "No")",
            "Connection callback this launch: \(receivedConnection ? "Yes" : "No")",
            "Currently connected: \(connected ? "Yes" : "No")",
            "Connected car scenes at last refresh: \(activeCarScenes)",
            "Vehicle video capability: \(Self.capability(supportsVideo))",
            "Assessment: \(assessment)", "", "Recent events (may include earlier launches):"
        ]
        lines += events.isEmpty ? ["No events recorded."] : events
        return lines.joined(separator: "\n")
    }
}

@MainActor
struct CarPlayDiagnosticsView: View {
    @ObservedObject private var diagnostics = CarPlayDiagnostics.shared
    var body: some View {
        List {
            Section("Connection test") {
                LabeledContent("Version", value: diagnostics.version)
                LabeledContent("Build mode", value: diagnostics.mode)
                Text(diagnostics.assessment).font(.footnote)
                Button("Refresh checks") { diagnostics.refresh() }
                ShareLink(item: diagnostics.report) { Label("Share diagnostic report", systemImage: "square.and.arrow.up") }
            }
            Section("Registration") {
                LabeledContent("CarPlay scene", value: diagnostics.manifestPresent ? "Present" : "Missing")
                LabeledContent("Delegate class", value: diagnostics.delegateResolves ? "Resolves" : "Not resolved")
                LabeledContent("Icon metadata", value: diagnostics.iconMetadataPresent ? "Present" : "Not found")
                LabeledContent("Scene requested", value: diagnostics.requestedScene ? "Yes" : "No")
                LabeledContent("Connection callback", value: diagnostics.receivedConnection ? "Received" : "Not received")
                LabeledContent("Currently connected", value: diagnostics.connected ? "Yes" : "No")
            }
            Section("Installed signature") {
                LabeledContent("CarPlay audio", value: CarPlayDiagnostics.capability(diagnostics.signed.audio))
                LabeledContent("CarPlay video", value: CarPlayDiagnostics.capability(diagnostics.signed.video))
                Text(diagnostics.signed.note).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Embedded profile") {
                LabeledContent("CarPlay audio", value: CarPlayDiagnostics.capability(diagnostics.profile.audio))
                LabeledContent("CarPlay video", value: CarPlayDiagnostics.capability(diagnostics.profile.video))
                Text(diagnostics.profile.note).font(.footnote).foregroundStyle(.secondary)
                Text("These checks read the installed files. They do not grant permissions or independently verify the profile's signature.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Video capability") {
                LabeledContent("Video SDK", value: diagnostics.videoSDK)
                LabeledContent("Vehicle", value: CarPlayDiagnostics.capability(diagnostics.supportsVideo))
                Text("The audio-only icon test checks browsing first. It does not enable car video.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Recent events") {
                Text(diagnostics.events.isEmpty ? "No events recorded." : diagnostics.events.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Clear event log", role: .destructive) { diagnostics.clearEvents() }
            }
        }
        .navigationTitle("CarPlay connection test")
        .onAppear { diagnostics.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in diagnostics.refresh() }
    }
}
