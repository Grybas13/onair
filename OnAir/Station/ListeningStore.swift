import Foundation

/// Vienas klausymas: kas grojo, kiek klausei, ar praleidai.
struct PlayEvent: Codable {
    let uri: String
    let name: String
    let artist: String
    let playedAt: Date
    var listenedMs: Int
    let durationMs: Int
    var skipped: Bool
    /// "onair" – grojo per OnAir; "spotify" – importuota iš Spotify istorijos.
    let source: String
}

struct TagEntry: Codable {
    let tags: [String: Int]
    let fetchedAt: Date
}

struct ListeningData: Codable {
    var plays: [PlayEvent] = []
    var likedURIs: Set<String> = []
    var likedKeys: Set<String> = []
    var dislikedURIs: Set<String> = []
    var dislikedKeys: Set<String> = []
    /// Atlikėjas (mažosiomis) → kiek kartų paspaustas 👎.
    var artistDislikes: [String: Int] = [:]
    /// Last.fm žymos: atlikėjas (mažosiomis) → žymos.
    var artistTags: [String: TagEntry] = [:]
    /// Last.fm žymos: "daina|atlikėjas" → žymos.
    var trackTags: [String: TagEntry] = [:]
    /// Naujos dainos, rastos per Last.fm ir Spotify paiešką (paruoštos kitam eteriui).
    var discoveryBank: [SpotifyTrack] = []
}

/// Statistika, kurią Dėdis gali naudoti kalboje.
struct ListeningStats {
    var topArtistsThisWeek: [(name: String, plays: Int)] = []
    var onRepeat: [(title: String, artist: String, plays: Int)] = []
    var skipsLastHour = 0
    var lastSkip: PlayEvent?
    var playsToday = 0
    var likedRecently: [String] = []
}

/// Klausymo istorija ir pasirinkimai, saugomi telefone (Application Support/listening.json).
@MainActor
final class ListeningStore {
    private(set) var data = ListeningData()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// Atlikėjas išmetamas iš stoties po tiek 👎.
    static let artistBanThreshold = 2

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("listening.json")

