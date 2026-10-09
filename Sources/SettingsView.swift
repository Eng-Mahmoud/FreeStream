import SwiftUI

struct SettingsView: View {
    @ObservedObject private var library = StreamLibrary.shared
    @State private var credentials = Vault.load()
    @State private var source = 0
    @State private var hls = true
    @State private var playlist = ""
    @State private var remember = !Vault.load().username.isEmpty
    @State private var busy = false
    @State private var message = ""
    var body: some View {
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
                    Button("Forget login and catalog", role: .destructive) { Vault.clear(); library.clear(); Favorites.shared.clear(); credentials = Credentials(); remember = false; Playback.shared.stop() }.disabled(busy)
                }
            }
            .navigationTitle("Settings")
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
