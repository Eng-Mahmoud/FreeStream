import UIKit
import CarPlay
import Combine
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: session.role)
            config.sceneClass = CPTemplateApplicationScene.self
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSearchTemplateDelegate, CPSessionConfigurationDelegate {
    private var controller: CPInterfaceController?
    private var session: CPSessionConfiguration?
    private var subscriptions = Set<AnyCancellable>()
    private var searchEntries: [CPListItem] = []
    private var supportsVideo = false

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        session = CPSessionConfiguration(delegate: self)
        #if FREESTREAM_VIDEO_SDK
        if #available(iOS 27.0, *) { supportsVideo = session?.supportsVideoPlayback == true }
        #endif
        StreamLibrary.shared.carStatus = supportsVideo
            ? "CarPlay connected • video supported; availability follows vehicle policy."
            : "CarPlay connected • audio mode. Video capability unavailable or SDK support absent."
        showRoot()
        StreamLibrary.shared.$items.combineLatest(StreamLibrary.shared.$series)
            .dropFirst().sink { [weak self] _, _ in self?.showRoot() }.store(in: &subscriptions)
    }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        subscriptions.removeAll(); controller = nil; session = nil; searchEntries = []
        StreamLibrary.shared.carStatus = "CarPlay disconnected."
        // Playback belongs to the app, not to the lifetime of either screen.
    }
    private func row(_ title: String, detail: String = "", action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        item.handler = { _, completion in action(); completion() }
        return item
    }
    private func showRoot() {
        let library = StreamLibrary.shared
        let rows = [
            row("All content", detail: "Live TV, movies and series") { [weak self] in self?.showAll() },
            row("Live TV", detail: "\(library.items.filter(\.live).count) channels") { [weak self] in self?.showChannels(library.items.filter(\.live), title: "Live TV") },
            row("Movies", detail: "\(library.items.filter { !$0.live }.count) movies") { [weak self] in self?.showChannels(library.items.filter { !$0.live }, title: "Movies") },
            row("Series", detail: "\(library.series.count) series") { [weak self] in self?.showSeries(library.series) },
            row("Search", detail: "Channels, movies and series") { [weak self] in
                guard let self else { return }
                let search = CPSearchTemplate(); search.delegate = self
                self.controller?.pushTemplate(search, animated: true, completion: nil)
            },
            row("Now Playing", detail: Playback.shared.channel?.name ?? "Nothing playing") { [weak self] in
                guard Playback.shared.channel != nil else { return }
                self?.controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            }
        ]
        let section = CPListSection(items: rows, header: library.items.isEmpty && library.series.isEmpty
            ? "Load a catalog on iPhone first" : (supportsVideo ? "Video supported when available" : "Audio mode"), sectionIndexTitle: nil)
        controller?.setRootTemplate(CPListTemplate(title: "MahmoudTV", sections: [section]), animated: false, completion: nil)
    }
    private func channelRow(_ channel: Channel) -> CPListItem {
        let item = row(channel.name, detail: channel.group) { [weak self] in
            Playback.shared.open(channel)
            // Video presentation is managed by CarPlay; no custom car window or policy bypass.
            if self?.supportsVideo != true {
                self?.controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            }
        }
        item.isPlaying = Playback.shared.channel?.id == channel.id
        #if FREESTREAM_VIDEO_SDK
        if #available(iOS 27.0, *) {
            item.playbackConfiguration = CPPlaybackConfiguration(
                preferredPresentation: supportsVideo ? .video : .audio,
                playbackAction: .play, elapsedTime: .zero, duration: .zero)
        }
        #endif
        return item
    }
    private var pageSize: Int { max(1, min(80, CPListTemplate.maximumItemCount - 1)) }
    private func showChannels(_ channels: [Channel], title: String, offset: Int = 0) {
        var rows = channels.dropFirst(offset).prefix(pageSize).map(channelRow)
        if offset + pageSize < channels.count {
            rows.append(row("More…") { [weak self] in self?.showChannels(channels, title: title, offset: offset + (self?.pageSize ?? 80)) })
        }
        if rows.isEmpty { rows = [row("No items", detail: "Load this catalog on iPhone") {}] }
        presentPage(rows, title: title, offset: offset)
    }
    private func seriesRow(_ series: Series) -> CPListItem {
        let item = CPListItem(text: series.name, detailText: "Series • \(series.group)")
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                defer { completion() }
                do {
                    let episodes = try await Catalog.episodes(series)
                    self?.showChannels(episodes, title: series.name)
                } catch {
                    self?.controller?.pushTemplate(CPListTemplate(title: "Episodes unavailable", sections: [CPListSection(items: [CPListItem(text: "Check provider and network", detailText: "Try again later")])]), animated: true, completion: nil)
                }
            }
        }
        return item
    }
    private func showSeries(_ series: [Series], offset: Int = 0) {
        var rows = series.dropFirst(offset).prefix(pageSize).map(seriesRow)
        if offset + pageSize < series.count {
            rows.append(row("More…") { [weak self] in self?.showSeries(series, offset: offset + (self?.pageSize ?? 80)) })
        }
        if rows.isEmpty { rows = [row("No series", detail: "Load Xtream catalog on iPhone") {}] }
        presentPage(rows, title: "Series", offset: offset)
    }
    private func presentPage(_ rows: [CPListItem], title: String, offset: Int) {
        let sections = [CPListSection(items: rows)]
        if offset > 0, let template = controller?.topTemplate as? CPListTemplate {
            template.updateSections(sections)
        } else {
            controller?.pushTemplate(CPListTemplate(title: title, sections: sections), animated: true, completion: nil)
        }
    }
    private func showAll(offset: Int = 0) {
        let library = StreamLibrary.shared
        let total = library.items.count + library.series.count
        let end = min(total, offset + pageSize)
        var rows: [CPListItem] = []
        if offset < end {
            for index in offset..<end {
                if index < library.items.count { rows.append(channelRow(library.items[index])) }
                else { rows.append(seriesRow(library.series[index - library.items.count])) }
            }
        }
        if end < total { rows.append(row("More…") { [weak self] in self?.showAll(offset: end) }) }
        if rows.isEmpty { rows = [row("No content", detail: "Load your source on iPhone") {}] }
        presentPage(rows, title: "All content", offset: offset)
    }
    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        let library = StreamLibrary.shared
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchEntries = []; completionHandler([]); return
        }
        let channels = library.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.group.localizedCaseInsensitiveContains(searchText) }
        let series = library.series.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.group.localizedCaseInsensitiveContains(searchText) }
        searchEntries = Array((channels.prefix(pageSize).map(channelRow) + series.prefix(pageSize).map(seriesRow)).prefix(pageSize))
        completionHandler(searchEntries)
    }
    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        if let handler = item.handler { handler(item, completionHandler) } else { completionHandler() }
    }
    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        controller?.pushTemplate(CPListTemplate(title: "Search results", sections: [CPListSection(items: searchEntries)]), animated: true, completion: nil)
    }
}
