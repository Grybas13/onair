import Foundation

/// Paprastas žurnalas, matomas programėlės „Log“ skirtuke.
/// Jį galima eksportuoti ir atsiųsti, kai kažkas neveikia.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []
    private let maxLines = 1500
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        print(line)
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

/// Galima kviesti iš bet kurios gijos.
func trace(_ message: String) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            AppLog.shared.append(message)
        }
    } else {
        Task { @MainActor in
            AppLog.shared.append(message)
        }
    }
}
