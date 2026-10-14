import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: StationEngine

    @AppStorage(SettingsKeys.talkEvery) private var talkEvery = 3
    @AppStorage(SettingsKeys.voiceID) private var voiceID = ""
    @AppStorage(SettingsKeys.speechRate) private var speechRate = 0.5
    @AppStorage(SettingsKeys.talkMode) private var talkMode = "duck"

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
                    Text("DJ")
                } footer: {
                    Text("„Patylinti“ – kaip tikrame radijuje, DJ kalba ant dainos pradžios. Jei patylinimas neveikia, rinkis „Sustabdyti“.")
                }

                Section {
                    Picker("Balsas", selection: $voiceID) {
                        Text("Automatiškai (geriausias)").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) · \(voice.language) · \(DJVoice.qualityLabel(voice))")
                                .tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)

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
                    Text("Natūralesnius balsus galima nemokamai atsisiųsti: iPhone Nustatymai → Pritaikymas neįgaliesiems → Įgarsinamas turinys → Balsai → English. Rinkis „Enhanced“ arba „Premium“, tada grįžk čia.")
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
                    Text("OnAir 0.2 · 2 etapas")
                        .foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Nustatymai")
            .onAppear {
                voices = DJVoice.englishVoices()
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
