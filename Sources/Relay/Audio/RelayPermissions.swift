@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation

/// Authorization only: checking access never starts an engine, captures a
/// screen/audio buffer, or presents a permission request. The visible onboarding
/// flow owns calls to the explicit request and System Settings actions.
@MainActor
@Observable
final class RelayPermissions {
    enum AccessStatus: Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    enum Permission: Equatable, Sendable {
        case microphone
        case systemAudio
    }

    /// Injection keeps permission tests away from the user's actual TCC grants.
    /// The production System-audio preflight deliberately matches Relay's
    /// ScreenCaptureKit path; it is not an inference from a saved preference.
    struct Operations {
        var microphoneStatus: @MainActor () -> AccessStatus
        var systemAudioGranted: @MainActor () -> Bool
        var requestMicrophone: @MainActor () async -> Bool
        var requestSystemAudio: @MainActor () -> Bool
        var openSettings: @MainActor (Permission) -> Bool

        static var live: Operations {
            Operations(microphoneStatus: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined: .notDetermined
                case .authorized: .authorized
                case .denied: .denied
                case .restricted: .restricted
                @unknown default: .restricted
                }
            }, systemAudioGranted: {
                CGPreflightScreenCaptureAccess()
            }, requestMicrophone: {
                await AVCaptureDevice.requestAccess(for: .audio)
            }, requestSystemAudio: {
                CGRequestScreenCaptureAccess()
            }, openSettings: { permission in
                let pane = permission == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
                    return false
                }
                return NSWorkspace.shared.open(url)
            })
        }
    }

    private(set) var microphoneStatus: AccessStatus = .notDetermined
    private(set) var hasSystemAudioAccess = false
    private(set) var requesting: Permission?
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private var allowsAutomaticRequest = true
    #if DEBUG
    @ObservationIgnored private var testingAccessSetter: ((AccessStatus, Bool) -> Void)?
    #endif

    var microphoneGranted: Bool { microphoneStatus == .authorized }
    var systemAudioGranted: Bool { hasSystemAudioAccess }
    var isReady: Bool { microphoneGranted && hasSystemAudioAccess }
    var canCreateConversation: Bool { isReady }
    var isRequesting: Bool { requesting != nil }

    init() {
        operations = .live
        refresh()
    }

    init(operations: Operations) {
        self.operations = operations
        refresh()
    }

    /// Re-read native grants on activation and while onboarding is visible.
    /// macOS may require a relaunch before a newly granted ScreenCaptureKit
    /// permission becomes visible to this process; never treat a request's
    /// return value or a previous onboarding completion as authorization.
    func refresh() {
        microphoneStatus = operations.microphoneStatus()
        hasSystemAudioAccess = operations.systemAudioGranted()
    }

    /// Onboarding asks in a fixed order and opens at most one relevant Privacy
    /// pane afterward. Repeated automatic view/activation refreshes never call
    /// this method and therefore cannot stack native permission requests.
    @discardableResult
    func requestRequiredAccess() async -> Bool {
        guard !Task.isCancelled else { return isReady }
        guard !isRequesting else { return isReady }
        refresh()
        guard allowsAutomaticRequest else { return isReady }
        guard !isReady else { return true }
        defer { requesting = nil }
        if microphoneStatus == .notDetermined {
            requesting = .microphone
            _ = await operations.requestMicrophone()
            refresh()
        }
        guard !Task.isCancelled else { return isReady }
        if !hasSystemAudioAccess {
            requesting = .systemAudio
            _ = operations.requestSystemAudio()
            refresh()
        }
        guard !Task.isCancelled else { return isReady }
        if !microphoneGranted { _ = openMicrophoneSettings() }
        else if !hasSystemAudioAccess { _ = openSystemAudioSettings() }
        refresh()
        return isReady
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        guard !Task.isCancelled else { return microphoneGranted }
        guard !isRequesting else { return microphoneGranted }
        refresh()
        guard !microphoneGranted else { return true }
        requesting = .microphone
        defer { requesting = nil }
        if microphoneStatus == .notDetermined {
            _ = await operations.requestMicrophone()
            refresh()
        }
        guard !Task.isCancelled else { return microphoneGranted }
        if !microphoneGranted { _ = openMicrophoneSettings() }
        refresh()
        return microphoneGranted
    }

    @discardableResult
    func requestSystemAudio() async -> Bool {
        guard !Task.isCancelled else { return hasSystemAudioAccess }
        guard !isRequesting else { return hasSystemAudioAccess }
        refresh()
        guard !hasSystemAudioAccess else { return true }
        requesting = .systemAudio
        defer { requesting = nil }
        _ = operations.requestSystemAudio()
        refresh()
        guard !Task.isCancelled else { return hasSystemAudioAccess }
        if !hasSystemAudioAccess { _ = openSystemAudioSettings() }
        refresh()
        return hasSystemAudioAccess
    }

    @discardableResult
    func openMicrophoneSettings() -> Bool { operations.openSettings(.microphone) }

    @discardableResult
    func openSystemAudioSettings() -> Bool { operations.openSettings(.systemAudio) }

    #if DEBUG
    /// Explicit fictional grants for unit/UI tests. No native prompt, audio,
    /// screen query, or System Settings action can escape this instance.
    static func testing(microphone: AccessStatus = .authorized, systemAudio: Bool = true,
                        grantsOnRequest: Bool = true) -> RelayPermissions {
        final class Fixture {
            var microphone: AccessStatus
            var systemAudio: Bool
            init(microphone: AccessStatus, systemAudio: Bool) {
                self.microphone = microphone
                self.systemAudio = systemAudio
            }
        }
        let fixture = Fixture(microphone: microphone, systemAudio: systemAudio)
        let permissions = RelayPermissions(operations: Operations(microphoneStatus: { fixture.microphone },
            systemAudioGranted: { fixture.systemAudio }, requestMicrophone: {
                if grantsOnRequest, fixture.microphone != .restricted { fixture.microphone = .authorized }
                return fixture.microphone == .authorized
            }, requestSystemAudio: {
                if grantsOnRequest { fixture.systemAudio = true }
                return fixture.systemAudio
            }, openSettings: { permission in
                if grantsOnRequest {
                    if permission == .microphone, fixture.microphone != .restricted {
                        fixture.microphone = .authorized
                    } else if permission == .systemAudio { fixture.systemAudio = true }
                }
                return true
            }))
        // The onboarding's initial task must not instantly erase a missing-
        // permission fixture. Explicit Allow/Open Settings actions still model
        // a user completing the grant, with no access to the real system.
        permissions.allowsAutomaticRequest = false
        permissions.testingAccessSetter = { microphone, systemAudio in
            fixture.microphone = microphone
            fixture.systemAudio = systemAudio
        }
        return permissions
    }

    func setTestingAccess(microphone: AccessStatus, systemAudio: Bool) {
        guard let testingAccessSetter else { return }
        testingAccessSetter(microphone, systemAudio)
        refresh()
    }
    #endif
}
