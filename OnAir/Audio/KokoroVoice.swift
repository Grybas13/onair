import Foundation
import AVFoundation
import MLX
import MLXUtilsLibrary
import KokoroSwift

/// Kokoro neuroninio balso modelio (327 MB) atsisiuntimas ir būsena.
/// Modelis siunčiamas vieną kartą iš HuggingFace ir lieka telefone
/// (išlieka ir perdiegus programėlę per Sideloadly).
@MainActor
final class KokoroModelStore: NSObject, ObservableObject {
    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    static let shared = KokoroModelStore()

    nonisolated static let modelURL = URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    nonisolated static let expectedBytes: Int64 = 327_115_152

    @Published private(set) var state: State = .missing

    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    nonisolated static var modelFileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kokoro", isDirectory: true)
        return directory.appendingPathComponent("kokoro-v1_0.safetensors")
    }

    nonisolated static var voicesFileURL: URL? {
        Bundle.main.url(forResource: "voices", withExtension: "npz")
    }

    /// Ar modelis atsisiųstas ir pilnas (tikriname dydį – sugadintas failas užlaužtų programėlę).
    nonisolated static var isModelReady: Bool {
        let path = modelFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value == expectedBytes
    }

    override init() {
        super.init()
        state = Self.isModelReady ? .ready : .missing
    }

    func download() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        trace("Kokoro: pradedu siųsti modelį (327 MB)")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: Self.modelURL)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = Self.isModelReady ? .ready : .missing
    }

    func deleteModel() {
        try? FileManager.default.removeItem(at: Self.modelFileURL)
        state = .missing
        KokoroEngine.shared.unload()
    }

    fileprivate func finish(with location: URL?, error: String?) {
        defer {
            task = nil
            session?.finishTasksAndInvalidate()
            session = nil
        }
        if let error {
            state = .failed(error)
            trace("Kokoro: siuntimas nepavyko – \(error)")
            return
        }
        guard let location else { return }
        do {
            let destination = Self.modelFileURL
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDestination = destination
            try? mutableDestination.setResourceValues(values)

            if Self.isModelReady {
                state = .ready
                trace("Kokoro: modelis atsisiųstas")
            } else {
                try? FileManager.default.removeItem(at: destination)
                state = .failed("Atsisiųstas failas netinkamo dydžio")
                trace("Kokoro: atsisiųstas failas netinkamo dydžio")
            }
        } catch {
            state = .failed(error.localizedDescription)
            trace("Kokoro: nepavyko išsaugoti modelio – \(error.localizedDescription)")
        }
    }
}

extension KokoroModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : KokoroModelStore.expectedBytes
        let progress = Double(totalBytesWritten) / Double(total)
        MainActor.assumeIsolated {
            self.state = .downloading(min(1, progress))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Laikinas failas dingsta grįžus iš šio metodo – perkeliame iškart (sinchroniškai).
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-download.safetensors")
        try? FileManager.default.removeItem(at: staging)
        let moved = (try? FileManager.default.moveItem(at: location, to: staging)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            if status != 200 {
                self.finish(with: nil, error: "HTTP \(status)")
            } else {
                self.finish(with: moved ? staging : nil, error: moved ? nil : "Nepavyko perkelti failo")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.finish(with: nil, error: message)
        }
    }
}

/// Jei programėlė užlūžta Kokoro įkėlimo ar kalbėjimo metu, kitą kartą atidarius
/// automatiškai perjungiamas Apple balsas (kad Dėdis neužlaužtų programėlės vėl ir vėl).
/// Žymė saugoma faile, nes UserDefaults užlūžus gali nespėti išsisaugoti.
enum KokoroCrashGuard {
    private static var markerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro-in-progress.txt")
    }

    static let crashedStageKey = "kokoroCrashedStage"

    static func begin(_ stage: String) {
        try? stage.data(using: .utf8)?.write(to: markerURL, options: .atomic)
    }

    static func end() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func checkAtLaunch() {
        guard let data = try? Data(contentsOf: markerURL),
              let stage = String(data: data, encoding: .utf8) else { return }
        end()
        UserDefaults.standard.set("apple", forKey: SettingsKeys.voiceEngine)
        UserDefaults.standard.set(stage, forKey: crashedStageKey)
        trace("Kokoro: praeitą kartą programėlė užlūžo („\(stage)“) – perjungiau į Apple balsą")
    }
}

/// Kokoro TTS variklis. Veikia tik CPU: iOS draudžia naudoti GPU fone (užrakintu ekranu),
/// o Dėdis turi kalbėti ir tada.
final class KokoroEngine: @unchecked Sendable {
    static let shared = KokoroEngine()

    static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    /// Balsų sąrašas (rodomi pavadinimai). Pirmoji raidė: a – amerikietiškas, b – britiškas;
    /// antroji: f – moteriškas, m – vyriškas.
    struct VoiceOption: Identifiable {
        let id: String
        let title: String
    }

