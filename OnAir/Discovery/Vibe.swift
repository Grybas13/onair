import Foundation

/// Stoties nuotaika. „Mix“ – numatytoji: tavo dainos + ~30 % naujų.
enum Vibe: String, CaseIterable, Codable, Identifiable {
    case mix, chill, energy, focus, party, feels, throwback, discover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mix: return "Mix"
        case .chill: return "Chill"
        case .energy: return "Energy"
        case .focus: return "Focus"
        case .party: return "Party"
        case .feels: return "Feels"
        case .throwback: return "Throwback"
        case .discover: return "Discover"
        }
    }

    var icon: String {
        switch self {
        case .mix: return "shuffle"
        case .chill: return "cloud.moon.fill"
        case .energy: return "bolt.fill"
        case .focus: return "scope"
        case .party: return "party.popper.fill"
        case .feels: return "heart.slash.fill"
        case .throwback: return "clock.arrow.circlepath"
        case .discover: return "sparkles"
        }
    }

    /// Kaip vibe apibūdinti Dėdžiui (angliškai).
    var promptDescription: String {
        switch self {
        case .mix: return "a mix of the listener's favourites plus some new finds"
        case .chill: return "chill, mellow, laid-back"
        case .energy: return "high energy, loud, fast"
        case .focus: return "focus music, mostly instrumental and calm"
        case .party: return "party, dance, club bangers"
        case .feels: return "sad, emotional, in-your-feelings songs"
        case .throwback: return "throwbacks: old favourites the listener used to play a lot"
        case .discover: return "discovery: brand new songs the listener has never played"
        }
    }

    /// Kiek naujų (atrastų) dainų dėti į sąrašą.
    var discoveryShare: Double {
        switch self {
        case .mix: return 0.3
        case .throwback: return 0
        case .discover: return 1
        default: return 0.3
        }
    }

    /// Last.fm žymų raktažodžiai ir jų svoriai. Žyma tinka, jei raktažodis yra jos dalis
    /// (pvz. „lithuanian hip-hop“ tinka „hip-hop“).
    var keywords: [String: Double] {
        switch self {
        case .chill:
            return ["chill": 1, "chillout": 1, "chillwave": 1, "lo-fi": 1, "lofi": 1, "ambient": 0.7,
                    "mellow": 1, "relax": 1, "downtempo": 1, "calm": 1, "smooth": 0.6, "acoustic": 0.6,
                    "soft": 0.6, "dream pop": 0.8, "bedroom pop": 0.7, "trip-hop": 0.8, "trip hop": 0.8,
                    "jazz": 0.5, "soul": 0.4, "r&b": 0.4, "rnb": 0.4, "chillhop": 1, "lounge": 0.8]
        case .energy:
            return ["energetic": 1, "upbeat": 0.8, "hard rock": 1, "rock": 0.5, "metal": 1, "punk": 1,
                    "drum and bass": 1, "dnb": 1, "edm": 0.8, "electro": 0.6, "workout": 1, "gym": 1,
                    "hardstyle": 1, "trap": 0.6, "dubstep": 0.9, "phonk": 1, "aggressive": 1,
                    "techno": 0.6, "rap": 0.4, "hip-hop": 0.4, "hip hop": 0.4, "drill": 0.8, "grime": 0.7]
        case .focus:
            return ["instrumental": 1, "ambient": 1, "post-rock": 1, "classical": 1, "piano": 1,
                    "lo-fi": 0.8, "lofi": 0.8, "study": 1, "minimal": 0.8, "soundtrack": 0.8,
                    "electronic": 0.3, "downtempo": 0.6, "chillhop": 0.8, "neoclassical": 1, "idm": 0.7]
        case .party:
            return ["dance": 1, "party": 1, "house": 1, "edm": 1, "club": 1, "pop": 0.4, "disco": 1,
                    "funk": 0.7, "reggaeton": 1, "dancehall": 1, "trap": 0.5, "hip-hop": 0.5,
                    "hip hop": 0.5, "rap": 0.5, "electropop": 0.8, "dance-pop": 1, "techno": 0.7,
                    "afrobeats": 1, "eurodance": 1]
        case .feels:
            return ["sad": 1, "melancholic": 1, "melancholy": 1, "emotional": 1, "heartbreak": 1,
                    "love": 0.5, "ballad": 1, "slow": 0.6, "singer-songwriter": 0.7, "depressing": 1,
                    "beautiful": 0.5, "romantic": 0.7, "emo": 0.8, "breakup": 1, "indie folk": 0.6]
        case .mix, .throwback, .discover:
            return [:]
        }
    }
}
