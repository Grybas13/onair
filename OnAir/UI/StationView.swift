import SwiftUI

struct StationView: View {
    @EnvironmentObject private var engine: StationEngine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        header
                        statusCard
                        if engine.phase == .onAir {
                            vibeBar
                            nowPlayingCard
                            onMicCard
                            controls
                            upNext
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            engine.refreshSoon()
        }
    }

    // MARK: - Antraštė

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("OnAir")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                if let device = engine.deviceName, engine.phase == .onAir {
                    Text("Groja per \(device)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            OnAirBadge(live: engine.onMicText != nil)
        }
        .padding(.top, 12)
    }

    // MARK: - Būsena

    @ViewBuilder
    private var statusCard: some View {
        switch engine.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text("Stotis išjungta")
                    .font(.title3.bold())
                Text("\(DJIdentity.name) sudarys sąrašą iš tavo mėgstamų Spotify dainų, įmes naujų atradimų ir kas kelias dainas pasakys, ką apie tave galvoja.")
                    .foregroundStyle(Theme.muted)
                primaryButton("Įjungti stotį", systemImage: "play.fill") {
                    Task { await engine.start() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

        case .starting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Ruošiu eterį…")
                    .font(.headline)
                Spacer()
            }
            .card()

        case .wakingSpotify:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Žadinu Spotify…")
                        .font(.headline)
                }
                Text("Spotify programėlė miegojo, todėl ją atidarėme. Kai muzika pradės groti ir DJ prabils, grįžk į OnAir (viršuje kairėje „◀ OnAir“).")
                    .foregroundStyle(Theme.muted)
                Button("Atšaukti") {
                    engine.cancelWake()
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

        case .needsSpotify:
            VStack(alignment: .leading, spacing: 12) {
                Text("Spotify nepradėjo groti")
                    .font(.title3.bold())
                Text("Atidaryk Spotify, paleisk bet kurią dainą, grįžk čia ir spausk „Bandyti dar kartą“. Daugiau informacijos – skirtuke „Žurnalas“.")
                    .foregroundStyle(Theme.muted)
                primaryButton("Bandyti dar kartą", systemImage: "arrow.clockwise") {
                    Task { await engine.start() }
                }
                Button("Atidaryti Spotify") {
                    if let url = URL(string: "spotify:") {
                        openURL(url)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("Nepavyko įjungti")
                    .font(.title3.bold())
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text("Daugiau informacijos – skirtuke „Žurnalas“.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                primaryButton("Bandyti dar kartą", systemImage: "arrow.clockwise") {
                    Task { await engine.start() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

        case .onAir:
            EmptyView()
        }
    }

    // MARK: - Vibe

    private var vibeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Vibe.allCases) { vibe in
                    let isActive = engine.currentVibe == vibe
                    let isLoading = engine.switchingVibe == vibe
                    Button {
                        Task { await engine.switchVibe(vibe) }
                    } label: {
                        HStack(spacing: 6) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                            } else {
                                Image(systemName: vibe.icon)
                                    .font(.caption)
                            }
                            Text(vibe.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(isActive ? Theme.accent : Theme.card))
                        .overlay(Capsule().stroke(isActive ? Color.clear : Theme.cardStroke, lineWidth: 1))
                        .foregroundStyle(.white)
                    }
                    .disabled(engine.switchingVibe != nil)
                    .accessibilityLabel("Vibe \(vibe.title)")
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Dabar groja

    private var nowPlayingCard: some View {
        VStack(spacing: 14) {
            AsyncImage(url: engine.nowPlaying?.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Theme.card
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 240, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)

            VStack(spacing: 4) {
                Text(engine.nowPlaying.map { DJScript.cleanTitle($0.name) } ?? "—")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(engine.nowPlaying?.artistNames ?? "")
                    .font(.headline)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            progressBar

            HStack(spacing: 12) {
                Button {
                    Task { await engine.dislikeCurrent() }
                } label: {
                    Label("Nepatinka", systemImage: "hand.thumbsdown.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.card))
                }
                Button {
                    Task { await engine.likeCurrent() }
                } label: {
                    Label("Patinka",
                          systemImage: engine.isCurrentLiked ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(engine.isCurrentLiked ? Theme.accent.opacity(0.85) : Theme.card))
                }
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = engine.nowPlaying?.durationMs ?? 0
            let elapsed = engine.isPlaying ? Int(context.date.timeIntervalSince(engine.progressUpdatedAt) * 1000) : 0
            let position = min(duration, engine.progressMs + max(0, elapsed))
            let fraction = duration > 0 ? Double(position) / Double(duration) : 0

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 5)

                HStack {
                    Text(formatDuration(ms: position))
                    Spacer()
                    Text(formatDuration(ms: duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - DJ eteryje

    @ViewBuilder
    private var onMicCard: some View {
        if let text = engine.onMicText {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(DJIdentity.name) eteryje")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                    Text(text)
                        .font(.callout)
                }
                Spacer(minLength: 0)
            }
            .card()
            .transition(.opacity)
        }
    }

    // MARK: - Valdymas

    private var controls: some View {
        HStack(spacing: 12) {
            controlButton(engine.isPlaying ? "pause.fill" : "play.fill", label: engine.isPlaying ? "Pauzė" : "Groti") {
                Task { await engine.togglePlayPause() }
            }
            controlButton("forward.fill", label: "Praleisti") {
                Task { await engine.skip() }
            }
            controlButton(engine.isSwitchingUp ? "hourglass" : "arrow.triangle.2.circlepath", label: "Keisti") {
                Task { await engine.switchItUp() }
            }
            controlButton("stop.fill", label: "Išjungti") {
                Task { await engine.stop(pauseSpotify: true) }
            }
        }
    }

    // MARK: - Toliau eteryje

    private var upNext: some View {
        let upcoming = upcomingTracks()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Toliau eteryje")
                    .font(.headline)
                Spacer()
                if engine.tracksUntilTalk > 0 {
                    Text("DJ po \(engine.tracksUntilTalk) d.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }

            if upcoming.isEmpty {
                Text("Eilė pasipildys automatiškai.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }

            ForEach(Array(upcoming.enumerated()), id: \.element.track.uri) { offset, entry in
                if entry.djBefore {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                        Text("\(DJIdentity.name) eteryje")
                            .font(.caption.bold())
                        Spacer()
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 2)
                }
                HStack(spacing: 12) {
                    Text(entry.airTime, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DJScript.cleanTitle(entry.track.name))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(entry.track.artistNames)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                if offset < upcoming.count - 1 {
                    Divider().overlay(Theme.cardStroke)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private struct UpcomingEntry {
        let track: SpotifyTrack
        let airTime: Date
        let djBefore: Bool
    }

    /// Būsimos dainos su apytiksliu eterio laiku, kaip radijo tvarkaraštyje.
    private func upcomingTracks() -> [UpcomingEntry] {
        guard let index = engine.currentIndex, index + 1 < engine.plan.count else { return [] }
        let current = engine.plan[index]
        let elapsed = engine.isPlaying ? Int(Date().timeIntervalSince(engine.progressUpdatedAt) * 1000) : 0
        let remainingMs = max(0, current.durationMs - (engine.progressMs + elapsed))
        var start = Date().addingTimeInterval(Double(remainingMs) / 1000)

        let talkEvery = DJStyle.talkEvery
        var entries: [UpcomingEntry] = []
        for (offset, track) in engine.plan[(index + 1)...].prefix(10).enumerated() {
            let position = offset + 1
            let djBefore = position == engine.tracksUntilTalk
                || (position > engine.tracksUntilTalk && (position - engine.tracksUntilTalk) % talkEvery == 0)
            entries.append(UpcomingEntry(track: track, airTime: start, djBefore: djBefore))
            start = start.addingTimeInterval(Double(track.durationMs) / 1000)
        }
        return entries
    }

    // MARK: - Mygtukai

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Theme.accent))
                .foregroundStyle(.white)
        }
    }

    private func controlButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }
}
