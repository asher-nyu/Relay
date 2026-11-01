import AppKit
import SwiftUI

struct RelayPermissionOnboarding: View {
    @Bindable var permissions: RelayPermissions

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 480
            let short = geometry.size.height < 345
            ScrollView(.vertical) {
                permissionContent(compact: compact, short: short)
                    .frame(maxWidth: 550)
                    .padding(.horizontal, 36)
                    .padding(.vertical, short ? 8 : compact ? 12 : 36)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.never)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("relay.permissions.onboarding")
        .task {
            await permissions.requestRequiredAccess()
            while !Task.isCancelled && !permissions.isReady {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                permissions.refresh()
            }
        }
    }

    private func permissionContent(compact: Bool, short: Bool) -> some View {
        VStack(spacing: 0) {
            if !short {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: compact ? 54 : 72, height: compact ? 54 : 72)
                    .accessibilityHidden(true)
                    .padding(.bottom, compact ? 10 : 20)
            }

            Text("Set up Relay")
                .font(.system(size: short ? 23 : 27, weight: .semibold))
                .tracking(-0.5)
            Text("Allow microphone and system audio access to start a conversation.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, short ? 3 : compact ? 6 : 10)

            VStack(spacing: 0) {
                permissionRow("Microphone", symbol: "mic", detail: "Transcribe voices around you.",
                              allowed: permissions.microphoneGranted,
                              buttonTitle: permissions.microphoneStatus == .notDetermined ? "Allow Microphone" : "Open System Settings",
                              identifier: "relay.permissions.microphone", compact: compact, short: short) {
                    Task { await permissions.requestMicrophone() }
                }
                Divider().padding(.leading, 58)
                permissionRow("System Audio", symbol: "speaker.wave.2", detail: "Transcribe playback and reduce speaker echo.",
                              allowed: permissions.hasSystemAudioAccess,
                              buttonTitle: "Allow System Audio",
                              identifier: "relay.permissions.systemAudio", compact: compact, short: short) {
                    Task { await permissions.requestSystemAudio() }
                }
            }
            .padding(.horizontal, 18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, short ? 8 : compact ? 14 : 28)

            Text("macOS lists system audio access under Screen & System Audio Recording. Relay uses audio only.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, short ? 6 : compact ? 10 : 18)
            Text("Speech is processed on this Mac. Audio isn’t saved.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, short ? 6 : compact ? 12 : 20)
        }
    }

    private func permissionRow(_ title: String, symbol: String, detail: String,
                               allowed: Bool, buttonTitle: String, identifier: String,
                               compact: Bool, short: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action)
                    .disabled(permissions.isRequesting)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(.vertical, short ? 4 : compact ? 8 : 18)
    }
}
