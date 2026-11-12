import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechInputController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: CGFloat = 0

    private let permissionManager: PermissionManager
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false
    private var onTranscript: ((String) -> Void)?
    private var onError: ((String) -> Void)?

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    /// Speech recognition reports "no speech detected" and its siblings as errors
    /// even though they are the normal way a dictation ends when the user pauses or
    /// stops without speaking.
    private static func isBenignRecognitionEnd(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == "kAFAssistantErrorDomain" else { return false }
        return [203, 216, 1110, 1107].contains(error.code)
    }

    func toggle(
        onTranscript: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        if isRecording {
            stop()
            return
        }

        self.onTranscript = onTranscript
        self.onError = onError
        permissionManager.requestVoicePermissions { [weak self] granted in
            guard let self else { return }
            if granted {
                self.start()
            } else {
                onError("Microphone and Speech Recognition access are required for voice. Typing remains available.")
            }
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        level = 0
    }

    private func start() {
        stop()
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech Recognition is currently unavailable. You can keep typing.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.onTranscript?(result.bestTranscription.formattedString)
                    if result.isFinal { self.stop() }
                }
                if let error {
                    // Ending a dictation without saying anything is ordinary, not a
                    // failure worth putting a red bar under someone's answer.
                    if Self.isBenignRecognitionEnd(error) {
                        self.stop()
                    } else {
                        self.onError?(error.localizedDescription)
                        self.stop()
                    }
                }
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += channel[index] * channel[index] }
            let rms = sqrt(sum / Float(count))
            let normalized = min(max(CGFloat(rms) * 9, 0), 1)
            DispatchQueue.main.async { self?.level = normalized }
        }
        hasInstalledTap = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            onError?("The microphone could not start: \(error.localizedDescription)")
            stop()
        }
    }
}
