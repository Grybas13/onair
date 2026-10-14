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
    /// "groq" – Groq Orpheus balsas (debesyje); "apple" – Apple sistemos balsas.
    static let voiceEngine = "voiceEngine2"
    /// Groq Orpheus balso ID (pvz. "troy").
    static let groqVoice = "groqVoice"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            talkEvery: 3,
            voiceID: "",
            speechRate: 0.5,
            talkMode: "duck",
            voiceEngine: "groq",
            groqVoice: GroqSpeech.defaultVoice
        ])
    }
}

/// DJ vardas (keičiamas nustatymuose). Paprastas angliškas, kad balsas taisyklingai ištartų.
enum DJIdentity {
    static let key = "djName"
    static let defaultName = "Uncle Dee"

    static var name: String {
        let value = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultName : value
    }

    /// Senas vardas „Dėdis“ tekstuose pakeičiamas dabartiniu.
    static func personalize(_ text: String) -> String {
        text.replacingOccurrences(of: "Dėdžio", with: "\(name)'s")
            .replacingOccurrences(of: "Dėdis", with: name)
    }
}
