import Foundation
import UIKit
import AVFoundation

/// Stoties „smegenys“: sudaro sąrašą pagal vibe, paleidžia jį Spotify,
/// seka dainų kaitą, fiksuoja klausymą ir kas N dainų įjungia Dėdį.
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
    @Published private(set) var currentVibe: Vibe = .mix
    @Published private(set) var switchingVibe: Vibe?
    @Published private(set) var isCurrentLiked = false

    let api: SpotifyAPI
    let audio: AudioController
    let voice: DJVoice
    let store: ListeningStore
    let curator: MusicCurator
    let writer: DedisWriter

    private var recentURIs: Set<String> = []
    private var deviceID: String?
    private var monitorTask: Task<Void, Never>?
    private var lastSeenURI: String?
    private var lastSeenTrack: SpotifyTrack?
    private var currentTrackStartedAt: Date?
    private var tracksSinceTalk = 0
    private var recentForRecap: [SpotifyTrack] = []
    private var isTalking = false
    private var wakeCancelled = false
    private var stationPlaylistID: String?
    private var stationPlaylistURI: String?
    private var lastHeartbeat = Date.distantPast

    /// Iš anksto paruoštas Dėdžio perėjimas (tekstas + balsas), kad prabiltų be pauzės.
    private struct PreparedSegment {
        let nextURI: String
        let nextKey: String
        let text: String
        let buffers: [AVAudioPCMBuffer]
    }
    private var prepared: PreparedSegment?
    private var isPreparing = false

    /// Spotify programėlė nemato dainų, pridėtų į jau grojamą grojaraštį,
    /// todėl iš karto sudarome ilgą grojaraštį.
    private let mixPlanSize = 100
    private let vibePlanSize = 40

    init(api: SpotifyAPI, audio: AudioController, voice: DJVoice,
         store: ListeningStore, curator: MusicCurator, writer: DedisWriter) {
        self.api = api
        self.audio = audio
        self.voice = voice
        self.store = store
        self.curator = curator
        self.writer = writer
    }

    private var talkEvery: Int {
        max(1, UserDefaults.standard.integer(forKey: SettingsKeys.talkEvery))
    }

    private func planSize(for vibe: Vibe) -> Int {
        vibe == .mix ? mixPlanSize : vibePlanSize
    }

    // MARK: - Paleidimas

    /// 1. Sudaromas sąrašas (pagal vibe) ir įrašomas į privatų grojaraštį „OnAir Radio“
    ///    (Spotify iPhone programėlė nuo 2026 rudens patikimai groja tik kontekstus).
    /// 2. Bandoma paleisti tiesiogiai; jei Spotify miega – atidarome jį ir kartojame.
    /// 3. Dėdis prabyla tik įsitikinus, kad stotis tikrai groja.
    func start() async {
        guard phase != .starting, phase != .wakingSpotify else { return }
        stopMonitor()
        phase = .starting
        wakeCancelled = false
        prepared = nil
        trace("Stotis: paleidžiama (vibe: \(currentVibe.title))")

        do {
            try await loadPool()
        } catch {
            trace("Stotis: nepavyko gauti dainų – \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard !curator.pool.isEmpty else {
            phase = .failed("Spotify negrąžino tavo „Top“ dainų. Paklausyk muzikos keletą dienų ir bandyk vėl.")
            return
        }

        // Paleidimui naudojame jau paruoštas naujas dainas (akimirksniu), o ne ieškome iš naujo.
        let newPlan = await curator.buildPlan(
            vibe: currentVibe, count: planSize(for: currentVibe), avoid: [], liveDiscovery: currentVibe != .mix
        )
        guard !newPlan.isEmpty else {
            phase = .failed("Nepavyko sudaryti dainų sąrašo.")
            return
        }
        plan = newPlan
        currentIndex = 0

        let playlist: SpotifyPlaylist
        do {
            playlist = try await prepareStationPlaylist(uris: plan.map(\.uri))
        } catch {
            trace("Grojaraščio klaida: \(error.localizedDescription)")
            phase = .failed("Nepavyko paruošti grojaraščio „OnAir Radio“: \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(for: .milliseconds(800))

        let playStation: () async throws -> Void = {
            await self.prepareSpotifyOrder()
            try await self.api.playContext(playlist.uri, position: 0, deviceID: self.deviceID)
        }
        let stationPlays: (SpotifyPlaybackState) -> Bool = { state in
            state.isPlaying && (state.context?.uri?.hasSuffix(playlist.id) ?? false)
        }

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

    private func goOnAir() {
        tracksSinceTalk = 0
        tracksUntilTalk = talkEvery
        recentForRecap = []
        phase = .onAir
        trace("Stotis: eteryje, groja per „\(deviceName ?? "?")“")

        if let first = nowPlaying ?? plan.first {
            Task { await self.talk(.open(first: first, vibe: self.currentVibe)) }
        }
        startMonitor(initialDelay: 2)
        curator.refreshDiscoveryBankInBackground()
    }

    private func loadPool() async throws {
        var seen = Set<String>()
        var collected: [SpotifyTrack] = []
        var shortTerm = Set<String>()
        var longTerm = Set<String>()
        for range in ["short_term", "medium_term", "long_term"] {
            do {
                let tracks = try await api.topTracks(timeRange: range)
                if range == "short_term" { shortTerm = Set(tracks.map(\.uri)) }
                if range == "long_term" { longTerm = Set(tracks.map(\.uri)) }
                for track in tracks where track.spotifyID != nil && seen.insert(track.uri).inserted {
                    collected.append(track)
                }
            } catch {
                trace("Top dainos (\(range)) nepavyko: \(error.localizedDescription)")
                if range == "short_term" { throw error }
            }
        }

        do {
            let recent = try await api.recentlyPlayed()
            recentURIs = Set(recent.map(\.track.uri))
            store.importRecentlyPlayed(recent)
        } catch {
            trace("Neseniai grotų gauti nepavyko (nekritiška): \(error.localizedDescription)")
        }

        let banned = collected.filter { store.isBanned($0) }.count
        curator.setPool(collected, shortTerm: shortTerm, longTerm: longTerm, recent: recentURIs)
        curator.startTaggingInBackground()
        trace("Tavo dainos: \(collected.count) (neseniai grotos: \(recentURIs.count), išmestos 👎: \(banned))")
    }

    /// Paruošia privatų grojaraštį „OnAir Radio“: perrašo jo dainas arba sukuria naują.
    private func prepareStationPlaylist(uris: [String]) async throws -> SpotifyPlaylist {
        let defaults = UserDefaults.standard
        let idKey = "stationPlaylistID"
        let uriKey = "stationPlaylistURI"
        let limited = Array(uris.prefix(100))

        if let id = defaults.string(forKey: idKey), let uri = defaults.string(forKey: uriKey) {
            do {
                try await api.replacePlaylistItems(playlistID: id, uris: limited)
                trace("Grojaraštis „OnAir Radio“ atnaujintas (\(limited.count) dainų)")
                stationPlaylistID = id
                stationPlaylistURI = uri
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
        try await api.replacePlaylistItems(playlistID: created.id, uris: limited)
        trace("Sukurtas grojaraštis „OnAir Radio“ (\(limited.count) dainų)")
        stationPlaylistID = created.id
        stationPlaylistURI = created.uri
        return created
    }

    /// Kad Spotify grotų lygiai mūsų tvarka.
    private func prepareSpotifyOrder() async {
        do { try await api.setShuffle(false, deviceID: deviceID) } catch { trace("Shuffle išjungti nepavyko (nekritiška)") }
        do { try await api.setRepeat("off", deviceID: deviceID) } catch { trace("Repeat išjungti nepavyko (nekritiška)") }
    }

    /// Perrašo grojaraštį nauju sąrašu ir paleidžia jį nuo pradžios (vibe keitimas, sąrašo pabaiga).
    private func replaceAndPlay(_ newPlan: [SpotifyTrack]) async -> Bool {
        do {
            let playlist = try await prepareStationPlaylist(uris: newPlan.map(\.uri))
            try? await Task.sleep(for: .milliseconds(800))
            try await api.playContext(playlist.uri, position: 0, deviceID: deviceID)
            plan = Array(newPlan.prefix(100))
            currentIndex = 0
            prepared = nil
            let ok = await waitForPlayback(matching: { state in
                state.isPlaying && (state.context?.uri?.hasSuffix(playlist.id) ?? false)
            }) != nil
            trace(ok ? "Naujas sąrašas groja" : "Naujo sąrašo patvirtinimo nesulaukta")
            return ok
        } catch {
            trace("Naujo sąrašo paleisti nepavyko: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Spotify žadinimas

    func cancelWake() {
        wakeCancelled = true
    }

    /// Atidaro Spotify programėlę (ji „pabunda“) ir kartoja veiksmą, kol jis tikrai suveikia.
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
                    isCurrentLiked = store.isLiked(item)
                    currentTrackStartedAt = Date().addingTimeInterval(-Double(state.progressMs ?? 0) / 1000)
                }
                isPlaying = state.isPlaying
                progressMs = state.progressMs ?? 0
                progressUpdatedAt = Date()
                return state
            }
        }
        return nil
    }

    // MARK: - Valdymas

    func stop(pauseSpotify: Bool) async {
        wakeCancelled = true
        stopMonitor()
        voice.stop()
        audio.endDuck()
        audio.stopKeepAlive()
        isTalking = false
        onMicText = nil
        prepared = nil
        if pauseSpotify {
            do { try await api.pause(deviceID: deviceID) } catch { trace("Pauzė nepavyko: \(error.localizedDescription)") }
        }
        phase = .idle
        store.saveNow()
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

    /// Pakeičia stoties vibe: Dėdis iškart pakomentuoja, o naujas sąrašas pasileidžia, kai bus paruoštas.
    func switchVibe(_ vibe: Vibe) async {
        guard phase == .onAir, switchingVibe == nil else { return }
        guard vibe != currentVibe || vibe == .discover else { return }
        if vibe != .mix && vibe != .throwback && !curator.hasLastFM {
            trace("Vibe „\(vibe.title)“ reikalauja Last.fm rakto (LASTFM_API_KEY)")
        }

        let previousVibe = currentVibe
        switchingVibe = vibe
        currentVibe = vibe
        trace("Vibe: \(previousVibe.title) → \(vibe.title)")

        let talkTask = Task { await self.talk(.vibeSwitch(from: previousVibe, to: vibe)) }
        var avoid = Set<String>()
        if let current = nowPlaying { avoid.insert(current.uri) }
        let newPlan = await curator.buildPlan(vibe: vibe, count: planSize(for: vibe), avoid: avoid, liveDiscovery: true)

        if newPlan.isEmpty {
            trace("Vibe „\(vibe.title)“: nepavyko rasti dainų – lieku prie „\(previousVibe.title)“")
            currentVibe = previousVibe
        } else {
            // Leidžiame Dėdžiui baigti sakinį prieš perjungiant dainą.
            await talkTask.value
            if await replaceAndPlay(newPlan) {
                tracksSinceTalk = 0
                tracksUntilTalk = talkEvery
                recentForRecap = []
            }
        }
        switchingVibe = nil
        startMonitor(initialDelay: 2)
    }

    /// ❤️ – išsaugo dainą į Spotify „Liked Songs“ ir prisimena, kad patinka.
    func likeCurrent() async {
        guard let track = nowPlaying, !isCurrentLiked else { return }
        store.like(track)
        isCurrentLiked = true
        do {
            try await api.saveToLibrary(uris: [track.uri])
            trace("❤️ \(track.name) – išsaugota į Liked Songs")
        } catch {
            trace("❤️ išsaugoti į Spotify nepavyko: \(error.localizedDescription)")
        }
        if Int.random(in: 0..<10) < 4 {
            await talk(.like(track: track))
        }
    }

    /// 👎 – daina daugiau negros; antras 👎 tam pačiam atlikėjui jį išmeta. Daina praleidžiama.
    func dislikeCurrent() async {
        guard let track = nowPlaying else { return }
        let banned = store.dislike(track)
        trace("👎 \(track.name)" + (banned ? " – atlikėjas \(track.primaryArtist) išmestas" : ""))
        isCurrentLiked = false
        // Kad perėjimas po praleidimo neužsikabintų ant Dėdžio reakcijos.
        tracksSinceTalk = -1
        await skip()
        await talk(.dislike(track: track, artistBanned: banned))
    }

    /// Rankinis Dėdžio įsijungimas.
    func talkNow() async {
        if let track = nowPlaying {
            await talk(.mention(track: track, vibe: currentVibe))
        } else {
            await talk(text: DJScript.voiceTest, label: "Testas")
        }
    }

    /// Balso testas iš nustatymų (veikia ir be paleistos stoties).
    func testVoice() async {
        await talk(text: DJScript.voiceTest, label: "Balso testas")
    }

    /// Kai programėlė grįžta į ekraną – greitai atnaujinti būseną.
    func refreshSoon() {
        guard phase == .onAir else { return }
        startMonitor(initialDelay: 0)
    }

    // MARK: - Dėdis

    private func beginTalking(_ label: String) -> Bool {
        if isTalking {
            trace("Dėdis jau kalba – praleidžiu „\(label)“")
            return false
        }
        isTalking = true
        return true
    }

    private func talk(_ moment: DJMoment) async {
        guard beginTalking(moment.label) else { return }
        let text = await writer.write(moment)
        await perform(text, label: moment.label, buffers: nil)
    }

    private func talk(text: String, label: String, buffers: [AVAudioPCMBuffer]? = nil) async {
        guard beginTalking(label) else { return }
        await perform(text, label: label, buffers: buffers)
    }

    /// Pasako tekstą: patylina Spotify, groja balsą per savo garso variklį, grąžina garsą.
    private func perform(_ text: String, label: String, buffers: [AVAudioPCMBuffer]?) async {
        onMicText = text
        trace("Dėdis [\(label)]: \(text)")

        let backgroundTask = BackgroundTaskHolder()
        backgroundTask.id = UIApplication.shared.beginBackgroundTask(withName: "OnAir DJ") {
            trace("Dėdis: baigėsi iOS skirtas fono laikas")
            backgroundTask.end()
        }
        defer { backgroundTask.end() }

        var audioBuffers: [AVAudioPCMBuffer]
        if let buffers, !buffers.isEmpty {
            audioBuffers = buffers
        } else {
            audioBuffers = await voice.render(text)
        }

        let mode = UserDefaults.standard.string(forKey: SettingsKeys.talkMode) ?? "duck"
        if mode == "pause" && phase == .onAir {
            do { try await api.pause(deviceID: deviceID) } catch { trace("Dėdis: pauzė nepavyko") }
            await speak(text, buffers: audioBuffers)
            do { try await api.resume(deviceID: deviceID) } catch { trace("Dėdis: tęsti nepavyko") }
        } else {
            audio.beginDuck()
            try? await Task.sleep(for: .milliseconds(350))
            await speak(text, buffers: audioBuffers)
            try? await Task.sleep(for: .milliseconds(250))
            audio.endDuck()
        }
        audio.ensureKeepAliveHealthy()
        audioBuffers.removeAll()

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

    /// Likus ~30 s iki dainos pabaigos paruošia Dėdžio perėjimą (tekstą ir balsą).
    private func prefetchHandoffIfNeeded() {
        guard phase == .onAir, !isPreparing, switchingVibe == nil,
              tracksSinceTalk + 1 >= talkEvery,
              let current = nowPlaying,
              let index = currentIndex, index + 1 < plan.count else { return }
        let next = plan[index + 1]
        if prepared?.nextURI == next.uri { return }

        isPreparing = true
        let earlier = Array(recentForRecap.suffix(2))
        let vibe = currentVibe
        Task {
            let text = await self.writer.write(.handoff(previous: current, earlier: earlier, next: next, vibe: vibe))
            let buffers = await self.voice.render(text)
            self.prepared = PreparedSegment(nextURI: next.uri, nextKey: next.matchKey, text: text, buffers: buffers)
            self.isPreparing = false
        }
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
                await handleTrackChange(from: previous, to: item, progressMs: state.progressMs ?? 0)
            }

            guard state.isPlaying else { return 5 }
            let remaining = Double(item.durationMs - (state.progressMs ?? 0)) / 1000
            if remaining < 32 && remaining > 3 {
                prefetchHandoffIfNeeded()
            }
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

    private func handleTrackChange(from previous: SpotifyTrack?, to current: SpotifyTrack, progressMs: Int) async {
        trace("Nauja daina: \(current.name) – \(current.artistNames)")
        let now = Date()

        // Įrašome, kiek klausei ankstesnės ir ar ją praleidai.
        if let previous, let startedAt = currentTrackStartedAt {
            let listened = min(previous.durationMs, Int(now.timeIntervalSince(startedAt) * 1000))
            let skipped = listened < previous.durationMs / 2 && previous.durationMs - listened > 15_000
            store.recordPlay(previous, listenedMs: listened, skipped: skipped, at: now)
            if skipped {
                trace("Praleista po \(listened / 1000) s: \(previous.name)")
            }
        }
        currentTrackStartedAt = now.addingTimeInterval(-Double(progressMs) / 1000)
        isCurrentLiked = store.isLiked(current)

        // 👎 dainos ir išmesti atlikėjai – iškart praleidžiame.
        if store.isBanned(current) {
            trace("Ši daina/atlikėjas išmesti 👎 – praleidžiu")
            do { try await api.next(deviceID: deviceID) } catch { trace("Praleisti nepavyko: \(error.localizedDescription)") }
            return
        }

        let previousIndex = currentIndex
        if let index = planIndex(of: current) {
            currentIndex = index
        } else {
            currentIndex = nil
            trace("Ši daina ne iš stoties plano (galbūt paleista ranka Spotify)")
        }

        if let previous {
            recentForRecap.append(previous)
            if recentForRecap.count > 6 { recentForRecap.removeFirst() }
        }
        tracksSinceTalk += 1
        tracksUntilTalk = max(0, talkEvery - tracksSinceTalk)

        if tracksSinceTalk >= talkEvery, let previous, switchingVibe == nil {
            tracksSinceTalk = 0
            tracksUntilTalk = talkEvery
            if let segment = prepared, segment.nextURI == current.uri || segment.nextKey == current.matchKey {
                prepared = nil
                recentForRecap.removeAll()
                Task { await self.talk(text: segment.text, label: "Perėjimas", buffers: segment.buffers) }
            } else {
                prepared = nil
                let earlier = Array(recentForRecap.dropLast().suffix(2))
                recentForRecap.removeAll()
                let vibe = currentVibe
                Task { await self.talk(.handoff(previous: previous, earlier: earlier, next: current, vibe: vibe)) }
            }
        }

        // Grojaraštis baigėsi ir Spotify įjungė savo „Autoplay“ – paleidžiame naują sąrašą.
        if currentIndex == nil, let previousIndex, previousIndex >= plan.count - 1, switchingVibe == nil {
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
        let key = track.matchKey
        if let index = plan.indices.first(where: { $0 >= searchFrom && plan[$0].matchKey == key }) {
            return index
        }
        return plan.firstIndex { $0.matchKey == key }
    }

    /// Sąrašas baigėsi – sudarome naują to paties vibe ir paleidžiame.
    private func rebuildStation() async {
        trace("Grojaraštis baigėsi – Spotify grojo savo dainas. Paleidžiu naują sąrašą.")
        let avoid = Set(plan.suffix(30).map(\.uri))
        let newPlan = await curator.buildPlan(
            vibe: currentVibe, count: planSize(for: currentVibe), avoid: avoid, liveDiscovery: currentVibe != .mix
        )
        guard !newPlan.isEmpty else { return }
        if await replaceAndPlay(newPlan) {
            await talk(.autoplayRecovery)
        }
        curator.refreshDiscoveryBankInBackground()
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
