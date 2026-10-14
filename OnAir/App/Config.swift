import Foundation

enum Config {
    /// Spotify „Client ID“. Į programėlę įrašomas kompiliuojant:
    /// GitHub → Settings → Secrets and variables → Actions → SPOTIFY_CLIENT_ID.
    /// (Kompiliuojant Mac'e ranka: xcodebuild ... SPOTIFY_CLIENT_ID=tavo_id)
    static let spotifyClientID: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// Turi lygiai sutapti su „Redirect URI“, įrašytu Spotify Dashboard nustatymuose.
    static let redirectURI = "onairfm://callback"
    static let callbackScheme = "onairfm"

    static let scopes = [
        "user-top-read",
        "user-read-recently-played",
        "user-library-read",
        "user-follow-read",
        "playlist-read-private",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing"
    ]

    static var isClientIDConfigured: Bool {
        !spotifyClientID.isEmpty && !spotifyClientID.contains("$(")
    }
}
