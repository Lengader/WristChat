import Foundation

enum ResponseStream {
    private struct Catalog: Decodable {
        struct Model: Decodable { let slug: String; let visibility: String }
        let models: [Model]
    }

    private struct StreamEvent: Decodable {
        struct Failure: Decodable { let code: String? }
        struct Result: Decodable { let error: Failure? }
        let type: String
        let delta: String?
        let code: String?
        let response: Result?
    }

    static func model(using token: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: OpenAI.authorized("/models", token: token))
        try OpenAI.check(response)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let available = catalog.models.filter { $0.visibility == "list" }
        guard let selected = available.first(where: { $0.slug == "gpt-6.2-sol" }) ?? available.first else {
            throw WristError.noModels
        }
        return selected.slug
    }

    static func answer(model: String, mode: ReasoningMode, context: [ChatMessage], token: String,
                       receive: (String) async -> Void) async throws -> String {
        var request = OpenAI.authorized("/responses", token: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Retain recent image context without re-uploading the entire photo history on every turn.
        let photos = Set(context.filter { $0.photo != nil }.suffix(2).map(\.id))
        let input: [[String: Any]] = context.map { message in
            guard let photo = message.photo, photos.contains(message.id) else {
                return ["role": message.role.rawValue, "content": message.content.isEmpty ? "[Фото]" : message.content]
            }
            return ["role": "user", "content": [
                ["type": "input_text", "text": message.content.isEmpty ? "Что на этом фото?" : message.content],
                ["type": "input_image", "image_url": "data:image/jpeg;base64," + photo.base64EncodedString(), "detail": "auto"],
            ]]
        }
        var body: [String: Any] = [
            "model": model, "store": false, "stream": true, "input": input,
            "instructions": #"Reply concisely in the user's language. Use \(...\) for inline math and \[...\] for display math. Break wide multi-step equations into aligned rows where appropriate for the Apple Watch screen."#,
        ]
        if let effort = mode.effort { body["reasoning"] = ["effort": effort] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 400 {
            var details = ""
            for try await line in bytes.lines {
                details += line.lowercased()
                if details.utf8.count >= 8_192 { break }
            }
            if mode.effort != nil, details.contains("reasoning") { throw WristError.reasoningUnavailable }
            if !photos.isEmpty, details.contains("image") || details.contains("vision") { throw WristError.photoUnavailable }
        }
        try OpenAI.check(response)

        let decoder = JSONDecoder()
        var text = ""
        for try await line in bytes.lines where line.hasPrefix("data:") {
            try Task.checkCancellation()
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard !payload.isEmpty else { continue }
            let event = try decoder.decode(StreamEvent.self, from: Data(payload.utf8))
            switch event.type {
            case "response.output_text.delta", "response.refusal.delta":
                if let delta = event.delta {
                    text += delta
                    await receive(delta)
                }
            case "response.completed":
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { throw WristError.invalidResponse }
                return answer
            case "response.failed", "response.incomplete", "error":
                if event.response?.error?.code == "subscription_sharing_usage_limit_exceeded" ||
                    event.code == "subscription_sharing_usage_limit_exceeded" { throw WristError.service(429) }
                throw WristError.invalidResponse
            default: continue
            }
        }
        throw WristError.invalidResponse
    }
}
