import Foundation

/// Dėdžio frazės be interneto (kai Groq nepasiekiamas ar baigėsi limitas).
/// Kiekviena frazė gali grąžinti nil, jei jai trūksta duomenų – tada imama kita.
enum DedisTemplates {
    typealias Line = (DedisFacts) -> String?

    static func line(for moment: DJMoment, facts: DedisFacts) -> String {
        let pool: [Line]
        switch moment {
        case .open: pool = opens
        case .handoff: pool = handoffs
        case .vibeSwitch(_, let to): pool = vibeSwitches[to] ?? genericVibeSwitch
        case .switchUp(let direction): pool = switchUps(direction)
        case .dislike(_, let banned): pool = banned ? artistBans : dislikes
        case .like: pool = likes
        case .mention: pool = mentions
        case .autoplayRecovery: pool = autoplay
        }
        let candidates = pool.shuffled().compactMap { $0(facts) }
        return candidates.first ?? "Dėdis on the mic. Shut up and listen."
    }

    static func next(_ f: DedisFacts) -> String { f.nextArtist ?? "this one" }

    // MARK: - Atidarymas

    static let opens: [Line] = [
        { f in "Dėdis here, live from a studio you couldn't afford. It's \(f.time), and your taste is about to be judged. Let's go." },
        { f in "\(f.day) night, \(f.time), and you opened a radio app instead of calling a girl. Respect. This is Dėdis on OnAir." },
        { _ in "Well look who crawled back. Dėdis on the mic. I picked the songs, you sit there and pretend you have taste." },
        { f in "Holy shit, you actually showed up. OnAir, Dėdis, \(f.time). Buckle up, nephew." },
        { f in "Good \(DedisTemplates.partOfDay(f.time)), you beautiful disaster. Dėdis here. I've seen your top artists. We need to talk. But first, music." },
        { f in f.stats.topArtistsThisWeek.first.map { "Dėdis on OnAir. \($0.name) \($0.plays) times this week? Okay, therapist's on line two. Let's start." } }
    ]

    // MARK: - Perėjimai

    static let handoffs: [Line] = [
        { f in f.previousArtist.map { "That was \($0). Moving on before you get attached. Here's \(DedisTemplates.next(f))." } },
        { f in f.previousArtist.map { "\($0), everybody. That guy is basically carrying your whole personality. Next up, \(DedisTemplates.next(f))." } },
        { f in "Okay, that one slapped. I'm not saying it twice. \(DedisTemplates.next(f)), go." },
        { f in "It's \(f.time) and you're still here. No plans, no friends, just vibes. Respect. Here's \(DedisTemplates.next(f))." },
        { f in "I've got \(DedisTemplates.next(f)) for you next. Don't you dare touch that skip button. I can see you." },
        { f in "Real talk, your library has the emotional range of a parking lot. I'm fixing it one song at a time. \(DedisTemplates.next(f))." },
        { f in f.previousArtistWeekPlays >= 3 ? "\(f.previousArtist ?? "That") again. \(f.previousArtistWeekPlays) times this week. Bro, blink twice if you need help. Here's \(DedisTemplates.next(f))." : nil },
        { f in f.stats.onRepeat.first.map { "\($0.title), \($0.plays) times this week. It's not gonna text you back, man. Anyway, \(DedisTemplates.next(f))." } },
        { f in f.stats.skipsLastHour >= 3 ? "\(f.stats.skipsLastHour) skips in the last hour. You're not picky, you're a goddamn menace. Let this one play. \(DedisTemplates.next(f))." : nil },
        { f in f.stats.lastSkip.map { "You bailed on \($0.artist) after \(max(1, $0.listenedMs / 1000)) seconds. Cold blooded. I love it. Here's \(DedisTemplates.next(f))." } },
        { f in f.nextIsNew ? "Fresh one coming up, \(DedisTemplates.next(f)). You've never heard it. Try to act cultured for three minutes." : nil },
        { f in f.nextIsNew ? "New blood. \(DedisTemplates.next(f)). If you hate it, that's a you problem." : nil },
        { f in f.nextYear.flatMap { year in year <= Calendar.current.component(.year, from: Date()) - 8 ? "Taking you back to \(year). Worse haircuts, better taste. \(DedisTemplates.next(f))." : nil } },
        { f in f.nextTags.first.map { "Got some \($0) for you next. Yeah, I know genres. \(DedisTemplates.next(f))." } },
        { f in f.earlierArtists.isEmpty ? nil : "\(DJScript.joinNames(f.earlierArtists)), and now this. Not bad for a guy with your history. \(DedisTemplates.next(f))." },
        { f in f.nextArtistWeekPlays >= 3 ? "More \(DedisTemplates.next(f)), because apparently that's all you fucking listen to. \(f.nextArtistWeekPlays) times this week." : nil }
    ]

