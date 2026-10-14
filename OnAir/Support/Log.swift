import Foundation

/// Žurnalas, matomas „Žurnalas“ skirtuke.
/// Kiekviena eilutė iškart įrašoma ir į failą, todėl net programėlei užlūžus
/// kitą kartą atidarius matosi, kas vyko prieš pat užlūžimą.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []
    private let maxLines = 1500

    init() {
        let previous = LogFile.shared.takePreviousSession()
        if !previous.isEmpty {
            lines.append("—— Ankstesnė sesija ——")
            lines.append(contentsOf: previous)
            lines.append("—— Dabartinė sesija ——")
        }
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() {
        lines.removeAll()
    }

    var fullText: String {
        lines.joined(separator: "\n")
    }
}

/// Sinchroniškas rašymas į failą (saugus iš bet kurios gijos).
final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    private let lock = NSLock()
    private let url: URL
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("onair-log.txt")
    }

    /// Grąžina paskutines ankstesnės sesijos eilutes ir pradeda failą iš naujo.
    func takePreviousSession(limit: Int = 250) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var previous: [String] = []
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            previous = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit).map(String.init)
        }
        try? Data().write(to: url, options: .atomic)
        handle = try? FileHandle(forWritingTo: url)
        return previous
    }

    func write(_ message: String) -> String {
        let line = "\(formatter.string(from: Date()))  \(message)"
        lock.lock(); defer { lock.unlock() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
        }
        if let handle, let data = (line + "\n").data(using: .utf8) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        return line
    }
}

/// Galima kviesti iš bet kurios gijos.
func trace(_ message: String) {
    let line = LogFile.shared.write(message)
    print(line)
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            AppLog.shared.append(line)
        }
    } else {
        Task { @MainActor in
            AppLog.shared.append(line)
        }
    }
}
