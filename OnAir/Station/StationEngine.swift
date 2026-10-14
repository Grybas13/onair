import Foundation
import UIKit
import AVFoundation

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
    private var stationPlaylistID: String?
    private var lastHeartbeat = Date.distantPast
    /// Spotify programėlė nemato dainų, pridėtų į jau grojamą grojaraštį,
    /// todėl iš karto sudarome ilgą (~6 val.) grojaraštį.
    private let initialPlanSize = 100

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
    /// 1. Sudaromas dainų sąrašas ir įrašomas į privatų grojaraštį „OnAir Radio“.
    ///    (Spotify iPhone programėlė nuo 2026 rudens patikimai groja tik kontekstus –
    ///    grojaraščius ar albumus –, o ne „plikus“ dainų sąrašus.)
    /// 2. Bandoma paleisti tiesiogiai. Jei Spotify telefone miega ir muzika nepasileidžia,
    ///    atidarome Spotify programėlę ir kartojame.
    /// 3. DJ prabyla tik įsitikinus, kad stotis tikrai groja.
    /// Fono palaikymas (tyla) įjungiamas tik tada, kai Spotify jau groja – kad netrukdytų
    /// Spotify pradėti grojimą fone.
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
        guard !plan.isEmpty else {
            phase = .failed("Nepavyko sudaryti dainų sąrašo.")
            return
        }

        let playlist: SpotifyPlaylist
        do {
            playlist = try await prepareStationPlaylist(uris: plan.map(\.uri))
        } catch {
            trace("Grojaraščio klaida: \(error.localizedDescription)")
            phase = .failed("Nepavyko paruošti grojaraščio „OnAir Radio“: \(error.localizedDescription)")
            return
        }
        stationPlaylistID = playlist.id
        // Leidžiame Spotify serveriams „pamatyti“ atnaujintą grojaraštį.
        try? await Task.sleep(for: .milliseconds(800))

        let playStation: () async throws -> Void = {
            await self.prepareSpotifyOrder()
            try await self.api.playContext(playlist.uri, position: 0, deviceID: self.deviceID)
        }
        let stationPlays: (SpotifyPlaybackState) -> Bool = { state in
            state.isPlaying && (state.context?.uri?.hasSuffix(playlist.id) ?? false)
        }

        // 1. Tiesiogiai
        var started = false
        if let state = try? await api.playbackState() {
            trace("Spotify būsena prieš paleidimą: \(state.summary)")
        } else {
            trace("Spotify būsena prieš paleidimą: nieko negroja")
        }
        if let device = try? await findDevice(phoneOnly: true) {
            deviceID = device.id
            deviceName = device.name
            do {
                try await playStation()
                started = await waitForPlayback(matching: stationPlays) != nil
            } catch {
                trace("Tiesioginis paleidimas nepavyko: \(error.localizedDescription)")
            }
            if !started {
                trace("Tiesiogiai nepasileido – Spotify greičiausiai miega")
            }
        } else {
            trace("Telefono nėra tarp Spotify įrenginių")
        }

        // 2. Žadinimas
        if !started {
            phase = .wakingSpotify
            // Kol Spotify atidarytas priekyje, OnAir turi išlikti gyva fone.
            audio.startKeepAlive()
            started = await wakeSpotifyAndRetry("paleidimas", action: playStation, verify: stationPlays)
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

        audio.startKeepAlive()
        goOnAir()
    }

    /// Paruošia privatų grojaraštį „OnAir Radio“: perrašo jo dainas arba sukuria naują.
    private func prepareStationPlaylist(uris: [String]) async throws -> SpotifyPlaylist {
        let defaults = UserDefaults.standard
        let idKey = "stationPlaylistID"
        let uriKey = "stationPlaylistURI"

        if let id = defaults.string(forKey: idKey), let uri = defaults.string(forKey: uriKey) {
            do {
                try await api.replacePlaylistItems(playlistID: id, uris: uris)
                trace("Grojaraštis „OnAir Radio“ atnaujintas (\(uris.count) dainų)")
                return SpotifyPlaylist(id: id, uri: uri, name: "OnAir Radio")
            } catch let error as SpotifyAPIError where error.status == 404 || error.status == 403 {
                trace("Senas grojaraštis nepasiekiamas (\(error.status ?? 0)) – kuriu naują")
            }
        }

        let created = try await api.createPlaylist(
            name: "OnAir Radio",
            description: "Tavo OnAir stotis. Šį grojaraštį OnAir atnaujina automatiškai."
        )
        defaults.set(created.id, forKey: idKey)
        defaults.set(created.uri, forKey: uriKey)
        try await api.replacePlaylistItems(playlistID: created.id, uris: uris)
        trace("Sukurtas grojaraštis „OnAir Radio“ (\(uris.count) dainų)")
        return created
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
        var lastState: SpotifyPlaybackState?
        defer {
            if let lastState, !verify(lastState) {
                trace("Paskutinė matyta būsena: \(lastState.summary)")
            }
        }
        for _ in 0..<7 {
            try? await Task.sleep(for: .milliseconds(700))
            if wakeCancelled { return nil }
            guard let state = try? await api.playbackState() else { continue }
            lastState = state
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
        // Tylos grotuvą trumpam išjungiame, kad netrukdytų Spotify pradėti grojimą.
        var resumed = false
        wakeCancelled = false
        audio.stopKeepAlive()
        do {
            try await api.resume(deviceID: deviceID)
            resumed = await waitForPlayback(matching: { $0.isPlaying }) != nil
        } catch {
            trace("Tęsti nepavyko: \(error.localizedDescription)")
        }
        if !resumed {
            audio.startKeepAlive()
            resumed = await wakeSpotifyAndRetry(
                "tęsimas",
                action: { try await self.api.resume(deviceID: self.deviceID) },
                verify: { $0.isPlaying }
            )
        }
        if !resumed {
            trace("Spotify nepavyko pažadinti – atidaryk Spotify ir paspausk groti")
        }
        if phase == .onAir {
            audio.startKeepAlive()
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

        // Papildomas laikas fone, kol perjungiame garso nustatymus ir kalbame.
        let backgroundTask = BackgroundTaskHolder()
        backgroundTask.id = UIApplication.shared.beginBackgroundTask(withName: "OnAir DJ") {
            trace("DJ: baigėsi iOS skirtas fono laikas")
            backgroundTask.end()
        }
        defer { backgroundTask.end() }

        // Balsą paruošiame iš anksto ir grojame per savo garso variklį,
        // kad Apple balso variklis nekeistų garso sesijos.
        let buffers = await voice.render(text)

        let mode = UserDefaults.standard.string(forKey: SettingsKeys.talkMode) ?? "duck"
        if mode == "pause" && phase == .onAir {
            do { try await api.pause(deviceID: deviceID) } catch { trace("DJ: pauzė nepavyko") }
            await speak(text, buffers: buffers)
            do { try await api.resume(deviceID: deviceID) } catch { trace("DJ: tęsti nepavyko") }
        } else {
            audio.beginDuck()
            try? await Task.sleep(for: .milliseconds(350))
            await speak(text, buffers: buffers)
            try? await Task.sleep(for: .milliseconds(250))
            audio.endDuck()
        }
        audio.ensureKeepAliveHealthy()

        onMicText = nil
        isTalking = false
    }

    private func speak(_ text: String, buffers: [AVAudioPCMBuffer]) async {
        if buffers.isEmpty {
            await voice.speak(text)
        } else {
            await audio.playSpeech(buffers)
        }
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

    /// Paima kitas dainas: be pasikartojimų, neseniai grotas dedant į galą
    /// ir vengiant to paties atlikėjo dviejų dainų iš eilės.
    private func takeNext(count: Int) -> [SpotifyTrack] {
        var candidates = pool.filter { !usedURIs.contains($0.uri) }
        if candidates.isEmpty {
            trace("Baseinas išsemtas – pradedu ratą iš naujo")
            usedURIs = Set(plan.suffix(20).map(\.uri))
            candidates = pool.filter { !usedURIs.contains($0.uri) }
        }

        let fresh = candidates.filter { !recentURIs.contains($0.uri) }.shuffled()
        let recent = candidates.filter { recentURIs.contains($0.uri) }.shuffled()
        var bag = fresh + recent

        var result: [SpotifyTrack] = []
        var lastArtist = plan.last?.primaryArtist
        while result.count < count, !bag.isEmpty {
            let window = bag.prefix(15)
            let index = window.firstIndex { $0.primaryArtist != lastArtist } ?? bag.startIndex
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
        audio.ensureKeepAliveHealthy()
        if Date().timeIntervalSince(lastHeartbeat) > 120 {
            lastHeartbeat = Date()
            let state = UIApplication.shared.applicationState == .background ? "fone" : "ekrane"
            trace("Gyvas (\(state)) · garso variklis: \(audio.isEngineRunning ? "veikia" : "SUSTOJĘS")")
        }
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
        } catch is CancellationError {
            return 1
        } catch let error as URLError where error.code == .cancelled {
            return 1
        } catch {
            trace("Stebėjimo klaida: \(error.localizedDescription)")
            return 8
        }
    }

    private func handleTrackChange(from previous: SpotifyTrack?, to current: SpotifyTrack) async {
        trace("Nauja daina: \(current.name) – \(current.artistNames)")

        let previousIndex = currentIndex
        if let index = planIndex(of: current) {
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

        // Grojaraštis baigėsi ir Spotify įjungė savo „Autoplay“ – paleidžiame naują stoties sąrašą.
        if currentIndex == nil, let previousIndex, previousIndex >= plan.count - 1 {
            await rebuildStation()
        }
    }

    /// Randa dainą plane. Spotify kartais groja kitą tos pačios dainos versiją (kitas ID),
    /// todėl, neradus pagal URI, ieškome pagal pavadinimą ir atlikėją.
    private func planIndex(of track: SpotifyTrack) -> Int? {
        let searchFrom = currentIndex ?? 0
        if let index = plan.indices.first(where: { $0 >= searchFrom && plan[$0].uri == track.uri }) {
            return index
        }
        if let index = plan.firstIndex(where: { $0.uri == track.uri }) {
            return index
        }
        let key = Self.matchKey(track)
        if let index = plan.indices.first(where: { $0 >= searchFrom && Self.matchKey(plan[$0]) == key }) {
            return index
        }
        return plan.firstIndex { Self.matchKey($0) == key }
    }

    private static func matchKey(_ track: SpotifyTrack) -> String {
        DJScript.cleanTitle(track.name).lowercased() + "|" + track.primaryArtist.lowercased()
    }

    /// Sudaro naują dainų sąrašą, perrašo grojaraštį ir paleidžia jį nuo pradžios.
    private func rebuildStation() async {
        trace("Grojaraštis baigėsi – Spotify grojo savo dainas. Paleidžiu naują sąrašą.")
        let newPlan = takeNext(count: initialPlanSize)
        guard !newPlan.isEmpty else { return }
        do {
            let playlist = try await prepareStationPlaylist(uris: newPlan.map(\.uri))
            stationPlaylistID = playlist.id
            plan = newPlan
            currentIndex = 0
            try? await Task.sleep(for: .milliseconds(800))
            try await api.playContext(playlist.uri, position: 0, deviceID: deviceID)
            let ok = await waitForPlayback(matching: { state in
                state.isPlaying && (state.context?.uri?.hasSuffix(playlist.id) ?? false)
            }) != nil
            trace(ok ? "Naujas sąrašas groja" : "Naujo sąrašo patvirtinimo nesulaukta")
        } catch {
            trace("Naujo sąrašo paleisti nepavyko: \(error.localizedDescription)")
        }
    }
}

/// Laiko iOS fono užduoties ID, kad ją būtų galima užbaigti ir iš jos pačios pabaigos bloko.
final class BackgroundTaskHolder {
    var id: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