    // MARK: - Vibe

    static let vibeSwitches: [Vibe: [Line]] = [
        .chill: [
            { _ in "Chill mode. Lower your shoulders, unclench whatever you're clenching. Dėdis has you." },
            { _ in "Switching to chill. Bold move for someone so stressed. Breathe, nephew." }
        ],
        .energy: [
            { _ in "[excited] Energy mode. If you're not moving in ten seconds, I'm calling your mother." },
            { _ in "Oh, we're doing energy now? Hell yes. Get off the couch, you lazy bastard." }
        ],
        .focus: [
            { _ in "Focus mode. Shut up and do your work. I'll keep it quiet. Mostly." },
            { _ in "Focus, huh. Fine. Put the phone down and stop pretending you're busy." }
        ],
        .party: [
            { _ in "[excited] Party mode. Doesn't matter if it's just you and the fridge. Let's fucking go." },
            { f in "It's \(f.time) on a \(f.day) and you want a party. Love that for you. Turn it up." }
        ],
        .feels: [
            { _ in "[whisper] Feels mode. Who hurt you? Actually, don't answer. Tissues on the left." },
            { _ in "Sad songs, huh. Somebody left you on read. Uncle's here. Let it out." }
        ],
        .throwback: [
            { _ in "Throwback time. The stuff you played before you got boring." },
            { _ in "Back to the old days. When your taste was questionable, but at least it was yours." }
        ],
        .discover: [
            { _ in "Discover mode. New shit only. Open your ears and your mind, in that order." },
            { _ in "Brand new stuff, nephew. Stop playing the same ten songs like a goddamn jukebox." }
        ],
        .mix: [
            { _ in "Back to the mix. Your stuff, my stuff, everybody's happy." },
            { _ in "Mix mode. A little of what you like, a little of what you need." }
        ]
    ]

    static func switchUps(_ direction: [String]) -> [Line] {
        let target = direction.first.map { "some \($0)" } ?? "something else"
        return [
            { _ in "Not feeling it? Picky little bastard. Fine, switching to \(target)." },
            { _ in "[dramatic] He's bored. The king is bored. Okay, \(target) coming up." },
            { _ in "Say no more. Throwing that out the window, here's \(target)." },
            { _ in "Switching it up. If you skip this too, I'm putting on polka." }
        ]
    }

    static let genericVibeSwitch: [Line] = [
        { f in "Switching it up. \(f.vibe.title) mode, let's see if you can handle it." }
    ]

    // MARK: - ❤️ / 👎

    static let dislikes: [Line] = [
        { _ in "[dramatic] Yeah, that was trash. Gone. Never again." },
        { _ in "Thumbs down, noted. That song is dead to us." },
        { f in f.previousArtist.map { "Sorry \($0), my nephew has spoken. Next." } },
        { _ in "Harsh. Correct, but harsh. Moving on." }
    ]

    static let artistBans: [Line] = [
        { f in "That's two strikes for \(f.previousArtist ?? "them"). Banned from this station. Brutal. I respect it." },
        { f in "\(f.previousArtist ?? "That artist") is officially dead to us. Don't come crying back." }
    ]

    static let likes: [Line] = [
        { f in "A heart for \(f.previousArtist ?? "that one")? Look at you having feelings." },
        { _ in "Saved. I'll play more like that, you sentimental bastard." },
        { _ in "Liked it, huh? Finally some taste. Noted." }
    ]

    // MARK: - Kita

    static let mentions: [Line] = [
        { f in "Still Dėdis, still judging. This is \(DedisTemplates.next(f)), and it's \(f.time)." },
        { f in "You pressed the DJ button. Needy. Anyway, this is \(DedisTemplates.next(f))." },
        { f in f.nextTags.first.map { "Little bit of \($0) right now. \(DedisTemplates.next(f)). You're welcome." } }
    ]

    static let autoplay: [Line] = [
        { _ in "Spotify tried to sneak its own garbage in. Not on my watch. Back to the real station." },
        { _ in "Some algorithm thought it could replace me. Cute. Dėdis is back." }
    ]

    static func partOfDay(_ time: String) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "morning"
        case 12..<18: return "afternoon"
        default: return "evening"
        }
    }
}
