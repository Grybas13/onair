import AVFoundation

/// Valdo programėlės garso sesiją:
/// 1) „fono palaikymas“ – groja tylą, kad iOS neužmigdytų programėlės, kol veikia stotis;
/// 2) „patylinimas“ (ducking) – kol DJ kalba, iOS patylina Spotify.
///
/// Sesija visada „mixWithOthers“, todėl Spotify niekada nesustabdomas – tik patylinamas.
@MainActor
final class AudioController {
    private let engine = AVAudioEngine()
    private let silenceNode = AVAudioPlayerNode()
    private var silenceBuffer: AVAudioPCMBuffer?
    private var observers: [NSObjectProtocol] = []

    private(set) var isKeepAliveRunning = false
    private(set) var isDucking = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.attach(silenceNode)
        engine.connect(silenceNode, to: engine.mainMixerNode, format: format)

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

    // MARK: - Patylinimas

    /// Patylina kitų programėlių (Spotify) garsą.
    func beginDuck() {
        guard !isDucking else { return }
        isDucking = true
        reconfigure(duck: true)
        trace("Audio: Spotify patylintas")
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
