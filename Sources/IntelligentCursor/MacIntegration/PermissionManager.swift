import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Speech

enum PermissionState: String {
    case granted
    case denied
    case notDetermined
    case restricted

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.circle.fill"
        case .notDetermined: "circle.dotted"
        case .restricted: "lock.circle.fill"
        }
    }
}

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var inputMonitoring: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined
    @Published private(set) var screenRecording: PermissionState = .notDetermined
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var speechRecognition: PermissionState = .notDetermined

    init() { refresh() }

    func refresh() {
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .notDetermined
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .restricted
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechRecognition = .granted
        case .denied: speechRecognition = .denied
        case .restricted: speechRecognition = .restricted
        case .notDetermined: speechRecognition = .notDetermined
        @unknown default: speechRecognition = .restricted
        }
    }

    func requestContextPermissions() {
        _ = CGRequestListenEventAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestScreenCaptureAccess()
        scheduleRefresh()
    }

    func requestVoicePermissions(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] microphoneGranted in
            SFSpeechRecognizer.requestAuthorization { speechStatus in
                DispatchQueue.main.async {
                    self?.refresh()
                    completion(microphoneGranted && speechStatus == .authorized)
                }
            }
        }
    }

    func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }
    func openInputMonitoringSettings() { openPrivacyPane("Privacy_ListenEvent") }
    func openScreenRecordingSettings() { openPrivacyPane("Privacy_ScreenCapture") }
    func openMicrophoneSettings() { openPrivacyPane("Privacy_Microphone") }

    /// macOS 13 replaced the `com.apple.preference.security` pane identifier. The
    /// old URL still opens System Settings but silently lands on General, so the
    /// links looked broken rather than failing.
    private func openPrivacyPane(_ anchor: String) {
        let identifier = "com.apple.settings.PrivacySecurity.extension"
        guard let url = URL(string: "x-apple.systempreferences:\(identifier)?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleRefresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.refresh()
        }
    }
}

