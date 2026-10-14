import Foundation

enum Config {
    /// Spotify „Client ID“. Į programėlę įrašomas kompiliuojant:
    /// GitHub → Settings → Secrets and variables → Actions → SPOTIFY_CLIENT_ID.
    /// (Kompiliuojant Mac'e ranka: xcodebuild ... SPOTIFY_CLIENT_ID=tavo_id)
    static let spotifyClientID: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// Last.fm API raktas (GitHub secret LASTFM_API_KEY) – vibe žymoms ir naujoms dainoms.
    static let lastFMAPIKey: String = plistValue("LastFMAPIKey")

    /// Groq API raktas (GitHub secret GROQ_API_KEY) – Dėdžio tekstams.
    static let groqAPIKey: String = plistValue("GroqAPIKey")

    private static func plistValue(_ key: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("$(") ? "" : value
    }

    /// Turi lygiai sutapti su „Redirect URI“, įrašytu Spotify Dashboard nustatymuose.
    static let redirectURI = "onairfm://callback"
    static let callbackScheme = "onairfm"

    static let scopes = [
        "user-top-read",
        "user-read-recently-played",
        "user-library-read",
        "user-library-modify",
        "user-follow-read",
        "playlist-read-private",
        "playlist-modify-private",
        "playlist-modify-public",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing"
    ]

    static var isClientIDConfigured: Bool {
        !spotifyClientID.isEmpty && !spotifyClientID.contains("$(")
    }
}
