import Foundation
import ActivityKit
import AppIntents

/// Live Activity (užrakintas ekranas ir Dynamic Island) duomenys.
/// Šis failas įtrauktas ir į programėlę, ir į valdiklio plėtinį.
struct OnAirActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var djName: String
        var vibe: String
        var title: String
        var artist: String
        var nextTitle: String?
        var nextArtist: String?
        /// Po kiek dainų prabils DJ (0 – kitoje sandūroje).
        var tracksUntilTalk: Int
        var isTalking: Bool
        var isLiked: Bool
        var isPlaying: Bool
    }

    var stationName: String
}

// MARK: - Mygtukai užrakintame ekrane
// LiveActivityIntent vykdomas programėlės procese (ji ir taip veikia fone),
// todėl valdiklio plėtinyje veiksmų kodas nekompiliuojamas.

struct SwitchUpIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Keisti muziką"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await LiveActivityActions.run(.switchUp)
        #endif
        return .result()
    }
}

struct LikeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Patinka"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await LiveActivityActions.run(.like)
        #endif
        return .result()
    }
}

struct DislikeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Nepatinka"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await LiveActivityActions.run(.dislike)
        #endif
        return .result()
    }
}

struct SkipIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Praleisti"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await LiveActivityActions.run(.skip)
        #endif
        return .result()
    }
}
