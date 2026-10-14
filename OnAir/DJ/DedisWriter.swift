import Foundation

/// Kada Dėdis kalba.
enum DJMoment {
    case open(first: SpotifyTrack, vibe: Vibe)
    case handoff(previous: SpotifyTrack, earlier: [SpotifyTrack], next: SpotifyTrack, vibe: Vibe)
    case vibeSwitch(from: Vibe, to: Vibe)
    case dislike(track: SpotifyTrack, artistBanned: Bool)
    case like(track: SpotifyTrack)
    case mention(track: SpotifyTrack, vibe: Vibe)
    case autoplayRecovery

    var label: String {
        switch self {
        case .open: return "Atidarymas"
        case .handoff: return "Perėjimas"
        case .vibeSwitch: return "Vibe"
        case .dislike: return "👎"
        case .like: return "❤️"
        case .mention: return "Rankinis"
        case .autoplayRecovery: return "Autoplay"
        }
    }
}

/// Faktai, kuriuos Dėdis gali naudoti (niekas neišgalvojama).
struct DedisFacts {
    var time = ""
    var day = ""
    var vibe: Vibe = .mix
    var previousArtist: String?
    var previousTitle: String?
    var previousArtistWeekPlays = 0
    var previousTags: [String] = []
    var nextArtist: String?
    var nextTitle: String?
    var nextArtistWeekPlays = 0
    var nextTags: [String] = []
    var nextYear: Int?
    var nextIsNew = false
    var earlierArtists: [String] = []
    var stats = ListeningStats()
}

/// Dėdžio tekstų rašytojas: Groq kalbos modelis, o be jo – šablonai.
@MainActor
final class DedisWriter {
    private let groq: GroqClient
    private let store: ListeningStore
    private let curator: MusicCurator
    private var recentLines: [String] = []

    init(groq: GroqClient, store: ListeningStore, curator: MusicCurator) {
        self.groq = groq
        self.store = store
        self.curator = curator
    }

    func write(_ moment: DJMoment) async -> String {
        let facts = buildFacts(moment)
        if let raw = await groq.complete(system: Self.persona, user: prompt(moment, facts: facts)),
           let cleaned = Self.clean(raw) {
            remember(cleaned)
            return cleaned
        }
        let fallback = DedisTemplates.line(for: moment, facts: facts)
        remember(fallback)
        return fallback
    }

    private func remember(_ line: String) {
        recentLines.append(line)
        if recentLines.count > 4 { recentLines.removeFirst() }
    }

    // MARK: - Faktai

    private func buildFacts(_ moment: DJMoment) -> DedisFacts {
        var facts = DedisFacts()
        let now = Date()
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "h:mm a"
        facts.time = time.string(from: now)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEEE"
        facts.day = day.string(from: now)
        facts.stats = store.stats()

        func fillPrevious(_ track: SpotifyTrack) {
            facts.previousArtist = track.primaryArtist
            facts.previousTitle = DJScript.cleanTitle(track.name)
            facts.previousArtistWeekPlays = store.playCount(artist: track.primaryArtist, days: 7)
            facts.previousTags = curator.topTagNames(for: track)
        }
        func fillNext(_ track: SpotifyTrack) {
            facts.nextArtist = track.primaryArtist
            facts.nextTitle = DJScript.cleanTitle(track.name)
            facts.nextArtistWeekPlays = store.playCount(artist: track.primaryArtist, days: 7)
            facts.nextTags = curator.topTagNames(for: track)
            facts.nextYear = track.releaseYear
            facts.nextIsNew = !curator.pool.contains { $0.uri == track.uri }
        }

        switch moment {
        case .open(let first, let vibe):
            facts.vibe = vibe
            fillNext(first)
        case .handoff(let previous, let earlier, let next, let vibe):
            facts.vibe = vibe
            fillPrevious(previous)
            fillNext(next)
            facts.earlierArtists = DJScript.uniqueArtists(earlier, excluding: [previous.primaryArtist, next.primaryArtist])
        case .vibeSwitch(_, let to):
            facts.vibe = to
        case .dislike(let track, _), .like(let track):
            fillPrevious(track)
        case .mention(let track, let vibe):
            facts.vibe = vibe
            fillNext(track)
        case .autoplayRecovery:
            break
        }
        return facts
    }

    // MARK: - Užklausa modeliui

    static let persona = """
    You are Dėdis (say it "DEH-dis", Lithuanian for "uncle"), the host of OnAir, a radio station with exactly one listener, \
    a guy in Lithuania. You are his foul-mouthed, savage, hilarious uncle on the mic. You roast his music taste and \
    listening habits relentlessly, but you clearly love him and the music. Swearing is welcome (fuck, shit, damn, hell, \
    bastard) when it makes the joke land. Crude jokes are fine. Never use slurs and never attack groups of people \
    (race, religion, gender, sexuality, nationality).

    Style: like Spotify's AI DJ, but meaner and funnier. Talk about the vibe, his habits and patterns, the time of day, \
    not a playlist read-out. Mention at most ONE song title per break, often none. Artist names are fine.
    Use ONLY the facts you are given. Never invent numbers, stats, dates or facts about artists.

    Format: 1 to 3 short sentences, at most 45 words. Natural spoken English with contractions. No emojis, hashtags, \
    stage directions, asterisks, quotation marks or lists. Do not start with "Alright", "Well" or "Ladies and gentlemen". \
    Do not greet him unless it is the opening of the show. Vary your openings and don't repeat your recent lines.
    """

