import Foundation

/// Groq (nemokamas planas) – kalbos modelis Dėdžio tekstams.
/// Jei modelis grąžina klaidą, jis trumpam praleidžiamas ir bandomas kitas;
/// tikroji Groq klaidos žinutė visada įrašoma į žurnalą.
@MainActor
final class GroqClient {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let models = ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b", "openai/gpt-oss-20b"]
    private var modelPausedUntil: [String: Date] = [:]
    private var pausedUntil = Date.distantPast
    private(set) var lastError: String?
    private(set) var lastModel: String?

    var isConfigured: Bool { !Config.groqAPIKey.isEmpty }

    func complete(system: String, user: String) async -> String? {
        guard isConfigured else {
            lastError = "Nėra GROQ_API_KEY"
            return nil
        }
        guard Date() >= pausedUntil else { return nil }

        for model in models {
            if let until = modelPausedUntil[model], until > Date() { continue }
            let outcome = await request(model: model, system: system, user: user)
            switch outcome {
            case .success(let text):
                lastModel = model
                lastError = nil
                return text
            case .modelProblem(let message):
                modelPausedUntil[model] = Date().addingTimeInterval(30 * 60)
                trace("Groq: \(model) – \(message). Bandau kitą modelį")
                continue
            case .rateLimited(let seconds, let message):
                pausedUntil = Date().addingTimeInterval(seconds)
                trace("Groq: limitas (\(message)) – \(Int(seconds)) s naudoju šablonus")
                return nil
            case .unauthorized(let message):
                pausedUntil = Date().addingTimeInterval(600)
                trace("Groq: raktas nepriimtas (\(message)) – naudoju šablonus")
                return nil
            case .failed(let message):
                trace("Groq: \(model) – \(message)")
                return nil
            }
        }
        return nil
    }

    private enum Outcome {
        case success(String)
        case modelProblem(String)
        case rateLimited(TimeInterval, String)
        case unauthorized(String)
        case failed(String)
    }

    private func request(model: String, system: String, user: String) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(Config.groqAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 1.0,
            "max_completion_tokens": model.hasPrefix("openai/") ? 900 : 200
        ]
        if model.hasPrefix("openai/") {
            body["reasoning_effort"] = "low"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed("JSON klaida") }
        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let message = Self.errorMessage(from: responseData)

            switch status {
            case 200:
                let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
                let choices = json?["choices"] as? [[String: Any]]
                let reply = choices?.first?["message"] as? [String: Any]
                if let content = reply?["content"] as? String, !content.isEmpty {
                    return .success(content)
                }
                lastError = "Tuščias atsakymas"
                return .modelProblem("tuščias atsakymas")
            case 401:
                lastError = "HTTP 401: \(message)"
                return .unauthorized(message)
            case 429:
                lastError = "HTTP 429: \(message)"
                let retry = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 120
                return .rateLimited(max(30, retry), message)
            case 400, 403, 404:
                lastError = "HTTP \(status): \(message)"
                return .modelProblem("HTTP \(status): \(message)")
            default:
                lastError = "HTTP \(status): \(message)"
                return .failed("HTTP \(status): \(message)")
            }
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Ištraukia Groq klaidos žinutę (arba atsakymo pradžią).
    nonisolated static func errorMessage(from data: Data) -> String {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let code = error["code"] as? String ?? ""
            let message = error["message"] as? String ?? ""
            return code.isEmpty ? message : "\(code): \(message)"
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "\(data.count) B"
    }
}
