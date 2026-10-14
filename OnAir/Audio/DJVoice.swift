import AVFoundation

/// DJ balsas: nemokamas Apple sistemos balsas (AVSpeechSynthesizer).
/// Geresnės kokybės balsus galima atsisiųsti: Nustatymai → Pritaikymas neįgaliesiems →
/// Įgarsinamas turinys → Balsai → English.
@MainActor
final class DJVoice: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    /// Pasako tekstą ir grįžta, kai baigia (arba po saugos laiko).
    func speak(_ text: String) async {
        if let previous = currentUtterance {
            finish(previous)
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.selectedVoice()
        let rate = UserDefaults.standard.double(forKey: SettingsKeys.speechRate)
        utterance.rate = Float(rate > 0 ? rate : Double(AVSpeechUtteranceDefaultSpeechRate))
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.15

        currentUtterance = utterance
        isSpeaking = true

        // Saugiklis: jei iOS nepraneštų apie pabaigą, neužstrigsime su patylinta muzika.
        let words = Double(text.split(separator: " ").count)
        let timeout = words / 1.8 + 8
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.currentUtterance === utterance else { return }
            trace("DJ balsas: baigėsi saugos laikas, nutraukiu")
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finish(utterance)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation = cont
            synthesizer.speak(utterance)
        }
        if currentUtterance == nil {
            isSpeaking = false
        }
    }

    func stop() {
        if let current = currentUtterance {
            finish(current)
        }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    fileprivate func finish(_ utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    // MARK: - Balsai

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue > b.quality.rawValue
                }
                if a.language != b.language {
                    return a.language < b.language
                }
                return a.name < b.name
            }
    }

    static func selectedVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: SettingsKeys.voiceID), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return bestDefaultVoice()
    }

    static func bestDefaultVoice() -> AVSpeechSynthesisVoice? {
        let voices = englishVoices()
        guard let bestQuality = voices.first?.quality else {
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        // Tarp geriausios kokybės balsų pirmenybė – amerikietiškam arba britiškam.
        let top = voices.filter { $0.quality == bestQuality }
        return top.first { $0.language == "en-US" }
            ?? top.first { $0.language == "en-GB" }
            ?? top.first
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}

extension DJVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finish(utterance)
            if self.currentUtterance == nil { self.isSpeaking = false }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finish(utterance)
            if self.currentUtterance == nil { self.isSpeaking = false }
        }
    }
}