    private func prompt(_ moment: DJMoment, facts: DedisFacts) -> String {
        var lines: [String] = []

        switch moment {
        case .open:
            lines.append("Moment: the very start of the show. Greet him, set the mood, throw to the first song.")
        case .handoff:
            lines.append("Moment: a break between songs. React to what just played or to his habits, then throw to the next song.")
        case .vibeSwitch(let from, let to):
            lines.append("Moment: he just pressed a button to switch the station vibe from \(from.title) to \(to.title) (\(to.promptDescription)). React to that switch. The next song is already starting.")
        case .dislike(_, let banned):
            if banned {
                lines.append("Moment: he just gave a thumbs down to a song by \(facts.previousArtist ?? "this artist") for the second time, so that artist is now banned from the station. React in one or two sentences.")
            } else {
                lines.append("Moment: he just gave a thumbs down to the song that was playing, and it got skipped. React in one or two sentences.")
            }
        case .like:
            lines.append("Moment: he just hearted the current song and saved it to his library. React in one short sentence, then shut up.")
        case .mention:
            lines.append("Moment: he pressed the 'DJ talk now' button in the middle of a song. Say something short about the current song or his habits.")
        case .autoplayRecovery:
            lines.append("Moment: Spotify tried to sneak its own autoplay songs in. You just took the station back. One or two sentences.")
        }

        lines.append("Time: \(facts.day), \(facts.time).")
        lines.append("Station vibe: \(facts.vibe.title) – \(facts.vibe.promptDescription).")

        if let artist = facts.previousArtist {
            var line = "Just played: \(facts.previousTitle ?? "a song") by \(artist)"
            if !facts.previousTags.isEmpty { line += " (tags: \(facts.previousTags.joined(separator: ", ")))" }
            if facts.previousArtistWeekPlays >= 2 { line += ". He played \(artist) \(facts.previousArtistWeekPlays) times this week" }
            lines.append(line + ".")
        }
        if let artist = facts.nextArtist {
            var line = "Next song: \(facts.nextTitle ?? "a song") by \(artist)"
            var details: [String] = []
            if !facts.nextTags.isEmpty { details.append("tags: \(facts.nextTags.joined(separator: ", "))") }
            if let year = facts.nextYear { details.append("released \(year)") }
            if facts.nextIsNew { details.append("NEW to him, he has never played it") }
            if facts.nextArtistWeekPlays >= 2 { details.append("he played \(artist) \(facts.nextArtistWeekPlays) times this week") }
            if !details.isEmpty { line += " (" + details.joined(separator: "; ") + ")" }
            lines.append(line + ".")
        }
        if !facts.earlierArtists.isEmpty {
            lines.append("Earlier in this set: \(facts.earlierArtists.joined(separator: ", ")).")
        }

        var habits: [String] = []
        if let top = facts.stats.topArtistsThisWeek.first, top.plays >= 3 {
            habits.append("his most played artist this week is \(top.name) with \(top.plays) plays")
        }
        if let repeated = facts.stats.onRepeat.first {
            habits.append("he has \(repeated.title) by \(repeated.artist) on repeat, \(repeated.plays) plays this week")
        }
        if facts.stats.skipsLastHour >= 2 {
            habits.append("he skipped \(facts.stats.skipsLastHour) songs in the last hour")
        }
        if let skip = facts.stats.lastSkip {
            habits.append("the last song he skipped was by \(skip.artist), after \(max(1, skip.listenedMs / 1000)) seconds")
        }
        if facts.stats.playsToday >= 15 {
            habits.append("he has played \(facts.stats.playsToday) songs today")
        }
        if !habits.isEmpty {
            lines.append("Listener facts (use one at most, only if funny): " + habits.joined(separator: "; ") + ".")
        }

        if !recentLines.isEmpty {
            lines.append("Your recent lines, do not repeat them: " + recentLines.joined(separator: " | "))
        }
        lines.append("Write only what Dėdis says out loud now.")
        return lines.joined(separator: "\n")
    }

    /// Nuvalo modelio atsakymą: kabutės, žvaigždutės, pastabos skliaustuose, per ilgas tekstas.
    static func clean(_ raw: String) -> String? {
        var text = raw
        text = text.replacingOccurrences(of: #"\*[^*]*\*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([^)]*(laugh|music|pause|sigh|chuckle)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        for symbol in ["\"", "“", "”", "#"] {
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        if text.lowercased().hasPrefix("dėdis:") || text.lowercased().hasPrefix("dedis:") {
            text = String(text.dropFirst(6))
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > 320, let cut = text.prefix(320).lastIndex(where: { ".!?".contains($0) }) {
            text = String(text[...cut])
        }
        return text.count >= 3 ? text : nil
    }
}
