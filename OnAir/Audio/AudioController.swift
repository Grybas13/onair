import AVFoundation
import UIKit

/// Valdo programėlės garso sesiją:
/// 1) „fono palaikymas“ – groja tylą, kad iOS neužmigdytų programėlės, kol veikia stotis;
/// 2) „patylinimas“ (ducking) – kol DJ kalba, iOS patylina Spotify.
///
/// Sesija visada „mixWithOthers“, todėl Spotify niekada nesustabdomas – tik patylinamas.
@MainActor
final class AudioController {
    private let engine = AVAudioEngine()
    private let silenceNode = AVAudioPlayerNode()
    /// DJ balsas groja per tą patį variklį, kad garso sesija visada priklausytų tik mums.
    private let speechNode = AVAudioPlayerNode()
    /// Visas DJ balsas paverčiamas į vieną pastovų formatą – kad greitis ir tonas
    /// visada būtų teisingi, nepriklausomai nuo balso variklio (Apple 22 kHz, Kokoro 24 kHz).
    private let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var silenceBuffer: AVAudioPCMBuffer?
    private var observers: [NSObjectProtocol] = []

    private(set) var isKeepAliveRunning = false
    private(set) var isDucking = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.attach(silenceNode)
        engine.connect(silenceNode, to: engine.mainMixerNode, format: format)
        engine.attach(speechNode)
        engine.connect(speechNode, to: engine.mainMixerNode, format: speechFormat)

