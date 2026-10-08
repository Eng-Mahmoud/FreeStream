import Foundation

@MainActor
final class StreamLibrary: ObservableObject {
    static let shared = StreamLibrary()
    @Published private(set) var items: [Channel] = []
    @Published private(set) var series: [Series] = []
    @Published var carStatus = "CarPlay disconnected. Authorized signing is required for the car app."
    @Published var rememberCatalog: Bool {
        didSet { UserDefaults.standard.set(rememberCatalog, forKey: "saveCatalog"); persist() }
    }
    private let cacheKey = "carplayCatalog"
    private struct Snapshot: Codable { let items: [Channel]; let series: [Series] }
    private init() {
        rememberCatalog = UserDefaults.standard.bool(forKey: "saveCatalog")
        if rememberCatalog, let data = SecureStore.read(account: cacheKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            items = snapshot.items; series = snapshot.series
        }
    }
    func replace(_ items: [Channel], series: [Series] = []) {
        self.items = items; self.series = series; persist()
    }
    func clear() { items = []; series = []; SecureStore.delete(account: cacheKey) }
    private func persist() {
        guard rememberCatalog else { SecureStore.delete(account: cacheKey); return }
        if let data = try? JSONEncoder().encode(Snapshot(items: items, series: series)) {
            if !SecureStore.write(data, account: cacheKey) {
                carStatus = "Catalog could not be saved. Reload it on iPhone before browsing from the car."
            }
        }
    }
}
