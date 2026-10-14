import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: StationEngine

    @AppStorage(SettingsKeys.talkEvery) private var talkEvery = 3
    @AppStorage(SettingsKeys.voiceID) private var voiceID = ""
    @AppStorage(SettingsKeys.speechRate) private var speechRate = 0.5
    @AppStorage(SettingsKeys.talkMode) private var talkMode = "duck"
    @AppStorage(SettingsKeys.voiceEngine) private var voiceEngine = "kokoro"
    @AppStorage(SettingsKeys.kokoroVoice) private var kokoroVoice = KokoroEngine.defaultVoice
    @AppStorage(KokoroCrashGuard.crashedStageKey) private var kokoroCrashedStage = ""
    @ObservedObject private var kokoroModel = KokoroModelStore.shared

    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $talkEvery, in: 1...6) {
                        Text("Dėdis įsijungia po \(talkEveryPhrase)")
                    }
                    Picker("Kai Dėdis kalba", selection: $talkMode) {
                        Text("Patylinti muziką").tag("duck")
                        Text("Sustabdyti muziką").tag("pause")
                    }
                } header: {
                    Text("Dėdis")
                } footer: {
                    Text("„Patylinti“ – kaip tikrame radijuje, Dėdis kalba ant dainos pradžios. Jei patylinimas neveikia, rinkis „Sustabdyti“.")
                }

                Section {
                    Picker("Balso variklis", selection: $voiceEngine) {
                        Text("Kokoro (neuroninis)").tag("kokoro")
                        Text("Apple").tag("apple")
                    }

                    if !kokoroCrashedStage.isEmpty {
                        Text("Kokoro anksčiau užlūžo („\(kokoroCrashedStage)“), todėl įjungtas Apple balsas. Atsiųsk žurnalą – pataisysiu.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if voiceEngine == "kokoro" {
                        kokoroModelRow
                        Picker("Kokoro balsas", selection: $kokoroVoice) {
                            ForEach(KokoroEngine.voiceNames) { voice in
                                Text(voice.title).tag(voice.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } else {
                        Picker("Apple balsas", selection: $voiceID) {
                            Text("Automatiškai (geriausias)").tag("")
                            ForEach(voices, id: \.identifier) { voice in
                                Text("\(voice.name) · \(voice.language) · \(DJVoice.qualityLabel(voice))")
                                    .tag(voice.identifier)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kalbėjimo greitis")
                        HStack {
                            Image(systemName: "tortoise")
                            Slider(value: $speechRate, in: 0.42...0.58)
                            Image(systemName: "hare")
                        }
                        .foregroundStyle(Theme.muted)
                    }

                    Button {
                        Task { await engine.testVoice() }
                    } label: {
                        Label("Išbandyti balsą", systemImage: "speaker.wave.2.fill")
                    }
                } header: {
                    Text("Balsas")
                } footer: {
                    if voiceEngine == "kokoro" {
                        Text("Kokoro – neuroninis balsas, veikiantis pačiame telefone, be interneto ir be limitų. Modelį (327 MB) reikia atsisiųsti vieną kartą, geriausia per Wi-Fi. Kol jo nėra, Dėdis kalba Apple balsu.")
                    } else {
                        Text("Natūralesnius Apple balsus galima nemokamai atsisiųsti: iPhone Nustatymai → Pritaikymas neįgaliesiems → Įgarsinamas turinys → Balsai → English. Rinkis „Enhanced“ arba „Premium“.")
                    }
                }

                Section("Spotify") {
                    Button(role: .destructive) {
                        Task {
                            await engine.stop(pauseSpotify: false)
                            auth.logout()
                        }
                    } label: {
                        Text("Atsijungti nuo Spotify")
                    }
                }

                Section("Paslaugos") {
                    statusRow("Last.fm (vibe, atradimai)", ok: !Config.lastFMAPIKey.isEmpty)
                    statusRow("Groq (Dėdžio tekstai)", ok: !Config.groqAPIKey.isEmpty)
                }

                Section {
                    Text("OnAir 0.3 · 3 etapas")
                        .foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Nustatymai")
            .onChange(of: voiceEngine) { _, newValue in
                if newValue == "kokoro" { kokoroCrashedStage = "" }
            }
            .onAppear {
                voices = DJVoice.englishVoices()
            }
        }
    }

    @ViewBuilder
    private var kokoroModelRow: some View {
        switch kokoroModel.state {
        case .ready:
            HStack {
                Text("Modelis")
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.spotifyGreen)
                Text("Paruoštas")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        case .missing:
            Button {
                kokoroModel.download()
            } label: {
                Label("Atsisiųsti balso modelį (327 MB)", systemImage: "arrow.down.circle.fill")
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Siunčiama…")
                    Spacer()
                    Text("\(Int(progress * 100)) %")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Button("Atšaukti", role: .cancel) {
                    kokoroModel.cancel()
                }
                .font(.footnote)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Nepavyko: \(message)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button {
                    kokoroModel.download()
                } label: {
                    Label("Bandyti dar kartą", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Theme.spotifyGreen : .orange)
            Text(ok ? "Prijungta" : "Nėra rakto")
                .foregroundStyle(Theme.muted)
                .font(.footnote)
        }
    }

    private var talkEveryPhrase: String {
        talkEvery == 1 ? "kiekvienos dainos" : "\(talkEvery) dainų"
    }
}
