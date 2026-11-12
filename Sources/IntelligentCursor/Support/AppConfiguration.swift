import Foundation
import Security

struct AppConfiguration: Sendable {
    let openAIAPIKey: String?
    let anthropicAPIKey: String?
    let xAIAPIKey: String?
    let openAIModel: String
    let anthropicModel: String
    let xAIModel: String
    let activationMouseButton: Int64

    func isConfigured(_ profile: ModelProfileID) -> Bool {
        switch profile {
        case .gpt56SolMax: openAIAPIKey?.isEmpty == false
        case .opus5Max: anthropicAPIKey?.isEmpty == false
        case .grok46Heavy: xAIAPIKey?.isEmpty == false
        case .allThree:
            openAIAPIKey?.isEmpty == false &&
            anthropicAPIKey?.isEmpty == false &&
            xAIAPIKey?.isEmpty == false
        }
    }
}

protocol SecretStore {
    func value(for key: String) -> String?
}

struct KeychainSecretStore: SecretStore {
    private let service = "com.caeseyfraser.intelligent-cursor"

    func value(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum ConfigurationLoader {
    static func load() -> AppConfiguration {
        let fileValues = loadEnvironmentFile()
        let processValues = ProcessInfo.processInfo.environment
        let keychain = KeychainSecretStore()

        func value(_ key: String) -> String? {
            let candidate = processValues[key] ?? keychain.value(for: key) ?? fileValues[key]
            return candidate?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let rawButton = Int64(value("INTELLIGENT_CURSOR_MOUSE_BUTTON") ?? "3") ?? 3
        return AppConfiguration(
            openAIAPIKey: value("OPENAI_API_KEY"),
            anthropicAPIKey: value("ANTHROPIC_API_KEY"),
            xAIAPIKey: value("XAI_API_KEY"),
            openAIModel: value("OPENAI_MODEL") ?? "gpt-5.6-sol",
            anthropicModel: value("ANTHROPIC_MODEL") ?? "claude-opus-5",
            xAIModel: value("XAI_MODEL") ?? "grok-4.6",
            activationMouseButton: rawButton
        )
    }

    /// A synced folder can stall a read indefinitely when its file provider is
    /// wedged. This runs on the main thread during launch, so an unbounded read
    /// hangs the entire app before it can draw a menu bar item, serve the menu, or
    /// log a single line — the app appears to start and then simply does nothing.
    ///
    /// Bound the wait and carry on without the file. Process environment values
    /// and the Keychain are unaffected, so credentials kept there still load.
    private static func readEnvironmentFile(at url: URL, timeout: TimeInterval = 1) -> String? {
        final class Box: @unchecked Sendable { var contents: String? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            box.contents = try? String(contentsOf: url, encoding: .utf8)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            Diagnostics.lifecycle.warning(
                "timed out reading the environment file; using process environment and Keychain only"
            )
            return nil
        }
        return box.contents
    }

    private static func loadEnvironmentFile() -> [String: String] {
        var candidates: [URL] = []
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env.local"))

        var cursor = Bundle.main.bundleURL
        for _ in 0..<9 {
            candidates.append(cursor.appendingPathComponent(".env.local"))
            cursor.deleteLastPathComponent()
        }

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let contents = readEnvironmentFile(at: url) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
