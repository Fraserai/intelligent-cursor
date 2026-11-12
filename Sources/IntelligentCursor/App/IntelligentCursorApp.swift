import AppKit
import SwiftUI

@main
struct IntelligentCursorApp: App {
    @NSApplicationDelegateAdaptor(IntelligentCursorAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            IntelligentCursorMenu(coordinator: appDelegate.coordinator)
        } label: {
            Image(systemName: menuSymbol)
                .accessibilityLabel("The Intelligent Cursor")
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuSymbol: String {
        switch appDelegate.coordinator.phase {
        case .idle, .armed: "scope"
        case .acquiring, .invoking, .responding: "sparkles"
        case .prompting: "text.bubble"
        case .failed: "exclamationmark.circle"
        }
    }
}

@MainActor
final class IntelligentCursorAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = ApplicationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}

private struct IntelligentCursorMenu: View {
    @ObservedObject var coordinator: ApplicationCoordinator
    @ObservedObject private var permissions: PermissionManager

    init(coordinator: ApplicationCoordinator) {
        self.coordinator = coordinator
        permissions = coordinator.permissionManager
    }

    var body: some View {
        Button("Activate at Cursor", systemImage: "scope") {
            coordinator.activateAtCursor()
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Text(coordinator.statusMessage)

        Divider()

        Menu("Default Intelligence") {
            ForEach(ModelProfileID.allCases) { profile in
                Button {
                    coordinator.selectedProfile = profile
                } label: {
                    if coordinator.selectedProfile == profile {
                        Label(profile.displayName(effort: coordinator.reasoningEffort), systemImage: "checkmark")
                    } else {
                        Text(profile.displayName(effort: coordinator.reasoningEffort))
                    }
                }
            }
        }

        if !coordinator.recentConversations.isEmpty {
            Menu("Recent Conversations") {
                ForEach(coordinator.recentConversations) { conversation in
                    Button(conversation.title) { coordinator.reopen(conversation) }
                }
            }
        }

        Menu("Gaming Mouse Button") {
            mouseButton("Middle button", value: 2)
            mouseButton("Side button 1", value: 3)
            mouseButton("Side button 2", value: 4)
            Divider()
            Text("F18 always works as a driver mapping")
        }

        Divider()

        Menu("Permissions") {
            permissionRow("Input Monitoring", permissions.inputMonitoring)
            permissionRow("Accessibility", permissions.accessibility)
            permissionRow("Screen Recording", permissions.screenRecording)
            permissionRow("Microphone", permissions.microphone)
            permissionRow("Speech Recognition", permissions.speechRecognition)

            Divider()

            Button("Request Context Access") { coordinator.requestContextPermissions() }
            Button("Open Accessibility Settings") { permissions.openAccessibilitySettings() }
            Button("Open Input Monitoring Settings") { permissions.openInputMonitoringSettings() }
            Button("Open Screen Recording Settings") { permissions.openScreenRecordingSettings() }
            Button("Refresh Status") { permissions.refresh() }
        }

        Divider()

        Button("Dismiss Current Interaction") { coordinator.dismissInteraction() }
            .disabled(coordinator.phase == .idle)
        Button("Quit The Intelligent Cursor") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func mouseButton(_ title: String, value: Int64) -> some View {
        Button {
            coordinator.setMouseButton(value)
        } label: {
            if coordinator.activationMouseButton == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func permissionRow(_ title: String, _ state: PermissionState) -> some View {
        Label("\(title): \(state.rawValue)", systemImage: state.symbol)
    }
}
