import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: StationEngine

    @AppStorage(SettingsKeys.talkEvery) private var talkEvery = 3
    @AppStorage(SettingsKeys.voiceID) private var voiceID = ""
    @AppStorage(SettingsKeys.speechRate) private var speechRate = 0.5
    @AppStorage(SettingsKeys.talkMode) private var talkMode = "duck"
    @AppStorage(SettingsKeys.voiceEngine) private var voiceEngine = "groq"
    @AppStorage(SettingsKeys.groqVoice) private var groqVoice = GroqSpeech.defaultVoice
    @AppStorage(DJIdentity.key) private var djName = ""
    @State private var diagnosis: String?
    @State private var backgroundTestRunning = false
    @State private var isDiagnosing = false

    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Vardas")
                        TextField(DJIdentity.defaultName, text: $djName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                    Stepper(value: $talkEvery, in: 1...6) {
                        Text("Kalba po \(talkEveryPhrase)")
                    }
                    Picker("Kai DJ kalba", selection: $talkMode) {
                        Text("Patylinti muziką").tag("duck")
                        Text("Sustabdyti muziką").tag("pause")
                    }
                } header: {
                    Text("DJ")
                } footer: {
                    Text("Vardą DJ naudoja kalbėdamas (angliškas vardas tariamas geriausiai). „Patylinti“ – kaip tikrame radijuje, DJ kalba ant dainos pradžios.")
                }

                Section {
                    Picker("Balso variklis", selection: $voiceEngine) {
                        Text("Groq Orpheus (gyvas)").tag("groq")
                        Text("Apple").tag("apple")
                    }

                    if voiceEngine == "groq" {
                        Picker("Orpheus balsas", selection: $groqVoice) {
                            ForEach(GroqSpeech.voices) { voice in
                                Text(voice.title).tag(voice.id)
                            }
                        }
                    }

                    Picker("Atsarginis Apple balsas", selection: $voiceID) {
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

                    Button {
                        Task {
                            backgroundTestRunning = true
                            await engine.backgroundTest()
                            backgroundTestRunning = false
                        }
                    } label: {
                        HStack {
                            Label("Fono testas", systemImage: "lock.fill")
                            if backgroundTestRunning {
                                Spacer()
                                Text("Užrakink telefoną…")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .disabled(backgroundTestRunning)
                } header: {
                    Text("Balsas")
                } footer: {
                    Text("Orpheus – gyvas, emocingas balsas Groq debesyje (tas pats Groq raktas). Nemokamai ~100 pasisakymų per dieną; pasiekus limitą DJ kalba Apple balsu. Natūralesnį Apple balsą galima atsisiųsti: iPhone Nustatymai → Pritaikymas neįgaliesiems → Įgarsinamas turinys → Balsai → English (Enhanced / Premium). Kalbėjimo greitis taikomas tik Apple balsui. „Fono testas“: paspausk ir per 15 s užrakink telefoną – DJ turi prabilti.")
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
                    statusRow("Groq (DJ tekstai ir balsas)", ok: !Config.groqAPIKey.isEmpty)
                    Button {
                        Task {
                            isDiagnosing = true
                            diagnosis = await engine.diagnoseGroq()
                            isDiagnosing = false
                        }
                    } label: {
                        HStack {
                            Label("Patikrinti Groq", systemImage: "stethoscope")
                            if isDiagnosing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isDiagnosing)
                    if let diagnosis {
                        Text(diagnosis)
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Text("OnAir 0.4")
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
