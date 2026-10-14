import Foundation

/// DJ tekstai (1 etapas – šablonai anglų kalba).
/// 3 etape čia prisidės Apple on-device modelis, atlikėjų faktai ir klausymo statistika.
enum DJScript {

    // MARK: - Segmentai

    static func stationOpen(first: SpotifyTrack, now: Date = Date()) -> String {
        let title = cleanTitle(first.name)
        let artist = first.artistNames
        let greeting = greeting(for: now)
        let time = spokenTime(now)
        let options = [
            "\(greeting), this is OnAir. Your station, nobody else's. It's \(time). Kicking things off with \(title) by \(artist).",
            "\(greeting). You're tuned to OnAir, and it's \(time). First up, \(artist) with \(title).",
            "\(greeting), and welcome to OnAir. We're starting with \(title). \(artist), take it away."
        ]
        return options.randomElement()!
    }

    /// Klasikinis radijo perėjimas: kas ką tik grojo, kas grojo prieš tai, kas groja dabar.
    static func handoff(previous: SpotifyTrack, earlier: [SpotifyTrack], next: SpotifyTrack, now: Date = Date()) -> String {
        let prevTitle = cleanTitle(previous.name)
        let prevArtist = previous.artistNames
        let nextTitle = cleanTitle(next.name)
        let nextArtist = next.artistNames

        var parts: [String] = []

        parts.append([
            "That was \(prevTitle) by \(prevArtist).",
            "\(prevArtist) there, with \(prevTitle).",
            "You just heard \(prevTitle) from \(prevArtist).",
            "\(prevTitle). \(prevArtist). Lovely stuff."
        ].randomElement()!)

        let earlierArtists = uniqueArtists(earlier, excluding: [previous.primaryArtist, next.primaryArtist])
        if !earlierArtists.isEmpty {
            parts.append([
                "Before that, \(joinNames(earlierArtists)).",
                "And earlier, we had \(joinNames(earlierArtists))."
            ].randomElement()!)
        }

        if Int.random(in: 0..<10) < 3 {
            parts.append([
                "It's \(spokenTime(now)).",
                "Time check, it's \(spokenTime(now)).",
                "This is OnAir."
            ].randomElement()!)
        }

        parts.append([
            "Up next, \(nextTitle) by \(nextArtist).",
            "Here's \(nextArtist) with \(nextTitle).",
            "Now, \(nextTitle). \(nextArtist).",
            "Keeping it going with \(nextArtist). This is \(nextTitle)."
        ].randomElement()!)

        return parts.joined(separator: " ")
    }

    /// Rankinis „Talk now“ mygtukas – kad galėtum ištestuoti patylinimą bet kada.
    static func nowPlayingMention(_ track: SpotifyTrack, now: Date = Date()) -> String {
        let title = cleanTitle(track.name)
        let artist = track.artistNames
        return [
            "You're listening to \(title) by \(artist), here on OnAir. It's \(spokenTime(now)).",
            "Quick one from the booth. This is \(artist), \(title). OnAir, \(spokenTime(now))."
        ].randomElement()!
    }

    static let voiceTest = "Testing, testing. This is your DJ on OnAir. If Spotify just got quieter, the talk-over works."

    // MARK: - Pagalbinės

    static func greeting(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Hello night owls"
        }
    }

    static func spokenTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date)
    }

    static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    static func uniqueArtists(_ tracks: [SpotifyTrack], excluding: [String]) -> [String] {
        var seen = Set(excluding.map { $0.lowercased() })
        var result: [String] = []
        for track in tracks {
            let name = track.primaryArtist
            if seen.insert(name.lowercased()).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// „Song - Remastered 2011“ → „Song“, „Song (feat. X)“ → „Song“.
    static func cleanTitle(_ title: String) -> String {
        var result = title
        let dashPattern = #"\s+-\s+.*(remaster|live|version|edit|mono|stereo|mix|demo|deluxe|anniversary|acoustic)"#
        if let range = result.range(of: dashPattern, options: [.regularExpression, .caseInsensitive]) {
            result = String(result[..<range.lowerBound])
        }
        let bracketPattern = #"\s*[\(\[][^\)\]]*(remaster|feat\.|ft\.|with |version|edit|live|mono|stereo|deluxe|anniversary)[^\)\]]*[\)\]]"#
        result = result.replacingOccurrences(of: bracketPattern, with: "", options: [.regularExpression, .caseInsensitive])
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }
}
