import Foundation

final class IntelligenceRouter {
    private let providers: [ModelProfileID: any ChatProvider]

    init(configuration: AppConfiguration) {
        providers = [
            .gpt56SolMax: OpenAIProvider(apiKey: configuration.openAIAPIKey, model: configuration.openAIModel),
            .opus5Max: AnthropicProvider(apiKey: configuration.anthropicAPIKey, model: configuration.anthropicModel),
            .grok46Heavy: XAIProvider(apiKey: configuration.xAIAPIKey, model: configuration.xAIModel)
        ]
    }

    func stream(_ request: IntelligenceRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        if request.profile == .allThree { return councilStream(request) }
        guard let provider = providers[request.profile] else {
            return failedStream(IntelligentCursorError.unsupported("That intelligence route is not available."))
        }
        return provider.stream(request)
    }

    private func councilStream(_ request: IntelligenceRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let profiles: [ModelProfileID] = [.gpt56SolMax, .opus5Max, .grok46Heavy]
                var successes = 0
                continuation.yield(.status("Asking all three…"))

                await withTaskGroup(of: (ModelProfileID, Result<String, Error>).self) { group in
                    for profile in profiles {
                        guard let provider = providers[profile] else { continue }
                        group.addTask {
                            var text = ""
                            do {
                                let routed = IntelligenceRequest(
                                    profile: profile,
                                    effort: request.effort,
                                    prompt: request.prompt,
                                    context: request.context,
                                    history: request.history
                                )
                                for try await event in provider.stream(routed) {
                                    if case let .delta(chunk) = event { text += chunk }
                                }
                                return (profile, .success(text))
                            } catch {
                                return (profile, .failure(error))
                            }
                        }
                    }

                    for await (profile, result) in group {
                        guard !Task.isCancelled else { break }
                        switch result {
                        case let .success(text):
                            successes += 1
                            continuation.yield(.delta("\n\n### \(profile.displayName)\n\n\(text)"))
                        case let .failure(error):
                            continuation.yield(.delta("\n\n### \(profile.displayName)\n\nUnavailable: \(error.localizedDescription)"))
                        }
                    }
                }

                if Task.isCancelled {
                    continuation.finish()
                } else if successes == 0 {
                    continuation.finish(throwing: IntelligentCursorError.provider("None of the three model routes completed."))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