        let frames: AVAudioFrameCount = 44_100
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            buffer.frameLength = frames
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    memset(channels[channel], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }
            silenceBuffer = buffer
        }

        registerObservers()
    }

    // MARK: - Fono palaikymas

    func startKeepAlive() {
        guard !isKeepAliveRunning else { return }
        do {
            try applySession(duck: false)
            try startEngine()
            isKeepAliveRunning = true
            trace("Audio: fono palaikymas įjungtas")
        } catch {
            trace("Audio: nepavyko įjungti fono palaikymo: \(error.localizedDescription)")
        }
    }

    func stopKeepAlive() {
        guard isKeepAliveRunning else { return }
        stopEngine()
        isKeepAliveRunning = false
        isDucking = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            trace("Audio: setActive(false) klaida: \(error.localizedDescription)")
        }
        trace("Audio: fono palaikymas išjungtas")
    }

    var isEngineRunning: Bool { engine.isRunning }

    /// Jei fono palaikymas turėtų veikti, bet variklis sustojęs – paleidžia iš naujo.
    func ensureKeepAliveHealthy() {
        guard isKeepAliveRunning, !engine.isRunning || !silenceNode.isPlaying else { return }
        trace("Audio: fono palaikymas buvo sustojęs – atkuriu")
        restartAfterProblem()
    }

    // MARK: - DJ balsas

    /// Sugroja paruoštus DJ balso garso buferius ir grįžta, kai jie baigiasi.
    func playSpeech(_ input: [AVAudioPCMBuffer]) async {
        guard let converted = Self.convertForSpeech(input, to: speechFormat) else {
            trace("Audio: balso garso nepavyko paruošti")
            return
        }
        let buffers = [converted]
        let seconds = Double(converted.frameLength) / converted.format.sampleRate
        let appState = UIApplication.shared.applicationState == .background ? "fone" : "ekrane"
        trace(String(format: "Audio: groju balsą %.1f s (programėlė %@, variklis %@, patylinta: %@)",
                     seconds, appState, engine.isRunning ? "veikia" : "SUSTOJĘS", isDucking ? "taip" : "ne"))
        do {
            if !engine.isRunning {
                try AVAudioSession.sharedInstance().setActive(true)
                engine.prepare()
                try engine.start()
            }
        } catch {
            trace("Audio: nepavyko paleisti variklio balsui: \(error.localizedDescription)")
            return
        }


        let totalSeconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        let gate = ResumeGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.set(continuation)
            for (index, buffer) in buffers.enumerated() {
                if index == buffers.count - 1 {
                    speechNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                        gate.resume()
                    }
                } else {
                    speechNode.scheduleBuffer(buffer, completionHandler: nil)
                }
            }
            speechNode.play()
            // Saugiklis, jei iOS neiškviestų pabaigos (pvz. pasikeitus ausinėms).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(totalSeconds + 3))
                gate.resume()
            }
        }
        speechNode.stop()
    }

    /// Sujungia buferius į vieną ir perskaičiuoja į nurodytą formatą (dažnį ir kanalus).
    static func convertForSpeech(_ buffers: [AVAudioPCMBuffer], to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0,
              let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let destination = merged.floatChannelData else { return nil }

        var offset = 0
        for buffer in buffers where buffer.format == format {
            guard let source = buffer.floatChannelData else { continue }
            let frames = Int(buffer.frameLength)
            for channel in 0..<Int(format.channelCount) {
                (destination[channel] + offset).update(from: source[channel], count: frames)
            }
            offset += frames
        }
        merged.frameLength = AVAudioFrameCount(offset)

        if format == target { return merged }
        guard let converter = AVAudioConverter(from: format, to: target) else { return nil }
        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(merged.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return merged
        }
        if status == .error || output.frameLength == 0 {
            trace("Audio: perskaičiavimo klaida \(error?.localizedDescription ?? "")")
            return nil
        }
        return output
    }

    // MARK: - Patylinimas

    /// Patylina kitų programėlių (Spotify) garsą.
    func beginDuck() {
        guard !isDucking else { return }
        isDucking = true
        reconfigure(duck: true)
        let session = AVAudioSession.sharedInstance()
        trace("Audio: Spotify patylintas (kitas garsas groja: \(session.isOtherAudioPlaying ? "taip" : "ne"), variklis: \(engine.isRunning ? "veikia" : "SUSTOJĘS"))")
    }

    /// Grąžina normalų Spotify garsą.
    func endDuck() {
        guard isDucking else { return }
        isDucking = false
        if isKeepAliveRunning {
            reconfigure(duck: false)
        } else {
            // Stotis neveikia (pvz. balso testas nustatymuose) – tiesiog atiduodame garsą.
            stopEngine()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                trace("Audio: setActive(false) klaida: \(error.localizedDescription)")
            }
        }
        trace("Audio: Spotify garsas grąžintas")
    }

    /// iOS patylinimą įjungia/išjungia tik aktyvuojant sesiją iš naujo,
    /// todėl trumpam sustabdome tylos grotuvą, perjungiame nustatymus ir paleidžiame vėl.
    private func reconfigure(duck: Bool) {
        stopEngine()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            trace("Audio: setActive(false) klaida: \(error.localizedDescription)")
        }
        do {
            try applySession(duck: duck)
            if isKeepAliveRunning || duck {
                try startEngine()
            }
        } catch {
            trace("Audio: sesijos perjungimo klaida: \(error.localizedDescription)")
        }
    }

    // MARK: - Vidinės

    private func applySession(duck: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if duck {
            options.insert(.duckOthers)
        }
        try session.setCategory(.playback, mode: .default, options: options)
        try session.setActive(true)
    }

    private func startEngine() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !silenceNode.isPlaying, let buffer = silenceBuffer {
            silenceNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            silenceNode.play()
        }
    }

    private func stopEngine() {
        silenceNode.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            MainActor.assumeIsolated {
                self?.handleInterruption(type)
            }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEngineConfigurationChange()
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                trace("Audio: iOS perkrovė garso paslaugas")
                self?.restartAfterProblem()
            }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .some(.began):
            trace("Audio: pertraukimas (pvz. skambutis)")
        case .some(.ended):
            trace("Audio: pertraukimas baigėsi")
            restartAfterProblem()
        default:
            break
        }
    }

    private func handleEngineConfigurationChange() {
        trace("Audio: pasikeitė garso išvestis (pvz. ausinės)")
        restartAfterProblem()
    }

    private func restartAfterProblem() {
        guard isKeepAliveRunning else { return }
        do {
            try applySession(duck: isDucking)
            silenceNode.stop()
            try startEngine()
            trace("Audio: fono palaikymas atkurtas")
        } catch {
            trace("Audio: nepavyko atkurti: \(error.localizedDescription)")
        }
    }
}

/// Užtikrina, kad tęsinys būtų pratęstas lygiai vieną kartą (iš bet kurios gijos).
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
