import Foundation

/// Stoties „smegenys“: parenka dainas, paleidžia jas Spotify, seka dainų kaitą
/// ir kas N dainų įjungia DJ.
@MainActor
final class StationEngine: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case onAir
        case needsSpotify
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: [SpotifyTrack] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var nowPlaying: SpotifyTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var progressMs = 0
    @Published private(set) var progressUpdatedAt = Date()
    @Published private(set) var onMicText: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var tracksUntilTalk = 0

    let api: SpotifyAPI
    let audio: AudioController
    let voice: DJVoice

    private var pool: [SpotifyTrack] = []
    private var recentURIs: Set<String> = []
    private var usedURIs: Set<String> = []
    private var deviceID: String?
    private var monitorTask: Task<Void, Never>?
    private var lastSeenURI: String?
    private var lastSeenTrack: SpotifyTrack?
    private var tracksSinceTalk = 0
    private var recentForRecap: [SpotifyTrack] = []
    private var isTalking = false
    private let initialPlanSize = 12
    private let refillSize = 6

    init(api: SpotifyAPI, audio: AudioController, voice: DJVoice) {
        self.api = api
        self.audio = audio
        self.voice = voice
    }

    private var talkEvery: Int {
        max(1, UserDefaults.standard.integer(forKey: SettingsKeys.talkEvery))
    }

    // MARK: - Valdymas

    func start() async {
        guard phase != .starting else { return }
        stopMonitor()
        phase = .starting
        trace("Stotis: paleidžiama")

        do {
            guard let device = try await findDevice() else {
                phase = .needsSpotify
                trace("Stotis: nerastas Spotify įrenginys. Reikia atidaryti Spotify programėlę.")
                return
            }
            deviceID = device.id
            deviceName = device.name
            trace("Stotis: groju per „\(device.name)“ (\(device.type))")

            try await loadPool()
            guard !pool.isEmpty else {
                phase = .failed("Spotify negrąžino tavo „Top“ dainų. Paklausyk muzikos keletą dienų ir bandyk vėl.")
                return
            }

            usedURIs.removeAll()
            plan = []
            plan = takeNext(count: initialPlanSize)
            currentIndex = 0

            // Kad Spotify grotų lygiai mūsų tvarka.
            do { try await api.setShuffle(false, deviceID: deviceID) } catch { trace("Shuffle išjungti nepavyko (nekritiška)") }
            do { try await api.setRepeat("off", deviceID: deviceID) } catch { trace("Repeat išjungti nepavyko (nekritiška)") }

            audio.startKeepAlive()

            try await api.play(uris: plan.map(\.uri), deviceID: deviceID)
            trace("Stotis: paleista \(plan.count) dainų")

            await waitForFirstTrack()

            tracksSinceTalk = 0
            tracksUntilTalk = talkEvery
            recentForRecap = []
            phase = .onAir

            if let first = plan.first {
                let opening = DJScript.stationOpen(first: first)
                Task { await self.talk(opening, label: "Atidarymas") }
            }
            startMonitor(initialDelay: 2)
        } catch {
            trace("Stotis: nepavyko paleisti – \(error.localizedDescription)")
            audio.stopKeepAlive()
            if let apiError = error as? SpotifyAPIError, apiError.status == 404 {
                // Dažniausiai: Spotify programėlė užmigdyta ir įrenginys „nerastas“.
                phase = .needsSpotify
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop(pauseSpotify: Bool) async {
        stopMonitor()
        voice.stop()
        audio.endDuck()
        audio.stopKeepAlive()
        isTalking = false
        onMicText = nil
        if pauseSpotify {
            do { try await api.pause(deviceID: deviceID) } catch { trace("Pauzė nepavyko: \(error.localizedDescription)") }
        }
        phase = .idle
        trace("Stotis: sustabdyta")
    }

    func skip() async {
        do {
            try await api.next(deviceID: deviceID)
            trace("Praleista daina")
            startMonitor(initialDelay: 1.2)
        } catch {
            trace("Praleisti nepavyko: \(error.localizedDescription)")
        }
    }

    func togglePlayPause() async {
        do {
            if isPlaying {
                try await api.pause(deviceID: deviceID)
                isPlaying = false
            } else {
                try await api.resume(deviceID: deviceID)
                isPlaying = true
            }
            startMonitor(initialDelay: 1)
        } catch {
            trace("Grojimo/pauzės klaida: \(error.localizedDescription)")
        }
    }

    /// Rankinis DJ įsijungimas testavimui.
    func talkNow() async {
        if let track = nowPlaying {
            await talk(DJScript.nowPlayingMention(track), label: "Rankinis")
        } else {
            await talk(DJScript.voiceTest, label: "Testas")
        }
    }

    /// Balso testas iš nustatymų (veikia ir be paleistos stoties).
    func testVoice() async {
        await talk(DJScript.voiceTest, label: "Balso testas")
    }

    /// Kai programėlė grįžta į ekraną – greitai atnaujinti būseną.
    func refreshSoon() {
        guard phase == .onAir else { return }
        startMonitor(initialDelay: 0)
    }

    // MARK: - DJ

    private func talk(_ text: String, label: String) async {
        guard !isTalking else {
            trace("DJ: jau kalba, praleidžiu „\(label)“")
            return
        }
        isTalking = true
        onMicText = text
        trace("DJ [\(label)]: \(text)")

        let mode = UserDefaults.standard.string(forKey: SettingsKeys.talkMode) ?? "duck"
        if mode == "pause" && phase == .onAir {
            do { try await api.pause(deviceID: deviceID) } catch { trace("DJ: pauzė nepavyko") }
            await voice.speak(text)
            do { try await api.resume(deviceID: deviceID) } catch { trace("DJ: tęsti nepavyko") }
        } else {
            audio.beginDuck()
            try? await Task.sleep(for: .milliseconds(350))
            await voice.speak(text)
            try? await Task.sleep(for: .milliseconds(250))
            audio.endDuck()
        }

        onMicText = nil
        isTalking = false
    }

    // MARK: - Dainų parinkimas (1 etapas: tavo „Top“ dainos)

    private func loadPool() async throws {
        var seen = Set<String>()
        var collected: [SpotifyTrack] = []
        for range in ["short_term", "medium_term", "long_term"] {
            do {
                let tracks = try await api.topTracks(timeRange: range)
                for track in tracks where track.spotifyID != nil && seen.insert(track.uri).inserted {
                    collected.append(track)
                }
                trace("Top dainos (\(range)): \(tracks.count)")
            } catch {
                trace("Top dainos (\(range)) nepavyko: \(error.localizedDescription)")
                if range == "short_term" { throw error }
            }
        }
        pool = collected

        do {
            let recent = try await api.recentlyPlayed()
            recentURIs = Set(recent.map(\.track.uri))
            trace("Neseniai grotos: \(recentURIs.count) (jų bus vengiama)")
        } catch {
            trace("Neseniai grotų gauti nepavyko (nekritiška): \(error.localizedDescription)")
        }
        trace("Dainų baseinas: \(pool.count)")
    }

    /// Paima kitas dainas: be pasikartojimų, vengiant neseniai grotų
    /// ir to paties atlikėjo dviejų dainų iš eilės.
    private func takeNext(count: Int) -> [SpotifyTrack] {
        var candidates = pool.filter { !usedURIs.contains($0.uri) }
        if candidates.count < count {
            trace("Baseinas išsemtas – pradedu ratą iš naujo")
            let inPlan = Set(plan.suffix(count).map(\.uri))
            usedURIs = inPlan
            candidates = pool.filter { !inPlan.contains($0.uri) }
        }

        let fresh = candidates.filter { !recentURIs.contains($0.uri) }
        var bag = (fresh.count >= count ? fresh : candidates).shuffled()

        var result: [SpotifyTrack] = []
        var lastArtist = plan.last?.primaryArtist
        while result.count < count, !bag.isEmpty {
            let index = bag.firstIndex { $0.primaryArtist != lastArtist } ?? 0
            let track = bag.remove(at: index)
            result.append(track)
            usedURIs.insert(track.uri)
            lastArtist = track.primaryArtist
        }
        return result
    }

    // MARK: - Įrenginys

    private func findDevice() async throws -> SpotifyDevice? {
        let devices = try await api.devices()
        if devices.isEmpty {
            trace("Įrenginių sąrašas tuščias")
        } else {
            let summary = devices.map { "\($0.name) [\($0.type)\($0.isActive ? ", aktyvus" : "")]" }
            trace("Įrenginiai: " + summary.joined(separator: "; "))
        }
        let usable = devices.filter { $0.id != nil && $0.isRestricted != true }
        return usable.first { $0.type == "Smartphone" && $0.isActive }
            ?? usable.first { $0.type == "Smartphone" }
            ?? usable.first { $0.isActive }
    }

    private func waitForFirstTrack() async {
        guard let firstURI = plan.first?.uri else { return }
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(700))
            if let state = try? await api.playbackState(), let item = state.item, item.uri == firstURI {
                lastSeenURI = item.uri
                lastSeenTrack = item
                nowPlaying = item
                isPlaying = state.isPlaying
                progressMs = state.progressMs ?? 0
                progressUpdatedAt = Date()
                trace("Pirma daina groja: \(item.name)")
                return
            }
        }
        trace("Pirmos dainos patvirtinimo nesulaukta – tęsiu")
        lastSeenURI = firstURI
        lastSeenTrack = plan.first
    }

    // MARK: - Stebėjimas

    private func startMonitor(initialDelay: Double) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            if initialDelay > 0 {
                try? await Task.sleep(for: .seconds(initialDelay))
            }
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce()
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Viena būsenos užklausa. Grąžina, po kiek sekundžių tikrinti vėl:
    /// dainos viduryje retai (kas 15 s), artėjant pabaigai – tiksliai po jos.
    private func pollOnce() async -> Double {
        do {
            guard let state = try await api.playbackState(), let item = state.item else {
                isPlaying = false
                return 5
            }

            nowPlaying = item
            isPlaying = state.isPlaying
            progressMs = state.progressMs ?? 0
            progressUpdatedAt = Date()

            if item.uri != lastSeenURI {
                let previous = lastSeenTrack
                lastSeenURI = item.uri
                lastSeenTrack = item
                await handleTrackChange(from: previous, to: item)
            }

            guard state.isPlaying else { return 5 }
            let remaining = Double(item.durationMs - (state.progressMs ?? 0)) / 1000
            if remaining > 17 { return 15 }
            return max(0.8, remaining + 0.7)
        } catch SpotifyAPIError.rateLimited(let seconds) {
            return Double(max(seconds, 5))
        } catch SpotifyAPIError.quotaExceeded {
            trace("Kvota viršyta – stebėjimą pristabdau minutei")
            return 60
        } catch {
            trace("Stebėjimo klaida: \(error.localizedDescription)")
            return 8
        }
    }

    private func handleTrackChange(from previous: SpotifyTrack?, to current: SpotifyTrack) async {
        trace("Nauja daina: \(current.name) – \(current.artistNames)")

        if let index = plan.firstIndex(where: { $0.uri == current.uri }) {
            currentIndex = index
        } else {
            currentIndex = nil
            trace("Ši daina ne iš stoties plano (galbūt paleista ranka Spotify)")
        }

        if let previous {
            recentForRecap.append(previous)
        }
        tracksSinceTalk += 1
        tracksUntilTalk = max(0, talkEvery - tracksSinceTalk)

        if tracksSinceTalk >= talkEvery, let previous {
            tracksSinceTalk = 0
            tracksUntilTalk = talkEvery
            let earlier = Array(recentForRecap.dropLast().suffix(2))
            recentForRecap.removeAll()
            let text = DJScript.handoff(previous: previous, earlier: earlier, next: current)
            Task { await self.talk(text, label: "Perėjimas") }
        }

        await refillIfNeeded()
    }

    /// Kai groja paskutinė plano daina, į Spotify eilę pridedame naujų.
    /// (Spotify eilė groja prieš likusias sąrašo dainas, todėl pildome tik pačiame gale.)
    private func refillIfNeeded() async {
        guard let index = currentIndex, index >= plan.count - 1 else { return }
        let more = takeNext(count: refillSize)
        var added = 0
        for track in more {
            do {
                try await api.addToQueue(uri: track.uri, deviceID: deviceID)
                plan.append(track)
                added += 1
            } catch {
                trace("Į eilę pridėti nepavyko: \(error.localizedDescription)")
                break
            }
        }
        trace("Į eilę pridėta dainų: \(added)")
    }
}
