import Foundation

// Minimalūs Spotify Web API modeliai. Dekoduojama su .convertFromSnakeCase,
// todėl pvz. „duration_ms“ tampa „durationMs“.

struct SpotifyImage: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct SpotifyArtist: Decodable {
    let spotifyID: String?
    let name: String

    enum CodingKeys: String, CodingKey {
        case spotifyID = "id"
        case name
    }
}

struct SpotifyAlbum: Decodable {
    let name: String
    let images: [SpotifyImage]?
    let releaseDate: String?
}

struct SpotifyTrack: Decodable, Identifiable, Hashable {
    let spotifyID: String?
    let uri: String
    let name: String
    let durationMs: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?

    enum CodingKeys: String, CodingKey {
        case spotifyID = "id"
        case uri, name, durationMs, artists, album
    }

    var id: String { uri }

    var artistNames: String {
        DJScript.joinNames(artists.map(\.name))
    }

    var primaryArtist: String {
        artists.first?.name ?? "Unknown artist"
    }

    var artworkURL: URL? {
        guard let images = album?.images, !images.isEmpty else { return nil }
        // Spotify grąžina nuo didžiausio iki mažiausio; imame vidutinį.
        let pick = images.count > 1 ? images[1] : images[0]
        return URL(string: pick.url)
    }

    static func == (lhs: SpotifyTrack, rhs: SpotifyTrack) -> Bool { lhs.uri == rhs.uri }
    func hash(into hasher: inout Hasher) { hasher.combine(uri) }
}

struct SpotifyPaging<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
}

struct SpotifyDevice: Decodable {
    let id: String?
    let isActive: Bool
    let isRestricted: Bool?
    let name: String
    let type: String
    let volumePercent: Int?
    let supportsVolume: Bool?
}

struct SpotifyDevicesResponse: Decodable {
    let devices: [SpotifyDevice]
}

struct SpotifyPlaybackState: Decodable {
    let device: SpotifyDevice?
    let isPlaying: Bool
    let progressMs: Int?
    let item: SpotifyTrack?
    let currentlyPlayingType: String?
}

struct SpotifyRecentlyPlayedItem: Decodable {
    let track: SpotifyTrack
    let playedAt: String
}

struct SpotifyErrorBody: Decodable {
    struct Inner: Decodable {
        let status: Int?
        let message: String?
        let reason: String?
    }
    let error: Inner
}
