import SwiftUI

struct MediaGroup: Identifiable {
    enum Kind: String {
        case live, movie, series
        var filterName: String {
            switch self { case .live: return "Live"; case .movie: return "Movies"; case .series: return "Series" }
        }
    }
    let id: String
    let name: String
    let kind: Kind
    var channels: [Channel]
    var shows: [Series]
    var count: Int { channels.count + shows.count }
    static func make(items: [Channel], shows: [Series]) -> [MediaGroup] {
        var result: [MediaGroup] = []
        var indices: [String: Int] = [:]
        func index(kind: Kind, categoryID: String?, name: String) -> Int {
            let identity = categoryID.map { "id:\($0)" } ?? "name:\(name)"
            let key = kind.rawValue + "|" + identity
            if let existing = indices[key] { return existing }
            let next = result.count
            indices[key] = next
            result.append(MediaGroup(id: key, name: name.isEmpty ? "Uncategorized" : name, kind: kind, channels: [], shows: []))
            return next
        }
        // First appearance follows the provider catalog. Keep each media type separate.
        for item in items {
            let groupIndex = index(kind: item.live ? .live : .movie, categoryID: item.categoryID, name: item.group)
            result[groupIndex].channels.append(item)
        }
        for show in shows {
            let groupIndex = index(kind: .series, categoryID: show.categoryID, name: show.group)
            result[groupIndex].shows.append(show)
        }
        return result
    }
}

struct ChannelTile: View {
    let item: Channel
    let play: () -> Void
    @ObservedObject private var favorites = Favorites.shared
    var body: some View {
        Button(action: play) {
            MediaCard(name: item.name, subtitle: item.group, kind: item.live ? "LIVE" : "MOVIE", symbol: item.live ? "tv" : "film", artwork: item.artwork)
        }.buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                FavoriteButton(selected: favorites.contains(item)) { favorites.toggle(item) }.padding(5)
            }
    }
}

struct SeriesTile: View {
    let show: Series
    let open: () -> Void
    @ObservedObject private var favorites = Favorites.shared
    var body: some View {
        Button(action: open) {
            MediaCard(name: show.name, subtitle: show.group, kind: "SERIES", symbol: "rectangle.stack", artwork: show.artwork)
        }.buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                FavoriteButton(selected: favorites.contains(show)) { favorites.toggle(show) }.padding(5)
            }
    }
}

struct MediaGroupRow: View {
    let group: MediaGroup
    let favoritesOnly: Bool
    let play: (Channel) -> Void
    let openSeries: (Series) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                GroupBrowser(kind: group.kind, initialGroupID: group.id, favoritesOnly: favoritesOnly)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name).font(.title2.bold()).lineLimit(2)
                        Text(group.kind.filterName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(group.count)").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(group.channels.prefix(12))) { item in
                        ChannelTile(item: item) { play(item) }.frame(width: item.live ? 215 : 155)
                    }
                    ForEach(Array(group.shows.prefix(12))) { show in
                        SeriesTile(show: show) { openSeries(show) }.frame(width: 155)
                    }
                    if group.count > 12 {
                        NavigationLink {
                            GroupBrowser(kind: group.kind, initialGroupID: group.id, favoritesOnly: favoritesOnly)
                        } label: {
                            VStack { Image(systemName: "folder").font(.largeTitle); Text("View all \(group.count)") }
                                .frame(width: 140, height: group.kind == .live ? 180 : 275)
                        }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

struct GroupBrowser: View {
    let kind: MediaGroup.Kind
    let favoritesOnly: Bool
    @State private var selectedGroupID: String
    @State private var search = ""
    @State private var selected: Channel?
    @State private var selectedSeries: Series?
    @ObservedObject private var library = StreamLibrary.shared
    @ObservedObject private var favorites = Favorites.shared
    init(kind: MediaGroup.Kind, initialGroupID: String, favoritesOnly: Bool) {
        self.kind = kind; self.favoritesOnly = favoritesOnly
        _selectedGroupID = State(initialValue: initialGroupID)
    }
    private var groups: [MediaGroup] {
        MediaGroup.make(items: library.items, shows: library.series).compactMap { group in
            guard group.kind == kind else { return nil }
            var filtered = group
            if favoritesOnly {
                filtered.channels = group.channels.filter { favorites.contains($0) }
                filtered.shows = group.shows.filter { favorites.contains($0) }
            }
            return filtered.count == 0 ? nil : filtered
        }
    }
    private var activeGroup: MediaGroup? { groups.first { $0.id == selectedGroupID } ?? groups.first }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(groups) { group in
                                Button { selectedGroupID = group.id } label: {
                                    Text(group.name).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10)
                                        .background(activeGroup?.id == group.id ? Color.green : Color.white.opacity(0.1), in: Capsule())
                                        .foregroundStyle(activeGroup?.id == group.id ? Color.black : Color.white)
                                }.buttonStyle(.plain).id(group.id)
                            }
                        }
                    }.onAppear { reader.scrollTo(selectedGroupID, anchor: .center) }
                }
                if let group = activeGroup {
                    Text("\(group.count) \(kind.filterName.lowercased())").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(group.channels.filter { matches($0.name) }) { item in
                            ChannelTile(item: item) {
                                Playback.shared.open(item, queue: item.live ? group.channels : [item]); selected = item
                            }
                        }
                        ForEach(group.shows.filter { matches($0.name) }) { show in
                            SeriesTile(show: show) { selectedSeries = show }
                        }
                    }
                    if !search.isEmpty && !group.channels.contains(where: { matches($0.name) }) && !group.shows.contains(where: { matches($0.name) }) {
                        ContentUnavailableView("No results", systemImage: "magnifyingglass")
                    }
                } else {
                    ContentUnavailableView("No items", systemImage: "folder")
                }
            }.padding()
        }
        .navigationTitle(activeGroup?.name ?? kind.filterName).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search this group")
        .sheet(item: $selected) { PlaybackView(channel: $0) }
        .sheet(item: $selectedSeries) { SeriesView(series: $0) }
    }
}

struct MiniPlayer: View {
    let open: (Channel) -> Void
    @ObservedObject private var playback = Playback.shared
    var body: some View {
        if let current = playback.channel {
            HStack {
                Button { open(current) } label: {
                    VStack(alignment: .leading) {
                        Text(current.name).lineLimit(1)
                        Text(playback.state).font(.caption)
                    }
                }
                Spacer()
                Button { playback.togglePause() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }
                Button { playback.stop() } label: { Image(systemName: "stop.fill") }
            }.padding().background(.ultraThinMaterial)
        }
    }
}
