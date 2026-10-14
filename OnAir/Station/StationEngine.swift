import Foundation
import UIKit

/// Stoties „smegenys“: parenka dainas, paleidžia jas Spotify, seka dainų kaitą
/// ir kas N dainų įjungia DJ.
@MainActor
final class StationEngine: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        /// Spotify programėlė miegojo – atidarėme ją ir laukiame, kol pradės groti.
        case wakingSpotify
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
    private var wakeCancelled = false
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

    /// Paleidimo eiga:
    /// 1. Sudaromas dainų sąrašas.
    /// 2. Jei Spotify šiame telefone jau groja (vadinasi, nemiega) – siunčiame sąrašą tiesiai.
    /// 3. Kitaip Spotify programėlė greičiausiai užmigdyta: komanda per serverį „praeitų“,
    ///    bet muzika nepasileistų. Todėl pirmiausia atidarome Spotify ir tik tada siunčiame.
    /// 4. DJ prabyla tik įsitikinus, kad pirma daina tikrai groja.
    func start() async {
        guard phase != .starting, phase != .wakingSpotify else { return }
        stopMonitor()
        phase = .starting
        wakeCancelled = false
        trace("Stotis: paleidžiama")

        do {
            try await loadPool()
        } catch {
            trace("Stotis: nepavyko gauti dainų – \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard !pool.isEmpty else {
            phase = .failed("Spotify negrąžino tavo „Top“ dainų. Paklausyk muzikos keletą dienų ir bandyk vėl.")
            return
        }

        usedURIs.removeAll()
        plan = []
        plan = takeNext(count: initialPlanSize)
        currentIndex = 0
        guard let firstURI = plan.first?.uri else {
            phase = .failed("Nepavyko sudaryti dainų sąrašo.")
            return
        }

        // Fono palaikymas reikalingas jau dabar: kol Spotify bus atidarytas priekyje,
        // OnAir turi likti gyva fone ir užbaigti paleidimą.
        audio.startKeepAlive()

        let uris = plan.map(\.uri)
        let playStation: () async throws -> Void = {
            await self.prepareSpotifyOrder()
            try await self.api.play(uris: uris, deviceID: self.deviceID)
        }
        let firstTrackPlays: (SpotifyPlaybackState) -> Bool = { state in
            state.isPlaying && state.item?.uri == firstURI
        }

        // Ar Spotify šiame telefone jau groja?
        var started = false
        if let state = try? await api.playbackState(),
           state.isPlaying,
           let device = state.device, device.type == "Smartphone", let id = device.id {
            deviceID = id
            deviceName = device.name
            trace("Spotify jau groja telefone – siunčiu sąrašą tiesiai")
            do {
                try await playStation()
                started = await waitForPlayback(matching: firstTrackPlays) != nil
            } catch {
                trace("Tiesioginis paleidimas nepavyko: \(error.localizedDescription)")
            }
        } else {
            trace("Spotify šiame telefone negroja – greičiausiai miega")
        }

        if !started {
            phase = .wakingSpotify
            started = await wakeSpotifyAndRetry("paleidimas", action: playStation, verify: firstTrackPlays)
        }

        guard started else {
            if wakeCancelled {
                trace("Paleidimas atšauktas")
                phase = .idle
            } else {
                trace("Stotis: Spotify nepradėjo groti")
                phase = .needsSpotify
            }
            audio.stopKeepAlive()
            return
        }

        goOnAir()
    }

    /// Atšaukia Spotify žadinimą (mygtukas ekrane).
    func cancelWake() {
        wakeCancelled = true
    }

    private func goOnAir() {
        tracksSinceTalk = 0
        tracksUntilTalk = talkEvery
        recentForRecap = []
        phase = .onAir
        trace("Stotis: eteryje, groja per „\(deviceName ?? "?")“")

        if let first = plan.first {
            let opening = DJScript.stationOpen(first: first)
            Task { await self.talk(opening, label: "Atidarymas") }
        }
        startMonitor(initialDelay: 2)
    }

    /// Kad Spotify grotų lygiai mūsų tvarka.
    private func prepareSpotifyOrder() async {
        do { try await api.setShuffle(false, deviceID: deviceID) } catch { trace("Shuffle išjungti nepavyko (nekritiška)") }
        do { try await api.setRepeat("off", deviceID: deviceID) } catch { trace("Repeat išjungti nepavyko (nekritiška)") }
    }

    // MARK: - Spotify žadinimas

    /// Atidaro Spotify programėlę (ji „pabunda“) ir kartoja veiksmą, kol jis tikrai suveikia.
    /// OnAir tuo metu veikia fone. Grąžina true, jei pavyko.
    private func wakeSpotifyAndRetry(
        _ label: String,
        action: () async throws -> Void,
        verify: (SpotifyPlaybackState) -> Bool
    ) async -> Bool {
        guard let url = URL(string: "spotify:") else { return false }
        trace("Atidarau Spotify, kad pabustų (\(label))")
        let opened = await UIApplication.shared.open(url)
        guard opened else {
            trace("Nepavyko atidaryti Spotify programėlės")
            return false
        }

        for attempt in 1...6 {
            try? await Task.sleep(for: .seconds(attempt == 1 ? 2.5 : 2.0))
            if wakeCancelled { return false }

            if let device = try? await findDevice(phoneOnly: true) {
                deviceID = device.id
                deviceName = device.name
            } else {
                trace("Bandymas \(attempt): telefono dar nematyti tarp įrenginių")
                continue
            }

            do {
                try await action()
            } catch {
                trace("Bandymas \(attempt): \(error.localizedDescription)")
                continue
            }

            if await waitForPlayback(matching: verify) != nil {
                trace("Spotify pabudo ir groja (bandymas \(attempt))")
                return true
            }
            trace("Bandymas \(attempt): komanda priimta, bet muzika dar negroja")
        }
        return false
    }

    /// Kelias sekundes tikrina grotuvo būseną, kol ji atitinka sąlygą.
    private func waitForPlayback(matching verify: (SpotifyPlaybackState) -> Bool) async -> SpotifyPlaybackState? {
        for _ in 0..<7 {
            try? await Task.sleep(for: .milliseconds(700))
            if wakeCancelled { return nil }
            guard let state = try? await api.playbackState() else { continue }
            if verify(state) {
                if let item = state.item {
                    lastSeenURI = item.uri
                    lastSeenTrack = item
                    nowPlaying = item
                }
                isPlaying = state.isPlaying
                progressMs = state.progressMs ?? 0
                progressUpdatedAt = Date()
                return state
            }
        }
        return nil
    }

    func stop(pauseSpotify: Bool) async {
        wakeCancelled = true
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
        if isPlaying {
            do {
                try await api.pause(deviceID: deviceID)
                isPlaying = false
            } catch {
                trace("Pauzės klaida: \(error.localizedDescription)")
            }
            startMonitor(initialDelay: 1)
            return
        }

        // Tęsti: jei Spotify per pauzę užmigo, komanda nesuveiks – tada pažadiname.
        var resumed = false
        wakeCancelled = false
        do {
            try await api.resume(deviceID: deviceID)
            resumed = await waitForPlayback(matching: { $0.isPlaying }) != nil
        } catch {
            trace("Tęsti nepavyko: \(error.localizedDescription)")
        }
        if !resumed {
            resumed = await wakeSpotifyAndRetry(
                "tęsimas",
                action: { try await self.api.resume(deviceID: self.deviceID) },
                verify: { $0.isPlaying }
            )
        }
        if !resumed {
            trace("Spotify nepavyko pažadinti – atidaryk Spotify ir paspausk groti")
        }
        startMonitor(initialDelay: 1)
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

    private func findDevice(phoneOnly: Bool = false) async throws -> SpotifyDevice? {
        let devices = try await api.devices()
        if devices.isEmpty {
            trace("Įrenginių sąrašas tuščias")
        } else {
            let summary = devices.map { "\($0.name) [\($0.type)\($0.isActive ? ", aktyvus" : "")]" }
            trace("Įrenginiai: " + summary.joined(separator: "; "))
        }
        let usable = devices.filter { $0.id != nil && $0.isRestricted != true }
        let phone = usable.first { $0.type == "Smartphone" && $0.isActive }
            ?? usable.first { $0.type == "Smartphone" }
        if phoneOnly { return phone }
        return phone ?? usable.first { $0.isActive }
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
