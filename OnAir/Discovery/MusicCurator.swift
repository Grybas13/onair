import Foundation

/// Sudaro stoties sąrašus pagal vibe: tavo dainos (pagal Last.fm žymas)
/// + naujos dainos (Last.fm „panašios“ → surastos Spotify kataloge).
@MainActor
final class MusicCurator {
    private let lastFM: LastFMAPI
    private let spotify: SpotifyAPI
    private let store: ListeningStore

    /// Tavo dainos (iš Spotify „Top“ sąrašų).
    private(set) var pool: [SpotifyTrack] = []
    private var shortTermURIs: Set<String> = []
    private var longTermURIs: Set<String> = []
    private var recentURIs: Set<String> = []

    private var taggingTask: Task<Void, Never>?
    private var bankTask: Task<Void, Never>?

    init(lastFM: LastFMAPI, spotify: SpotifyAPI, store: ListeningStore) {
        self.lastFM = lastFM
        self.spotify = spotify
        self.store = store
    }

    var hasLastFM: Bool { lastFM.isConfigured }

    func setPool(_ tracks: [SpotifyTrack], shortTerm: Set<String>, longTerm: Set<String>, recent: Set<String>) {
        pool = tracks
        shortTermURIs = shortTerm
        longTermURIs = longTerm
        recentURIs = recent
    }

    // MARK: - Sąrašo sudarymas

    /// Sudaro naują sąrašą. `liveDiscovery` – ar ieškoti naujų dainų dabar (lėčiau),
    /// ar imti jau paruoštas iš banko (akimirksniu).
    func buildPlan(vibe: Vibe, count: Int, avoid: Set<String>, liveDiscovery: Bool) async -> [SpotifyTrack] {
        let usable = pool.filter { !store.isBanned($0) && !avoid.contains($0.uri) }

        // 1. Tavo dainos, tinkančios vibe
        var own: [SpotifyTrack]
        switch vibe {
        case .mix:
            own = freshFirst(usable)
        case .discover:
            own = []
        case .throwback:
            own = ranked(usable) { throwbackScore($0) }
        default:
            await waitForTagging(timeout: 25)
            own = ranked(usable) { vibeScore($0, vibe: vibe) }
        }

        // 2. Naujos dainos
        let wantedDiscovery = Int((Double(count) * vibe.discoveryShare).rounded())
        var discovered: [SpotifyTrack] = []
        if wantedDiscovery > 0 && hasLastFM {
            let exclude = Set(pool.map(\.uri)).union(avoid)
            if liveDiscovery {
                let seeds = discoverySeeds(vibe: vibe, ownMatches: own)
                let target = vibe == .discover ? min(wantedDiscovery, 25) : min(wantedDiscovery, 12)
                discovered = await discover(seeds: seeds, count: target, exclude: exclude)
            } else {
                discovered = store.takeFromDiscoveryBank(count: wantedDiscovery, excluding: exclude)
            }
        }

        // Jei saviškių trūksta (pvz. mažai žymų) – papildome bendru sąrašu.
        let ownTarget = vibe == .discover ? 0 : count - discovered.count
        if own.count < min(ownTarget, 15) && vibe != .discover {
            let extra = freshFirst(usable).filter { candidate in !own.contains { $0.uri == candidate.uri } }
            own += extra.prefix(max(0, 15 - own.count))
        }
        own = Array(own.prefix(ownTarget))

        let plan = interleave(own: own, discovered: discovered)
        trace("Sąrašas „\(vibe.title)“: \(own.count) tavo + \(discovered.count) naujų")
        return separateArtists(plan)
    }

    /// Fone paruošia naujų dainų banką kitam eteriui ir „Mix“ režimui.
    func refreshDiscoveryBankInBackground() {
        guard hasLastFM, bankTask == nil, store.data.discoveryBank.count < 40 else { return }
        bankTask = Task { [weak self] in
            guard let self else { return }
            let seeds = self.discoverySeeds(vibe: .mix, ownMatches: [])
            let exclude = Set(self.pool.map(\.uri)).union(self.store.data.discoveryBank.map(\.uri))
            let found = await self.discover(seeds: seeds, count: 30, exclude: exclude)
            self.store.setDiscoveryBank(self.store.data.discoveryBank + found)
            trace("Atradimų bankas: \(self.store.data.discoveryBank.count) dainų")
            self.bankTask = nil
        }
    }