        if let raw = try? Data(contentsOf: fileURL) {
            do {
                data = try JSONDecoder().decode(ListeningData.self, from: raw)
            } catch {
                trace("Istorijos failo nepavyko perskaityti – pradedu iš naujo (\(error.localizedDescription))")
            }
        }
        trimOldPlays()
    }

    // MARK: - Įrašymas

    func recordPlay(_ track: SpotifyTrack, listenedMs: Int, skipped: Bool, at date: Date = Date()) {
        let event = PlayEvent(
            uri: track.uri,
            name: track.name,
            artist: track.primaryArtist,
            playedAt: date,
            listenedMs: max(0, listenedMs),
            durationMs: track.durationMs,
            skipped: skipped,
            source: "onair"
        )
        data.plays.append(event)
        scheduleSave()
    }

    /// Įrašo Spotify „neseniai grotas“ dainas, kurių dar nėra istorijoje.
    func importRecentlyPlayed(_ items: [SpotifyRecentlyPlayedItem]) {
        let formatterFractional = ISO8601DateFormatter()
        formatterFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var added = 0
        for item in items {
            guard let date = formatterFractional.date(from: item.playedAt) ?? formatter.date(from: item.playedAt) else {
                continue
            }
            let duplicate = data.plays.contains {
                $0.uri == item.track.uri && abs($0.playedAt.timeIntervalSince(date)) < 120
            }
            if duplicate { continue }
            data.plays.append(PlayEvent(
                uri: item.track.uri,
                name: item.track.name,
                artist: item.track.primaryArtist,
                playedAt: date,
                listenedMs: item.track.durationMs,
                durationMs: item.track.durationMs,
                skipped: false,
                source: "spotify"
            ))
            added += 1
        }
        if added > 0 {
            data.plays.sort { $0.playedAt < $1.playedAt }
            trace("Istorija: importuota iš Spotify \(added) klausymų")
            scheduleSave()
        }
    }

    // MARK: - ❤️ / 👎

    func like(_ track: SpotifyTrack) {
        data.likedURIs.insert(track.uri)
        data.likedKeys.insert(track.matchKey)
        // Jei anksčiau buvo 👎 – atšaukiame.
        data.dislikedURIs.remove(track.uri)
        data.dislikedKeys.remove(track.matchKey)
        scheduleSave()
    }

    func isLiked(_ track: SpotifyTrack) -> Bool {
        data.likedURIs.contains(track.uri) || data.likedKeys.contains(track.matchKey)
    }

    /// Grąžina true, jei po šio 👎 atlikėjas išmestas iš stoties.
    @discardableResult
    func dislike(_ track: SpotifyTrack) -> Bool {
        data.dislikedURIs.insert(track.uri)
        data.dislikedKeys.insert(track.matchKey)
        data.likedURIs.remove(track.uri)
        data.likedKeys.remove(track.matchKey)
        let artist = track.primaryArtist.lowercased()
        let count = (data.artistDislikes[artist] ?? 0) + 1
        data.artistDislikes[artist] = count
        scheduleSave()
        return count >= Self.artistBanThreshold
    }

    func isBanned(_ track: SpotifyTrack) -> Bool {
        if data.dislikedURIs.contains(track.uri) || data.dislikedKeys.contains(track.matchKey) {
            return true
        }
        return track.artists.contains { isArtistBanned($0.name) }
    }

    func isArtistBanned(_ name: String) -> Bool {
        (data.artistDislikes[name.lowercased()] ?? 0) >= Self.artistBanThreshold
    }

    // MARK: - Žymos

    func artistTags(_ artist: String) -> [String: Int]? {
        guard let entry = data.artistTags[artist.lowercased()], isFresh(entry) else { return nil }
        return entry.tags
    }

    func trackTags(_ track: SpotifyTrack) -> [String: Int]? {
        guard let entry = data.trackTags[track.matchKey], isFresh(entry) else { return nil }
        return entry.tags
    }

    func setArtistTags(_ artist: String, tags: [String: Int]) {
        data.artistTags[artist.lowercased()] = TagEntry(tags: tags, fetchedAt: Date())
        scheduleSave()
    }

    func setTrackTags(_ track: SpotifyTrack, tags: [String: Int]) {
        data.trackTags[track.matchKey] = TagEntry(tags: tags, fetchedAt: Date())
        scheduleSave()
    }

    private func isFresh(_ entry: TagEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) < 30 * 24 * 3600
    }

    // MARK: - Atradimų bankas

    func setDiscoveryBank(_ tracks: [SpotifyTrack]) {
        data.discoveryBank = Array(tracks.prefix(80))
        scheduleSave()
    }

    func takeFromDiscoveryBank(count: Int, excluding: Set<String>) -> [SpotifyTrack] {
        var taken: [SpotifyTrack] = []
        var remaining: [SpotifyTrack] = []
        for track in data.discoveryBank {
            if taken.count < count, !excluding.contains(track.uri), !isBanned(track) {
                taken.append(track)
            } else {
                remaining.append(track)
            }
        }
        data.discoveryBank = remaining
        scheduleSave()
        return taken
    }

    // MARK: - Statistika

    func plays(inLast seconds: TimeInterval) -> [PlayEvent] {
        let since = Date().addingTimeInterval(-seconds)
        return data.plays.filter { $0.playedAt >= since }
    }

    func playCount(artist: String, days: Double) -> Int {
        let name = artist.lowercased()
        return plays(inLast: days * 24 * 3600).filter { $0.artist.lowercased() == name && !$0.skipped }.count
    }

    func stats() -> ListeningStats {
        var result = ListeningStats()
        let week = plays(inLast: 7 * 24 * 3600).filter { !$0.skipped }

        var artistCounts: [String: Int] = [:]
        var artistDisplay: [String: String] = [:]
        for play in week {
            let key = play.artist.lowercased()
            artistCounts[key, default: 0] += 1
            artistDisplay[key] = play.artist
        }
        result.topArtistsThisWeek = artistCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (name: artistDisplay[$0.key] ?? $0.key, plays: $0.value) }

        var trackCounts: [String: (title: String, artist: String, plays: Int)] = [:]
        for play in week {
            let key = play.uri
            let current = trackCounts[key]?.plays ?? 0
            trackCounts[key] = (title: play.name, artist: play.artist, plays: current + 1)
        }
        result.onRepeat = trackCounts.values
            .filter { $0.plays >= 3 }
            .sorted { $0.plays > $1.plays }
            .prefix(2)
            .map { $0 }

        let lastHour = plays(inLast: 3600)
        result.skipsLastHour = lastHour.filter(\.skipped).count
        result.lastSkip = lastHour.last(where: \.skipped)

        let startOfDay = Calendar.current.startOfDay(for: Date())
        result.playsToday = data.plays.filter { $0.playedAt >= startOfDay }.count
        return result
    }

    // MARK: - Saugojimas

    private func trimOldPlays() {
        let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        let before = data.plays.count
        data.plays.removeAll { $0.playedAt < cutoff }
        if data.plays.count != before { scheduleSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: [.atomic])
        } catch {
            trace("Istorijos išsaugoti nepavyko: \(error.localizedDescription)")
        }
    }
}
