import Foundation

struct AnthropicProvider: ChatProvider {
    let profile: ModelProfileID = .opus5Max
    let apiKey: String?
    let model: String
    private let client = SSEClient()

    func stream(_ request: IntelligenceRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else {
            return failedStream(IntelligentCursorError.missingCredential("Opus 5 · Max needs ANTHROPIC_API_KEY in .env.local."))
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return failedStream(IntelligentCursorError.provider("The Anthropic endpoint is invalid."))
        }

        var content: [[String: Any]] = []
        if let image = request.context.image {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        content.append([
            "type": "text",
            "text": ProviderPromptEncoder.userText(for: request)
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64_000,
            "output_config": ["effort": request.effort.anthropicValue],
            "system": ProviderPromptEncoder.system,
            "messages": [["role": "user", "content": content]],
            "stream": true
        ]

        do {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 3_600
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            return client.stream(request: urlRequest) { data in
                guard let jsonData = data.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
                if json["type"] as? String == "content_block_delta",
                   let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta" {
                    return (delta["text"] as? String).map { .delta($0) }
                }
                if json["type"] as? String == "error",
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw IntelligentCursorError.provider(message)
                }
                return nil
            }
        } catch {
            return failedStream(error)
        }
    }
}