    // MARK: - Žymos

    /// Fone surenka Last.fm žymas visoms baseino dainoms (išsaugoma 30 d.).
    func startTaggingInBackground() {
        guard hasLastFM, taggingTask == nil else { return }
        let tracks = pool
        taggingTask = Task { [weak self] in
            guard let self else { return }
            var fetched = 0
            var artistsDone = Set<String>()
            for track in tracks {
                if Task.isCancelled { break }
                let artist = track.primaryArtist
                if !artistsDone.contains(artist.lowercased()) {
                    artistsDone.insert(artist.lowercased())
                    if self.store.artistTags(artist) == nil {
                        let tags = await self.lastFM.artistTopTags(artist: artist)
                        self.store.setArtistTags(artist, tags: tags)
                        fetched += 1
                    }
                }
                if self.store.trackTags(track) == nil {
                    let tags = await self.lastFM.trackTopTags(artist: artist, title: DJScript.cleanTitle(track.name))
                    self.store.setTrackTags(track, tags: tags)
                    fetched += 1
                }
            }
            if fetched > 0 {
                trace("Last.fm: surinktos žymos (\(fetched) užklausų)")
            }
            self.taggingTask = nil
        }
    }

    private func waitForTagging(timeout: Double) async {
        guard let task = taggingTask else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while taggingTask != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if taggingTask != nil {
            trace("Žymos dar renkamos – sąrašą sudarau iš to, ką turiu")
        }
        _ = task
    }

    /// Žymos dainai: pirmiausia dainos, jei jų mažai – atlikėjo.
    func tags(for track: SpotifyTrack) -> [String: Int] {
        let trackTags = store.trackTags(track) ?? [:]
        if trackTags.count >= 3 { return trackTags }
        let artistTags = store.artistTags(track.primaryArtist) ?? [:]
        var merged = artistTags.mapValues { $0 / 2 }
        for (tag, count) in trackTags {
            merged[tag] = max(merged[tag] ?? 0, count)
        }
        return merged
    }

