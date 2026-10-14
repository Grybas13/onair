import Foundation

/// Last.fm API klientas: žymos (vibe) ir panašios dainos/atlikėjai (atradimams).
/// Last.fm JSON nėra nuoseklus (vienas elementas kartais grąžinamas ne masyvu,
/// skaičiai kartais yra tekstas), todėl skaitome jį lanksčiai per JSONSerialization.
@MainActor
final class LastFMAPI {
    struct SimilarTrack {
        let title: String
        let artist: String
        let match: Double
    }

    private let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private var lastCallAt = Date.distantPast
    /// Last.fm leidžia ~5 užklausas per sekundę – laikomės atsargiau.
    private let minInterval: TimeInterval = 0.25

    var isConfigured: Bool { !Config.lastFMAPIKey.isEmpty }

    // MARK: - Žymos

    func trackTopTags(artist: String, title: String) async -> [String: Int] {
        guard let json = await call("track.gettoptags", ["artist": artist, "track": title, "autocorrect": "1"]) else {
            return [:]
        }
        return Self.parseTags(json)
    }

    func artistTopTags(artist: String) async -> [String: Int] {
        guard let json = await call("artist.gettoptags", ["artist": artist, "autocorrect": "1"]) else {
            return [:]
        }
        return Self.parseTags(json)
    }

    // MARK: - Panašūs

    func similarTracks(artist: String, title: String, limit: Int) async -> [SimilarTrack] {
        guard let json = await call("track.getsimilar", [
            "artist": artist, "track": title, "limit": String(limit), "autocorrect": "1"
        ]) else { return [] }
        let container = json["similartracks"] as? [String: Any]
        return Self.list(container?["track"]).compactMap { item in
            guard let title = item["name"] as? String,
                  let artistName = (item["artist"] as? [String: Any])?["name"] as? String else { return nil }
            return SimilarTrack(title: title, artist: artistName, match: Self.number(item["match"]) ?? 0)
        }
    }

    func similarArtists(artist: String, limit: Int) async -> [(name: String, match: Double)] {
        guard let json = await call("artist.getsimilar", [
            "artist": artist, "limit": String(limit), "autocorrect": "1"
        ]) else { return [] }
        let container = json["similarartists"] as? [String: Any]
        return Self.list(container?["artist"]).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return (name: name, match: Self.number(item["match"]) ?? 0)
        }
    }

    func artistTopTracks(artist: String, limit: Int) async -> [SimilarTrack] {
        guard let json = await call("artist.gettoptracks", [
            "artist": artist, "limit": String(limit), "autocorrect": "1"
        ]) else { return [] }
        let container = json["toptracks"] as? [String: Any]
        return Self.list(container?["track"]).compactMap { item in
            guard let title = item["name"] as? String else { return nil }
            let artistName = (item["artist"] as? [String: Any])?["name"] as? String ?? artist
            return SimilarTrack(title: title, artist: artistName, match: 0.5)
        }
    }

    // MARK: - Užklausa

    private func call(_ method: String, _ params: [String: String]) async -> [String: Any]? {
        guard isConfigured else { return nil }

        let wait = minInterval - Date().timeIntervalSince(lastCallAt)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
        lastCallAt = Date()

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: Config.lastFMAPIKey),
            URLQueryItem(name: "format", value: "json")
        ]
        items += params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("OnAir/0.2 (personal radio)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let code = json["error"] {
                // 6 = nerasta (įprasta mažiau žinomoms dainoms) – netriukšmaujame žurnale.
                if Self.number(code) != 6 {
                    trace("Last.fm \(method) klaida \(code): \(json["message"] as? String ?? "")")
                }
                return nil
            }
            if status != 200 {
                trace("Last.fm \(method) HTTP \(status)")
                return nil
            }
            return json
        } catch {
            if (error as? URLError)?.code != .cancelled {
                trace("Last.fm \(method) nepavyko: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: - Lankstus skaitymas

    private static func parseTags(_ json: [String: Any]) -> [String: Int] {
        let container = json["toptags"] as? [String: Any]
        var result: [String: Int] = [:]
        for item in list(container?["tag"]).prefix(25) {
            guard let name = item["name"] as? String else { continue }
            let count = Int(number(item["count"]) ?? 0)
            guard count > 0 else { continue }
            result[name.lowercased()] = max(result[name.lowercased()] ?? 0, count)
        }
        return result
    }

    /// Paverčia Last.fm reikšmę į elementų sąrašą (masyvas arba vienas objektas).
    private static func list(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
