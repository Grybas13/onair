import Foundation
import AVFoundation

/// Dėdžio balsas per Groq „Orpheus“ (debesyje): gyvas, emocingas, palaiko intonacijų žymes
/// kaip [excited] ar [whisper]. Veikia ir fone (tai tik interneto užklausa).
/// Nemokamas planas ribotas (~100 užklausų per dieną) – pasiekus limitą kalba Apple balsas.
@MainActor
final class GroqSpeech {
    static let shared = GroqSpeech()

    struct VoiceOption: Identifiable {
        let id: String
        let title: String
    }

    static let model = "canopylabs/orpheus-v1-english"
    static let voices: [VoiceOption] = [
        VoiceOption(id: "troy", title: "Troy · vyras"),
        VoiceOption(id: "austin", title: "Austin · vyras"),
        VoiceOption(id: "daniel", title: "Daniel · vyras"),
        VoiceOption(id: "autumn", title: "Autumn · moteris"),
        VoiceOption(id: "diana", title: "Diana · moteris"),
        VoiceOption(id: "hannah", title: "Hannah · moteris")
    ]
    static let defaultVoice = "troy"

    /// Orpheus priima iki ~200 ženklų per užklausą.
    static let maxCharacters = 190

    /// Intonacijų žymės, kurias Orpheus supranta. Kitos žymės iš teksto išmetamos,
    /// kad balsas jų neperskaitytų garsiai.
    static let allowedTags: Set<String> = [
        "cheerful", "excited", "whisper", "dramatic", "professionally", "authoritatively", "menacing whisper"
    ]

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/speech")!
    private var pausedUntil = Date.distantPast
    private(set) var lastError: String?

    var isAvailable: Bool {
        !Config.groqAPIKey.isEmpty && Date() >= pausedUntil
    }

    /// Įgarsina tekstą. Grąžina nil, jei nepavyko (tada kviečiantis naudoja Apple balsą).
    func synthesize(_ text: String) async -> [AVAudioPCMBuffer]? {
        guard isAvailable else { return nil }
        let voice = UserDefaults.standard.string(forKey: SettingsKeys.groqVoice) ?? Self.defaultVoice
        let chunks = Self.chunks(Self.sanitizeTags(Self.prepareForSpeech(text)))
        guard !chunks.isEmpty else { return nil }

        let started = Date()
        var buffers: [AVAudioPCMBuffer] = []
        for chunk in chunks {
            guard let data = await request(chunk, voice: voice),
                  let buffer = Self.decodeWAV(data) else { return nil }
            buffers.append(buffer)
        }
        let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        trace(String(format: "Orpheus: %.1f s balso per %.1f s (%ld užkl.)", seconds, Date().timeIntervalSince(started), chunks.count))
        lastError = nil
        return buffers
    }

    private func request(_ input: String, voice: String) async -> Data? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(Config.groqAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Self.model,
            "input": input,
            "voice": voice,
            "response_format": "wav"
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = json

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 { return data }

            let message = GroqClient.errorMessage(from: data)
            lastError = "HTTP \(status): \(message)"
            switch status {
            case 429:
                let retry = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 600
                pausedUntil = Date().addingTimeInterval(max(60, retry))
                trace("Orpheus: pasiektas limitas (\(message)) – \(Int(max(60, retry)) / 60) min. kalba Apple balsas")
            case 401:
                pausedUntil = .distantFuture
                trace("Orpheus: neteisingas Groq raktas – kalba Apple balsas")
            default:
                if message.lowercased().contains("terms") {
                    pausedUntil = Date().addingTimeInterval(3600)
                    trace("Orpheus: Groq konsolėje reikia priimti modelio sąlygas – \(message)")
                } else {
                    pausedUntil = Date().addingTimeInterval(120)
                    trace("Orpheus klaida HTTP \(status): \(message)")
                }
            }
            return nil
        } catch {
            lastError = error.localizedDescription
            if (error as? URLError)?.code != .cancelled {
                trace("Orpheus nepavyko: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: - Tekstas

    /// Palieka tik žinomas intonacijų žymes, kitas išmeta.
    static func sanitizeTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]{1,30})\]"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in regex.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range, in: result),
                  let inner = Range(match.range(at: 1), in: result) else { continue }
            let tag = result[inner].lowercased().trimmingCharacters(in: .whitespaces)
            if allowedTags.contains(tag) {
                result.replaceSubrange(whole, with: "[\(tag)]")
            } else {
                result.replaceSubrange(whole, with: "")
            }
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tarimas: „Dėdis“ → „Dehdis“, lietuviškos raidės → lotyniškos, simboliai → žodžiai.
    static func prepareForSpeech(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "Dėdis", with: "Dehdis")
            .replacingOccurrences(of: "Dėdžio", with: "Dehdis's")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "%", with: " percent")
        result = result.applyingTransform(.stripDiacritics, reverse: false) ?? result
        return result
    }

    /// Visiškai pašalina žymes (Apple balsui ir rodymui ekrane).
    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]{1,30}\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Skaido tekstą į ≤190 ženklų dalis sakinių ribose.
    static func chunks(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        if sentences.isEmpty { sentences = [text] }

        var result: [String] = []
        var current = ""
        for sentence in sentences {
            for piece in split(sentence) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= maxCharacters {
                    current += " " + piece
                } else {
                    result.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        // Daugiau nei 2 užklausų vienam pasisakymui negaištame (taupome dienos limitą).
        return Array(result.prefix(2))
    }

    /// Per ilgą sakinį skaido žodžiais.
    private static func split(_ sentence: String) -> [String] {
        guard sentence.count > maxCharacters else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if current.count + word.count + 1 > maxCharacters, !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " " + word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - WAV

    /// Perskaito WAV į garso buferį (pirmiausia per AVAudioFile, atsargai – rankiniu būdu).
    static func decodeWAV(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        if (try? data.write(to: url)) != nil,
           let file = try? AVAudioFile(forReading: url),
           file.length > 0,
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
           (try? file.read(into: buffer)) != nil,
           buffer.frameLength > 0 {
            return buffer
        }
        return decodeWAVManually(data)
    }

    private static func decodeWAVManually(_ data: Data) -> AVAudioPCMBuffer? {
        let bytes = [UInt8](data)
        guard bytes.count > 44,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            trace("Orpheus: atsakymas nėra WAV (\(bytes.count) B)")
            return nil
        }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        var offset = 12
        var formatTag = 1, channels = 1, sampleRate = 24_000, bits = 16
        var dataStart: Int?
        var dataLength = 0
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " && body + 16 <= bytes.count {
                formatTag = u16(body)
                channels = max(1, u16(body + 2))
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                dataStart = body
                let remaining = bytes.count - body
                dataLength = (size == 0 || size == 0xFFFF_FFFF || size > remaining) ? remaining : size
                break
            }
            offset = body + size + (size % 2)
        }

        guard let start = dataStart, sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else {
            return nil
        }
        let bytesPerSample = bits / 8
        guard bytesPerSample > 0 else { return nil }
        let frames = dataLength / (bytesPerSample * channels)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = start + (frame * channels + channel) * bytesPerSample
                let value: Float
                if formatTag == 3 && bits == 32 {
                    let raw = UInt32(u32(index))
                    value = Float(bitPattern: raw)
                } else if bits == 16 {
                    value = Float(Int16(bitPattern: UInt16(u16(index)))) / 32768
                } else {
                    return nil
                }
                output[channel][frame] = value
            }
        }
        return buffer
    }
}