    /// Kelios ryškiausios žymos (Dėdžiui apie nuotaiką).
    func topTagNames(for track: SpotifyTrack, limit: Int = 3) -> [String] {
        let ignored: Set<String> = ["seen live", "favorites", "favourite", "favorite", "albums i own", "under 2000 listeners"]
        return tags(for: track)
            .filter { !ignored.contains($0.key) && $0.key.count <= 24 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    func vibeScore(_ track: SpotifyTrack, vibe: Vibe) -> Double {
        let keywords = vibe.keywords
        guard !keywords.isEmpty else { return 0 }
        var score = 0.0
        for (tag, count) in tags(for: track) {
            for (keyword, weight) in keywords where tag.contains(keyword) {
                score += Double(count) / 100 * weight
                break
            }
        }
        if store.isLiked(track) { score *= 1.2 }
        return score
    }

    func throwbackScore(_ track: SpotifyTrack) -> Double {
        var score = 0.0
        let year = Calendar.current.component(.year, from: Date())
        if let released = track.releaseYear {
            if released <= year - 8 { score += 1 } else if released <= year - 5 { score += 0.5 }
        }
        if longTermURIs.contains(track.uri) && !shortTermURIs.contains(track.uri) { score += 0.8 }
        for tag in tags(for: track).keys where ["80s", "90s", "00s", "oldies", "classic"].contains(where: { tag.contains($0) }) {
            score += 0.4
            break
        }
        return score
    }

    // MARK: - Atradimai

    private func discoverySeeds(vibe: Vibe, ownMatches: [SpotifyTrack]) -> [SpotifyTrack] {
        let liked = pool.filter { store.isLiked($0) }
        let recentFavourites = pool.filter { shortTermURIs.contains($0.uri) }
        var seeds: [SpotifyTrack]
        switch vibe {
        case .mix, .discover:
            seeds = liked.shuffled() + recentFavourites.shuffled()
        default:
            seeds = Array(ownMatches.prefix(12)).shuffled() + liked.shuffled()
        }
        var seen = Set<String>()
        return seeds.filter { seen.insert($0.uri).inserted && !store.isBanned($0) }
    }

    /// Randa naujų dainų: Last.fm „panašios dainos“ (arba panašių atlikėjų hitai),
    /// tada kiekvieną suranda Spotify kataloge.
    func discover(seeds: [SpotifyTrack], count: Int, exclude: Set<String>) async -> [SpotifyTrack] {
        guard count > 0 else { return [] }
        var candidates: [LastFMAPI.SimilarTrack] = []
        var seenKeys = Set(pool.map(\.matchKey))

        for seed in seeds.prefix(8) {
            if candidates.count >= count * 3 { break }
            var similar = await lastFM.similarTracks(
                artist: seed.primaryArtist, title: DJScript.cleanTitle(seed.name), limit: 15
            )
            if similar.isEmpty {
                // Mažiau žinomoms dainoms Last.fm „panašių“ neturi – imame panašių atlikėjų hitus.
                let artists = await lastFM.similarArtists(artist: seed.primaryArtist, limit: 4)
                for artist in artists.shuffled().prefix(2) {
                    let top = await lastFM.artistTopTracks(artist: artist.name, limit: 4)
                    similar += top
                }
            }
            for item in similar.shuffled() {
                let key = DJScript.cleanTitle(item.title).lowercased() + "|" + item.artist.lowercased()
                guard seenKeys.insert(key).inserted, !store.isArtistBanned(item.artist) else { continue }
                candidates.append(item)
            }
        }

        var found: [SpotifyTrack] = []
        var usedArtists: [String: Int] = [:]
        for candidate in candidates.shuffled() {
            if found.count >= count { break }
            // Ne daugiau 2 dainų iš to paties naujo atlikėjo.
            if usedArtists[candidate.artist.lowercased(), default: 0] >= 2 { continue }
            guard let track = try? await spotify.searchTrack(title: candidate.title, artist: candidate.artist),
                  !exclude.contains(track.uri),
                  !store.isBanned(track),
                  !found.contains(where: { $0.uri == track.uri }) else { continue }
            found.append(track)
            usedArtists[candidate.artist.lowercased(), default: 0] += 1
        }
        if !found.isEmpty {
            trace("Atrasta naujų dainų: \(found.count)")
        }
        return found
    }

    // MARK: - Tvarka

    /// Neseniai grotas – į galą, kitas sumaišome.
    private func freshFirst(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        let fresh = tracks.filter { !recentURIs.contains($0.uri) }.shuffled()
        let recent = tracks.filter { recentURIs.contains($0.uri) }.shuffled()
        return fresh + recent
    }

    /// Tinkančios dainos (score > 0) – geriausios pirmiau, bet su atsitiktinumu.
    private func ranked(_ tracks: [SpotifyTrack], score: (SpotifyTrack) -> Double) -> [SpotifyTrack] {
        var scored: [(track: SpotifyTrack, value: Double)] = []
        for track in tracks {
            let value = score(track)
            guard value > 0.15 else { continue }
            let penalty = recentURIs.contains(track.uri) ? 0.3 : 0
            scored.append((track: track, value: value * Double.random(in: 0.75...1.25) - penalty))
        }
        return scored.sorted { $0.value > $1.value }.map(\.track)
    }

    /// Naujas dainas išdėlioja tolygiai tarp tavo dainų (pvz. kas trečia).
    private func interleave(own: [SpotifyTrack], discovered: [SpotifyTrack]) -> [SpotifyTrack] {
        guard !discovered.isEmpty else { return own }
        guard !own.isEmpty else { return discovered }
        var result: [SpotifyTrack] = []
        let step = max(1, Double(own.count + discovered.count) / Double(discovered.count))
        var ownIndex = 0
        var newIndex = 0
        var nextNewAt = step - 1
        while ownIndex < own.count || newIndex < discovered.count {
            if newIndex < discovered.count && (Double(result.count) >= nextNewAt || ownIndex >= own.count) {
                result.append(discovered[newIndex])
                newIndex += 1
                nextNewAt += step
            } else if ownIndex < own.count {
                result.append(own[ownIndex])
                ownIndex += 1
            }
        }
        return result
    }

    /// Vengia to paties atlikėjo dviejų dainų iš eilės.
    private func separateArtists(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        var bag = tracks
        var result: [SpotifyTrack] = []
        var lastArtist: String?
        while !bag.isEmpty {
            let window = bag.prefix(6)
            let index = window.firstIndex { $0.primaryArtist != lastArtist } ?? bag.startIndex
            let track = bag.remove(at: index)
            result.append(track)
            lastArtist = track.primaryArtist
        }
        return result
    }
}
