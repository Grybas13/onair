import AVFoundation

/// DJ balsas: nemokamas Apple sistemos balsas (AVSpeechSynthesizer).
/// Geresnės kokybės balsus galima atsisiųsti: Nustatymai → Pritaikymas neįgaliesiems →
/// Įgarsinamas turinys → Balsai → English.
@MainActor
final class DJVoice: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    /// Atskiras sintezatorius, kuris balso negroja, o tik paverčia jį garso buferiais.
    /// Taip Apple balso variklis neliečia programėlės garso sesijos (ir neužmigdo jos fone).
    private let renderer = AVSpeechSynthesizer()
    private var renderUtterance: AVSpeechUtterance?
    private var renderCollector: SpeechBufferCollector?
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        renderer.delegate = self
        renderer.usesApplicationAudioSession = true
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.selectedVoice()
        let rate = UserDefaults.standard.double(forKey: SettingsKeys.speechRate)
        utterance.rate = Float(rate > 0 ? rate : Double(AVSpeechUtteranceDefaultSpeechRate))
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.15
        return utterance
    }

    private var renderChain: Task<Void, Never>?

    /// Paverčia tekstą garso buferiais (standartinis float formatas), negrodamas jo.
    /// Grąžina tuščią masyvą, jei nepavyko – tada kviečiantis gali naudoti speak().
    /// Užklausos vykdomos paeiliui (vienas sintezatorius).
    func render(_ text: String) async -> [AVAudioPCMBuffer] {
        let previous = renderChain
        let task = Task { () -> [AVAudioPCMBuffer] in
            await previous?.value
            return await self.renderNow(text)
        }
        renderChain = Task { _ = await task.value }
        return await task.value
    }

    /// Ar naudoti Kokoro (pasirinkta ir modelis atsisiųstas).
    static var usesKokoro: Bool {
        UserDefaults.standard.string(forKey: SettingsKeys.voiceEngine) == "kokoro" && KokoroModelStore.isModelReady
    }

    /// Iš anksto įkelia Kokoro modelį, kad pirmas Dėdžio sakinys nevėluotų.
    func warmUp() {
        guard Self.usesKokoro, !KokoroEngine.shared.isLoaded else { return }
        Task.detached(priority: .utility) {
            _ = KokoroEngine.shared.loadIfNeeded()
        }
    }

    private func renderNow(_ text: String) async -> [AVAudioPCMBuffer] {
        if Self.usesKokoro {
            let voiceID = UserDefaults.standard.string(forKey: SettingsKeys.kokoroVoice) ?? KokoroEngine.defaultVoice
            let rate = UserDefaults.standard.double(forKey: SettingsKeys.speechRate)
            let speed = Float(1 + ((rate > 0 ? rate : 0.5) - 0.5) * 3)
            let samples = await Task.detached(priority: .userInitiated) {
                KokoroEngine.shared.synthesize(text, voice: voiceID, speed: speed)
            }.value
            if let samples, let buffer = KokoroEngine.buffer(from: samples) {
                return [buffer]
            }
            trace("Kokoro balsas nepavyko – šįkart naudoju Apple balsą")
        }
        return await renderWithApple(text)
    }

    private func renderWithApple(_ text: String) async -> [AVAudioPCMBuffer] {
        let utterance = makeUtterance(text)
        let collector = SpeechBufferCollector()
        let words = Double(text.split(separator: " ").count)
        let timeout = words / 3.0 + 6

        renderUtterance = utterance
        renderCollector = collector
        let buffers = await withCheckedContinuation { (continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            collector.set(continuation)
            renderer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    collector.finish()
                } else if let converted = Self.toStandardFloat(pcm) {
                    collector.append(converted)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                collector.finish()
            }
        }
        if renderUtterance === utterance {
            renderUtterance = nil
            renderCollector = nil
        }
        if buffers.isEmpty {
            trace("DJ balsas: nepavyko paruošti garso buferių")
        }
        return buffers
    }

    nonisolated private static func toStandardFloat(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outFormat = AVAudioFormat(
            standardFormatWithSampleRate: input.format.sampleRate,
            channels: input.format.channelCount
        ),
        let converter = AVAudioConverter(from: input.format, to: outFormat),
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: input.frameLength) else {
            return nil
        }
        do {
            try converter.convert(to: output, from: input)
        } catch {
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    /// Pasako tekstą ir grįžta, kai baigia (arba po saugos laiko).
    func speak(_ text: String) async {
        if let previous = currentUtterance {
            finish(previous)
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = makeUtterance(text)

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
            if utterance === self.renderUtterance {
                // Leidžiame paskutiniams buferiams atkeliauti.
                let collector = self.renderCollector
                try? await Task.sleep(for: .milliseconds(150))
                collector?.finish()
                return
            }
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

/// Surenka sintezatoriaus buferius iš bet kurios gijos ir grąžina juos vieną kartą.
final class SpeechBufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    func set(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if continuation != nil {
            buffers.append(buffer)
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let pending = continuation
        let result = buffers
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
