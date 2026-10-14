import Foundation

enum SettingsKeys {
    /// Po kiek dainų DJ įsijungia į eterį.
    static let talkEvery = "talkEvery"
    /// Pasirinkto Apple balso identifikatorius ("" = automatiškai geriausias).
    static let voiceID = "voiceID"
    /// Kalbėjimo greitis (AVSpeechUtterance rate, 0.0–1.0, numatytasis 0.5).
    static let speechRate = "speechRate"
    /// "duck" – patylinti Spotify kol DJ kalba; "pause" – sustabdyti Spotify kol DJ kalba.
    static let talkMode = "talkMode"
    /// "kokoro" – neuroninis balsas telefone; "apple" – Apple sistemos balsas.
    static let voiceEngine = "voiceEngine"
    /// Kokoro balso ID (pvz. "am_michael").
    static let kokoroVoice = "kokoroVoice"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            talkEvery: 3,
            voiceID: "",
            speechRate: 0.5,
            talkMode: "duck",
            voiceEngine: "kokoro",
            kokoroVoice: KokoroEngine.defaultVoice
        ])
    }
}
