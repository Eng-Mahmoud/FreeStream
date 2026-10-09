import SwiftUI
import CryptoKit

// Store only hashes of source identities; stream credentials stay out of preferences.
@MainActor
final class Favorites: ObservableObject {
    static let shared = Favorites()
    @Published private(set) var keys: Set<String>
    private let storageKey = "MahmoudTV.favorites.v1"
    private init() { keys = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? []) }
    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func key(_ item: Channel) -> String { hash("media|" + item.url.absoluteString) }
    func key(_ show: Series) -> String {
        hash("series|\(show.credentials.server)|\(show.credentials.username)|\(show.id)")
    }
    func contains(_ item: Channel) -> Bool { keys.contains(key(item)) }
    func contains(_ show: Series) -> Bool { keys.contains(key(show)) }
    func toggle(_ item: Channel) { toggleKey(key(item)) }
    func toggle(_ show: Series) { toggleKey(key(show)) }
    private func toggleKey(_ key: String) {
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        UserDefaults.standard.set(Array(keys), forKey: storageKey)
    }
    func clear() { keys = []; UserDefaults.standard.removeObject(forKey: storageKey) }
}

struct FavoriteButton: View {
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "heart.fill" : "heart")
                .foregroundStyle(selected ? Color.pink : Color.white)
                .padding(10).background(.black.opacity(0.65), in: Circle())
        }.buttonStyle(.plain)
            .accessibilityLabel(selected ? "Remove from favorites" : "Add to favorites")
    }
}

struct LibraryTabs: View {
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab).tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            HomeView(favoritesOnly: true, selectedTab: $selectedTab).tabItem { Label("Favorites", systemImage: "heart.fill") }.tag(1)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(2)
        }.tint(.cyan)
    }
}
