import Foundation

struct OpenAIProvider: ChatProvider {
    let profile: ModelProfileID = .gpt56SolMax
    let apiKey: String?
    let model: String
    private let client = SSEClient()

    func stream(_ request: IntelligenceRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else {
            return failedStream(IntelligentCursorError.missingCredential("GPT-5.6 Sol · Max needs OPENAI_API_KEY."))
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            return failedStream(IntelligentCursorError.provider("The OpenAI endpoint is invalid."))
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

        // The tool is offered only when the question needs it. Held permanently,
        // the model reaches for it on ordinary questions and every answer becomes
        // a slow one.
        let researching = ResearchIntent.requiresLiveInformation(request.prompt)
        var body: [String: Any] = [
            "model": model,
            "instructions": ProviderPromptEncoder.system,
            "reasoning": ["effort": request.effort.openAIValue],
            "input": [["role": "user", "content": content]],
            "stream": true,
            "store": false
        ]
        if researching {
            body["tools"] = [["type": "web_search"]]
        }

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
                switch json["type"] as? String {
                case "response.output_text.delta":
                    return (json["delta"] as? String).map { .delta($0) }
                case "response.output_item.added":
                    let item = json["item"] as? [String: Any]
                    guard item?["type"] as? String == "web_search_call" else { return nil }
                    return .status("Searching the web…")
                case "error":
                    guard let error = json["error"] as? [String: Any],
                          let message = error["message"] as? String else { return nil }
                    throw IntelligentCursorError.provider(message)
                default:
                    return nil
                }
            }
        } catch {
            return failedStream(error)
        }
    }
}

func failedStream(_ error: Error) -> AsyncThrowingStream<ProviderEvent, Error> {
    AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
}

