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
    /// Ar rodyti Live Activity užrakintame ekrane.
    static let liveActivity = "liveActivity"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            talkEvery: 3,
            DJStyle.key: 3,
            voiceID: "",
            speechRate: 0.5,
            talkMode: "duck",
            voiceEngine: "groq",
            groqVoice: GroqSpeech.defaultVoice,
            liveActivity: true
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

/// DJ plepumas (1 – santūrus … 5 – plepus): kaip dažnai ir kiek ilgai kalba, ar reaguoja į ❤️/👎.
enum DJStyle {
    static let key = "chattiness"

    static var level: Int {
        min(5, max(1, UserDefaults.standard.integer(forKey: key)))
    }

    /// Po kiek dainų DJ įsijungia.
    static var talkEvery: Int { [5, 4, 3, 2, 1][level - 1] }

    /// Ilgiausias pasisakymas žodžiais.
    static var maxWords: Int { [14, 20, 30, 40, 50][level - 1] }

    /// Tikimybė, kad DJ pakomentuos ❤️.
    static var likeReactionChance: Double { [0, 0, 0.35, 0.7, 1][level - 1] }

    /// Ar DJ komentuoja 👎.
    static var reactsToDislikes: Bool { level >= 2 }

    static func title(for level: Int) -> String {
        ["Santūrus", "Ramus", "Vidutinis", "Šnekus", "Plepus"][min(5, max(1, level)) - 1]
    }

    static func summary(for level: Int) -> String {
        let clamped = min(5, max(1, level))
        let every = [5, 4, 3, 2, 1][clamped - 1]
        let words = [14, 20, 30, 40, 50][clamped - 1]
        let frequency = every == 1 ? "po kiekvienos dainos" : "kas \(every) dainas"
        let reactions: String
        switch clamped {
        case 1: reactions = "į ❤️/👎 nereaguoja"
        case 2: reactions = "komentuoja tik 👎"
        default: reactions = "komentuoja ❤️ ir 👎"
        }
        return "Kalba \(frequency), iki \(words) žodžių, \(reactions)."
    }
}