    static let voiceNames: [VoiceOption] = [
        VoiceOption(id: "am_michael", title: "Michael · US vyras"),
        VoiceOption(id: "am_fenrir", title: "Fenrir · US vyras"),
        VoiceOption(id: "am_puck", title: "Puck · US vyras"),
        VoiceOption(id: "am_echo", title: "Echo · US vyras"),
        VoiceOption(id: "am_eric", title: "Eric · US vyras"),
        VoiceOption(id: "am_liam", title: "Liam · US vyras"),
        VoiceOption(id: "am_onyx", title: "Onyx · US vyras"),
        VoiceOption(id: "am_adam", title: "Adam · US vyras"),
        VoiceOption(id: "am_santa", title: "Santa · US vyras"),
        VoiceOption(id: "bm_george", title: "George · UK vyras"),
        VoiceOption(id: "bm_fable", title: "Fable · UK vyras"),
        VoiceOption(id: "bm_lewis", title: "Lewis · UK vyras"),
        VoiceOption(id: "bm_daniel", title: "Daniel · UK vyras"),
        VoiceOption(id: "af_heart", title: "Heart · US moteris"),
        VoiceOption(id: "af_bella", title: "Bella · US moteris"),
        VoiceOption(id: "af_nicole", title: "Nicole · US moteris"),
        VoiceOption(id: "af_sarah", title: "Sarah · US moteris"),
        VoiceOption(id: "af_nova", title: "Nova · US moteris"),
        VoiceOption(id: "af_sky", title: "Sky · US moteris"),
        VoiceOption(id: "af_jessica", title: "Jessica · US moteris"),
        VoiceOption(id: "af_river", title: "River · US moteris"),
        VoiceOption(id: "af_aoede", title: "Aoede · US moteris"),
        VoiceOption(id: "af_kore", title: "Kore · US moteris"),
        VoiceOption(id: "af_alloy", title: "Alloy · US moteris"),
        VoiceOption(id: "bf_emma", title: "Emma · UK moteris"),
        VoiceOption(id: "bf_isabella", title: "Isabella · UK moteris"),
        VoiceOption(id: "bf_alice", title: "Alice · UK moteris"),
        VoiceOption(id: "bf_lily", title: "Lily · UK moteris")
    ]

    static let defaultVoice = "am_michael"

    /// MLX visam laikui nukreipiamas į CPU (GPU fone iOS draudžia).
    static func configureCPUOnly() {
        Device.setDefault(device: .cpu)
    }

    private let lock = NSLock()
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return tts != nil
    }

    func unload() {
        lock.lock(); defer { lock.unlock() }
        tts = nil
        voices = [:]
    }

    /// Įkelia modelį (užtrunka kelias sekundes). Kviesti ne pagrindinėje gijoje.
    func loadIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tts != nil { return true }
        guard KokoroModelStore.isModelReady, let voicesURL = KokoroModelStore.voicesFileURL else { return false }

        let started = Date()
        trace("Kokoro: skaitau balsus")
        KokoroCrashGuard.begin("balsų skaitymas")
        let loadedVoices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        guard !loadedVoices.isEmpty else {
            KokoroCrashGuard.end()
            trace("Kokoro: nepavyko perskaityti balsų failo")
            return false
        }
        trace("Kokoro: balsų \(loadedVoices.count), įkeliu modelį")
        KokoroCrashGuard.begin("modelio įkėlimas")
        let engine = Device.withDefaultDevice(.cpu) {
            KokoroTTS(modelPath: KokoroModelStore.modelFileURL, g2p: .misaki)
        }
        KokoroCrashGuard.end()
        tts = engine
        voices = loadedVoices
        trace(String(format: "Kokoro: modelis įkeltas per %.1f s", Date().timeIntervalSince(started)))
        return true
    }

    /// Sugeneruoja balsą. Ilgą tekstą skaido sakiniais (modelis turi ribą).
    /// `useGPU` – tik kai programėlė ekrane (fone iOS GPU draudžia; CPU per lėtas – ~0.1x).
    func synthesize(_ text: String, voice: String, speed: Float, useGPU: Bool) -> [Float]? {
        guard loadIfNeeded() else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let tts else { return nil }
        let voiceKey = voices["\(voice).npy"] != nil ? voice : Self.defaultVoice
        guard let style = voices["\(voiceKey).npy"] else { return nil }
        let language: Language = voiceKey.hasPrefix("b") ? .enGB : .enUS

        let started = Date()
        var samples: [Float] = []
        let pause = [Float](repeating: 0, count: Int(Self.sampleRate * 0.12))
        for sentence in Self.sentences(Self.prepare(text)) {
            do {
                KokoroCrashGuard.begin("kalbos generavimas")
                defer { KokoroCrashGuard.end() }
                let (audio, _) = try Device.withDefaultDevice(useGPU ? .gpu : .cpu) {
                    try tts.generateAudio(voice: style, language: language, text: sentence, speed: speed)
                }
                if !samples.isEmpty { samples += pause }
                samples += audio
            } catch {
                trace("Kokoro: sakinio nepavyko įgarsinti (\(error)) – „\(sentence.prefix(40))…“")
            }
        }
        guard !samples.isEmpty else { return nil }
        let seconds = Double(samples.count) / Self.sampleRate
        let elapsed = max(0.01, Date().timeIntervalSince(started))
        trace(String(format: "Kokoro: %.1f s balso per %.1f s (%.1fx)", seconds, elapsed, seconds / elapsed))
        return samples
    }

    /// Paverčia mėginius garso buferiu, kurį groja mūsų garso variklis.
    static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    /// Tarimas: „Dėdis“ → „Dehdis“, lietuviškos raidės → lotyniškos, simboliai → žodžiai.
    static func prepare(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "Dėdis", with: "Dehdis")
            .replacingOccurrences(of: "Dėdžio", with: "Dehdis's")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "%", with: " percent")
        result = result.applyingTransform(.stripDiacritics, reverse: false) ?? result
        return result
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                result.append(sentence)
            }
        }
        return result.isEmpty ? [text] : result
    }
}
