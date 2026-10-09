import Foundation
import Security

struct Credentials: Codable {
    var server = ""
    var username = ""
    var password = ""
    func baseURL() throws -> URL {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CatalogError.invalidURL }
        return url
    }
    func apiURL(action: String?) throws -> URL {
        let base = try baseURL().appendingPathComponent("player_api.php")
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { c.queryItems!.append(URLQueryItem(name: "action", value: action)) }
        guard let result = c.url else { throw CatalogError.invalidURL }
        return result
    }
    func streamURL(id: String, movie: Bool, ext: String) throws -> URL {
        try baseURL().appendingPathComponent(movie ? "movie" : "live")
            .appendingPathComponent(username).appendingPathComponent(password)
            .appendingPathComponent("\(id).\(ext)")
    }
}

enum CatalogError: LocalizedError {
    case invalidURL, rejected, malformed, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a full http:// or https:// server URL, including port if needed."
        case .rejected: return "Provider rejected the login, or the account is inactive."
        case .malformed: return "The provider response is not a supported catalog."
        case .http(let status): return "Provider returned HTTP \(status)."
        }
    }
}

struct Channel: Identifiable, Codable {
    var id: String
    var name: String
    var group: String
    var url: URL
    var live: Bool
    var artwork: URL? = nil
    var categoryID: String? = nil
}

enum Catalog {
    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw CatalogError.http(http.statusCode) }
        return data
    }
    static func scalar(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    static func xtream(_ c: Credentials, movie: Bool, hls: Bool) async throws -> [Channel] {
        let loginData = try await fetch(c.apiURL(action: nil))
        guard let root = try JSONSerialization.jsonObject(with: loginData) as? [String: Any],
              let user = root["user_info"] as? [String: Any], scalar(user["auth"]) == "1",
              scalar(user["status"])?.lowercased() == "active" else { throw CatalogError.rejected }
        async let categories = categoryNames(c, action: movie ? "get_vod_categories" : "get_live_categories")
        let data = try await fetch(c.apiURL(action: movie ? "get_vod_streams" : "get_live_streams"))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CatalogError.malformed }
        let names = (try? await categories) ?? [:]
        return try rows.compactMap { row in
            guard let id = scalar(row["stream_id"]), let name = row["name"] as? String else { return nil }
            let ext = movie ? (scalar(row["container_extension"]) ?? "mp4") : (hls ? "m3u8" : "ts")
            return Channel(id: "\(movie ? "vod" : "live"):\(id)", name: name,
                           group: names[scalar(row["category_id"]) ?? ""] ?? scalar(row["category_id"]) ?? "", url: try c.streamURL(id: id, movie: movie, ext: ext), live: !movie, artwork: scalar(row["stream_icon"]).flatMap(URL.init(string:)), categoryID: scalar(row["category_id"]))
        }
    }
    static func m3u(_ text: String, base: URL) -> [Channel] {
        var name = "Stream", group = "", result: [Channel] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                if let comma = line.firstIndex(of: ",") { name = String(line[line.index(after: comma)...]) }
                group = ""
                if let range = line.range(of: "group-title=\"") {
                    group = String(line[range.upperBound...].prefix(while: { $0 != "\"" }))
                }
            } else if !line.isEmpty && !line.hasPrefix("#"),
                      let url = URL(string: line, relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                result.append(Channel(id: "m3u:\(result.count)", name: name, group: group, url: url, live: true))
                name = "Stream"; group = ""
            }
        }
        return result
    }
}

enum Vault {
    static let service = "FreeStream.credentials"
    static func save(_ c: Credentials) throws {
        let data = try JSONEncoder().encode(c)
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrService as String: service, kSecAttrAccount as String: "xtream"]
        let update = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CatalogError.malformed }
        } else if update != errSecSuccess { throw CatalogError.malformed }
    }
    static func load() -> Credentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "xtream",
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let c = try? JSONDecoder().decode(Credentials.self, from: data) else { return Credentials() }
        return c
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

struct Series: Identifiable, Codable {
    let id: String
    let name: String
    let group: String
    let credentials: Credentials
    var artwork: URL? = nil
    var categoryID: String? = nil
}

extension Catalog {
    static func categoryNames(_ credentials: Credentials, action: String) async throws -> [String: String] {
        let data = try await fetch(credentials.apiURL(action: action))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CatalogError.malformed }
        var result: [String: String] = [:]
        for row in rows {
            if let id = scalar(row["category_id"]), let name = scalar(row["category_name"]) { result[id] = name }
        }
        return result
    }
    static func series(_ credentials: Credentials) async throws -> [Series] {
        async let categories = categoryNames(credentials, action: "get_series_categories")
        let data = try await fetch(credentials.apiURL(action: "get_series"))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CatalogError.malformed }
        let names = (try? await categories) ?? [:]
        return rows.compactMap { row in
            guard let id = scalar(row["series_id"]), let name = row["name"] as? String else { return nil }
            return Series(id: id, name: name, group: names[scalar(row["category_id"]) ?? ""] ?? scalar(row["category_id"]) ?? "", credentials: credentials, artwork: scalar(row["cover"]).flatMap(URL.init(string:)), categoryID: scalar(row["category_id"]))
        }
    }
    static func episodes(_ series: Series) async throws -> [Channel] {
        var components = URLComponents(url: try series.credentials.apiURL(action: "get_series_info"), resolvingAgainstBaseURL: false)!
        components.queryItems?.append(URLQueryItem(name: "series_id", value: series.id))
        guard let url = components.url else { throw CatalogError.invalidURL }
        let data = try await fetch(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seasons = root["episodes"] as? [String: [[String: Any]]] else { throw CatalogError.malformed }
        var result: [Channel] = []
        for season in seasons.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            for row in (seasons[season] ?? []).sorted(by: { (Int(scalar($0["episode_num"]) ?? "0") ?? 0) < (Int(scalar($1["episode_num"]) ?? "0") ?? 0) }) {
                guard let id = scalar(row["id"]) else { continue }
                let ext = scalar(row["container_extension"]) ?? "mp4"
                let stream = try series.credentials.baseURL().appendingPathComponent("series")
                    .appendingPathComponent(series.credentials.username).appendingPathComponent(series.credentials.password)
                    .appendingPathComponent("\(id).\(ext)")
                result.append(Channel(id: "episode:\(id)", name: scalar(row["title"]) ?? "Episode \(scalar(row["episode_num"]) ?? id)",
                                      group: "\(series.name) • Season \(season)", url: stream, live: false, artwork: ((row["info"] as? [String: Any]).flatMap { scalar($0["movie_image"]) }).flatMap(URL.init(string:)) ?? series.artwork))
            }
        }
        return result
    }
}

// Stream URLs contain provider secrets, so saved catalogs use Keychain, not a plain file.
enum SecureStore {
    private static func key(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "FreeStream.catalog", kSecAttrAccount as String: account]
    }
    static func read(account: String) -> Data? {
        var query = key(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    @discardableResult static func write(_ data: Data, account: String) -> Bool {
        let query = key(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
    static func delete(account: String) { SecItemDelete(key(account) as CFDictionary) }
}
