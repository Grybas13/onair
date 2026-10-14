import Foundation
import CryptoKit

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum SpotifyAuthError: LocalizedError {
    case notConfigured
    case notLoggedIn
    case stateMismatch
    case missingCode
    case denied(String)
    case tokenRequestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Programėlėje nėra Spotify Client ID (GitHub secret SPOTIFY_CLIENT_ID)."
        case .notLoggedIn:
            return "Neprisijungta prie Spotify."
        case .stateMismatch:
            return "Prisijungimo atsakymas nesutampa (state). Bandyk dar kartą."
        case .missingCode:
            return "Spotify negrąžino prisijungimo kodo."
        case .denied(let reason):
            return "Spotify atmetė prisijungimą: \(reason)"
        case .tokenRequestFailed(let status, let body):
            return "Nepavyko gauti rakto (HTTP \(status)): \(body)"
        }
    }
}

/// Prisijungimas prie Spotify per „Authorization Code + PKCE“.
/// Slapto rakto (client secret) nereikia, todėl tinka programėlei telefone.
@MainActor
final class SpotifyAuth: ObservableObject {
    @Published private(set) var isLoggedIn = false

    private var tokens: SpotifyTokens?
    private var pendingVerifier: String?
    private var pendingState: String?
    private var refreshTask: Task<SpotifyTokens, Error>?
    private let keychainKey = "spotify.tokens"

    init() {
        if let data = Keychain.get(keychainKey),
           let saved = try? JSONDecoder().decode(SpotifyTokens.self, from: data) {
            tokens = saved
            isLoggedIn = true
        }
    }

    // MARK: - Prisijungimas

    func makeAuthorizationURL() throws -> URL {
        guard Config.isClientIDConfigured else { throw SpotifyAuthError.notConfigured }

        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 16)
        pendingVerifier = verifier
        pendingState = state

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Config.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Config.scopes.joined(separator: " "))
        ]
        return components.url!
    }

    func handleCallback(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") { throw SpotifyAuthError.denied(error) }
        guard let state = value("state"), state == pendingState else { throw SpotifyAuthError.stateMismatch }
        guard let code = value("code"), let verifier = pendingVerifier else { throw SpotifyAuthError.missingCode }

        let newTokens = try await requestTokens(
            params: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Config.redirectURI,
                "client_id": Config.spotifyClientID,
                "code_verifier": verifier
            ],
            fallbackRefreshToken: nil
        )
        pendingVerifier = nil
        pendingState = nil
        store(newTokens)
        trace("Spotify: prisijungta")
    }

    func logout() {
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        Keychain.delete(keychainKey)
        isLoggedIn = false
        trace("Spotify: atsijungta")
    }

    // MARK: - Raktai

    /// Grąžina galiojantį „access token“; jei baigiasi, automatiškai atnaujina.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw SpotifyAuthError.notLoggedIn }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        if let running = refreshTask {
            return try await running.value.accessToken
        }

        let refreshToken = current.refreshToken
        let task = Task { () throws -> SpotifyTokens in
            try await self.requestTokens(
                params: [
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": Config.spotifyClientID
                ],
                fallbackRefreshToken: refreshToken
            )
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            refreshTask = nil
            store(refreshed)
            trace("Spotify: raktas atnaujintas")
            return refreshed.accessToken
        } catch {
            refreshTask = nil
            if case SpotifyAuthError.tokenRequestFailed(let status, let body) = error,
               status == 400, body.contains("invalid_grant") {
                trace("Spotify: atnaujinimo raktas nebegalioja, reikia prisijungti iš naujo")
                logout()
            }
            throw error
        }
    }

    private func store(_ newTokens: SpotifyTokens) {
        tokens = newTokens
        if let data = try? JSONEncoder().encode(newTokens) {
            Keychain.set(data, for: keychainKey)
        }
        isLoggedIn = true
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func requestTokens(params: [String: String], fallbackRefreshToken: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            trace("Spotify token klaida \(status): \(body)")
            throw SpotifyAuthError.tokenRequestFailed(status, body)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = decoded.refresh_token ?? fallbackRefreshToken else {
            throw SpotifyAuthError.tokenRequestFailed(status, "Atsakyme nėra refresh_token")
        }
        return SpotifyTokens(
            accessToken: decoded.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    // MARK: - Pagalbinės

    private static func randomString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
    }
}
