import Foundation

struct XAIProvider: ChatProvider {
    let profile: ModelProfileID = .grok46Heavy
    let apiKey: String?
    let model: String
    private let client = SSEClient()

    func stream(_ request: IntelligenceRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else {
            return failedStream(IntelligentCursorError.missingCredential("Grok 4.6 · Heavy needs XAI_API_KEY in .env.local."))
        }
        guard let url = URL(string: "https://api.x.ai/v1/responses") else {
            return failedStream(IntelligentCursorError.provider("The xAI endpoint is invalid."))
        }

        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": ProviderPromptEncoder.userText(for: request)
        ]]
        if let imageURL = ProviderPromptEncoder.imageDataURL(for: request) {
            content.append([
                "type": "input_image",
                "image_url": imageURL,
                "detail": "high"
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": request.effort.xAIValue],
            "input": [
                ["role": "system", "content": ProviderPromptEncoder.system],
                ["role": "user", "content": content]
            ],
            "stream": true
        ]

        do {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 3_600
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            return client.stream(request: urlRequest) { data in
                guard let jsonData = data.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
                if json["type"] as? String == "response.output_text.delta" {
                    return (json["delta"] as? String).map { .delta($0) }
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

