import Foundation

enum SpotifyAPIError: LocalizedError {
    case http(status: Int, message: String, reason: String?)
    case quotaExceeded
    case rateLimited(retryAfter: Int)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message, let reason):
            if let reason { return "Spotify klaida \(status): \(message) [\(reason)]" }
            return "Spotify klaida \(status): \(message)"
        case .quotaExceeded:
            return "Viršyta Spotify Development Mode kvota. Palauk ir bandyk vėliau."
        case .rateLimited(let seconds):
            return "Per daug užklausų, Spotify prašo palaukti \(seconds) s."
        }
    }

    var reason: String? {
        if case .http(_, _, let reason) = self { return reason }
        return nil
    }

    var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }
}

/// Plonas Spotify Web API klientas.
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth
    private let baseURL = URL(string: "https://api.spotify.com/v1")!
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    // MARK: - Asmeniniai duomenys

    func topTracks(timeRange: String, limit: Int = 50) async throws -> [SpotifyTrack] {
        let page: SpotifyPaging<SpotifyTrack>? = try await get(
            "me/top/tracks",
            query: ["time_range": timeRange, "limit": String(limit)]
        )
        return page?.items ?? []
    }

    func recentlyPlayed(limit: Int = 50) async throws -> [SpotifyRecentlyPlayedItem] {
        let page: SpotifyPaging<SpotifyRecentlyPlayedItem>? = try await get(
            "me/player/recently-played",
            query: ["limit": String(limit)]
        )
        return page?.items ?? []
    }

    // MARK: - Grotuvas

    func devices() async throws -> [SpotifyDevice] {
        let response: SpotifyDevicesResponse? = try await get("me/player/devices")
        return response?.devices ?? []
    }

    /// nil, kai niekas negroja / nėra aktyvaus įrenginio (HTTP 204).
    func playbackState() async throws -> SpotifyPlaybackState? {
        try await get("me/player")
    }

    func play(uris: [String], deviceID: String?) async throws {
        var query: [String: String] = [:]
        if let deviceID { query["device_id"] = deviceID }
        try await send("PUT", "me/player/play", query: query, json: ["uris": uris])
    }

    /// Groja kontekstą (grojaraštį) nuo nurodytos pozicijos.
    /// Spotify iPhone programėlė (nuo 2026 rudens) patikimai paleidžia tik kontekstus,
    /// o ne „plikus“ dainų sąrašus (uris).
    func playContext(_ contextURI: String, position: Int, deviceID: String?) async throws {
        var query: [String: String] = [:]
        if let deviceID { query["device_id"] = deviceID }
        try await send("PUT", "me/player/play", query: query, json: [
            "context_uri": contextURI,
            "offset": ["position": position]
        ])
    }

    func resume(deviceID: String?) async throws {
        var query: [String: String] = [:]
        if let deviceID { query["device_id"] = deviceID }
        try await send("PUT", "me/player/play", query: query)
    }

    func pause(deviceID: String?) async throws {
        var query: [String: String] = [:]
        if let deviceID { query["device_id"] = deviceID }
        try await send("PUT", "me/player/pause", query: query)
    }

    func next(deviceID: String?) async throws {
        var query: [String: String] = [:]
        if let deviceID { query["device_id"] = deviceID }
        try await send("POST", "me/player/next", query: query)
    }

    func addToQueue(uri: String, deviceID: String?) async throws {
        var query: [String: String] = ["uri": uri]
        if let deviceID { query["device_id"] = deviceID }
        try await send("POST", "me/player/queue", query: query)
    }

    func setShuffle(_ on: Bool, deviceID: String?) async throws {
        var query: [String: String] = ["state": on ? "true" : "false"]
        if let deviceID { query["device_id"] = deviceID }
        try await send("PUT", "me/player/shuffle", query: query)
    }

    func setRepeat(_ mode: String, deviceID: String?) async throws {
        var query: [String: String] = ["state": mode]
        if let deviceID { query["device_id"] = deviceID }
        try await send("PUT", "me/player/repeat", query: query)
    }

    // MARK: - Grojaraščiai

    func createPlaylist(name: String, description: String) async throws -> SpotifyPlaylist {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "description": description,
            "public": false
        ] as [String: Any])
        let (data, _) = try await perform("POST", "me/playlists", query: [:], body: body)
        return try decoder.decode(SpotifyPlaylist.self, from: data)
    }

    /// Pakeičia visas grojaraščio dainas (iki 100).
    func replacePlaylistItems(playlistID: String, uris: [String]) async throws {
        try await send("PUT", "playlists/\(playlistID)/items", json: ["uris": uris])
    }

    /// Prideda dainas į grojaraščio galą (iki 100).
    func addPlaylistItems(playlistID: String, uris: [String]) async throws {
        try await send("POST", "playlists/\(playlistID)/items", json: ["uris": uris])
    }

    // MARK: - Užklausos

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T? {
        let (data, status) = try await perform("GET", path, query: query, body: nil)
        if status == 204 || data.isEmpty { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? ""
            trace("Dekodavimo klaida \(path): \(error) | \(preview)")
            throw error
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws {
        var body: Data?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
        }
        _ = try await perform(method, path, query: query, body: body)
    }

    private func perform(_ method: String, _ path: String, query: [String: String], body: Data?, isRetry: Bool = false) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        let token = try await auth.validAccessToken(forceRefresh: isRetry)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            // Spotify kai kuriems POST/PUT reikalauja Content-Length: 0.
            request.httpBody = Data()
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if (200...299).contains(status) {
            return (data, status)
        }

        if status == 401 && !isRetry {
            trace("API \(method) \(path): 401, atnaujinu raktą ir kartoju")
            return try await perform(method, path, query: query, body: body, isRetry: true)
        }

        let parsed = try? decoder.decode(SpotifyErrorBody.self, from: data)
        let message = parsed?.error.message ?? String(data: data, encoding: .utf8) ?? ""
        let reason = parsed?.error.reason
        trace("API \(method) \(path) → \(status) \(message) \(reason ?? "")")

        if status == 429 {
            if reason == "QUOTA_EXCEEDED" { throw SpotifyAPIError.quotaExceeded }
            let retryAfter = Int((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            throw SpotifyAPIError.rateLimited(retryAfter: retryAfter)
        }
        throw SpotifyAPIError.http(status: status, message: message, reason: reason)
    }
}
