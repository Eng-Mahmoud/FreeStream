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

struct Channel: Identifiable {
    var id: String
    var name: String
    var group: String
    var url: URL
    var live: Bool
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
        let data = try await fetch(c.apiURL(action: movie ? "get_vod_streams" : "get_live_streams"))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CatalogError.malformed }
        return try rows.compactMap { row in
            guard let id = scalar(row["stream_id"]), let name = row["name"] as? String else { return nil }
            let ext = movie ? (scalar(row["container_extension"]) ?? "mp4") : (hls ? "m3u8" : "ts")
            return Channel(id: "\(movie ? "vod" : "live"):\(id)", name: name,
                           group: scalar(row["category_id"]) ?? "", url: try c.streamURL(id: id, movie: movie, ext: ext), live: !movie)
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
