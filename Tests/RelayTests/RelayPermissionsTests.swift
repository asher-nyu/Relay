import Foundation
import Testing
@testable import Relay

@Suite("Required audio permission onboarding", .serialized)
@MainActor
struct RelayPermissionsTests {
    @Test("Readiness requires both fresh grants", arguments:
        [RelayPermissions.AccessStatus.notDetermined, .authorized, .denied, .restricted], [false, true])
    func readiness(microphone: RelayPermissions.AccessStatus, systemAudio: Bool) {
        let fixture = PermissionFixture(microphone: microphone, systemAudio: systemAudio)
        let permissions = fixture.makePermissions()
        let ready = microphone == .authorized && systemAudio
        #expect(permissions.isReady == ready)
        #expect(permissions.canCreateConversation == ready)
        #expect(permissions.microphoneGranted == (microphone == .authorized))
        #expect(permissions.systemAudioGranted == systemAudio)
        #expect(!permissions.isRequesting && fixture.actions.isEmpty)
    }

    @Test("The visible onboarding requests microphone then System audio exactly once")
    func sequentialRequests() async {
        let fixture = PermissionFixture()
        fixture.microphoneGrant = true
        fixture.systemAudioGrant = true
        let permissions = fixture.makePermissions()
        #expect(await permissions.requestRequiredAccess())
        #expect(fixture.actions == [.requestMicrophone, .requestSystemAudio])
        #expect(permissions.isReady && permissions.requesting == nil)
        #expect(await permissions.requestRequiredAccess())
        #expect(fixture.actions == [.requestMicrophone, .requestSystemAudio])
    }

    @Test("A denied required flow opens one relevant Privacy pane", arguments:
        [RelayPermissions.Permission.microphone, .systemAudio])
    func denialOpensOnePane(missing: RelayPermissions.Permission) async {
        let fixture = PermissionFixture(microphone: missing == .microphone ? .notDetermined : .authorized,
                                        systemAudio: false)
        let permissions = fixture.makePermissions()
        #expect(!(await permissions.requestRequiredAccess()))
        let settings = fixture.actions.filter {
            if case .openSettings = $0 { return true }
            return false
        }
        #expect(settings == [.openSettings(missing)])
        #expect(permissions.requesting == nil && !permissions.isReady)
    }

    @Test("Activation refresh observes revocation without requests or Settings")
    func refreshRevokedGrant() {
        let fixture = PermissionFixture(microphone: .authorized, systemAudio: true)
        let permissions = fixture.makePermissions()
        #expect(permissions.isReady)
        fixture.microphone = .denied
        fixture.systemAudio = false
        permissions.refresh()
        #expect(permissions.microphoneStatus == .denied && !permissions.hasSystemAudioAccess)
        #expect(!permissions.canCreateConversation)
        fixture.microphone = .authorized
        fixture.systemAudio = true
        permissions.refresh()
        #expect(permissions.isReady && fixture.actions.isEmpty)
    }

    @Test("An already canceled onboarding action cannot request access", arguments: [0, 1, 2])
    func alreadyCanceled(action: Int) async {
        let fixture = PermissionFixture()
        let permissions = fixture.makePermissions()
        let task = Task { @MainActor in
            switch action {
            case 0: await permissions.requestRequiredAccess()
            case 1: await permissions.requestMicrophone()
            default: await permissions.requestSystemAudio()
            }
        }
        task.cancel()
        #expect(!(await task.value))
        #expect(fixture.actions.isEmpty && permissions.requesting == nil)
    }

    @Test("Canceling a pending native microphone request cannot launch another prompt or Settings", arguments: [false, true])
    func cancellationAfterMicrophonePrompt(requiredFlow: Bool) async throws {
        let fixture = PermissionFixture()
        fixture.suspendMicrophoneRequest = true
        let permissions = fixture.makePermissions()
        let task = Task { @MainActor in
            if requiredFlow { await permissions.requestRequiredAccess() }
            else { await permissions.requestMicrophone() }
        }
        try await waitForMicrophoneRequest(fixture)
        #expect(permissions.isRequesting && permissions.requesting == .microphone)
        task.cancel()
        fixture.completeMicrophoneRequest(granted: false)
        #expect(!(await task.value))
        #expect(fixture.actions == [.requestMicrophone])
        #expect(permissions.microphoneStatus == .denied && permissions.requesting == nil)
    }

    @Test("A second action cannot stack native requests during a pending prompt")
    func requestsDoNotOverlap() async throws {
        let fixture = PermissionFixture()
        fixture.suspendMicrophoneRequest = true
        fixture.systemAudioGrant = true
        let permissions = fixture.makePermissions()
        let task = Task { @MainActor in await permissions.requestRequiredAccess() }
        try await waitForMicrophoneRequest(fixture)
        #expect(!(await permissions.requestSystemAudio()))
        #expect(fixture.actions == [.requestMicrophone])
        fixture.completeMicrophoneRequest(granted: true)
        #expect(await task.value)
        #expect(fixture.actions == [.requestMicrophone, .requestSystemAudio])
    }

    @Test("Restricted microphone access is never represented as authorized")
    func restrictedAccess() async {
        let fixture = PermissionFixture(microphone: .restricted, systemAudio: true)
        let permissions = fixture.makePermissions()
        #expect(!(await permissions.requestRequiredAccess()))
        #expect(fixture.actions == [.openSettings(.microphone)])
        #expect(permissions.microphoneStatus == .restricted && !permissions.isReady)
    }

    @Test("Successful request return values cannot replace an actual grant")
    func requestReturnDoesNotAuthorize() async {
        let fixture = PermissionFixture()
        fixture.microphoneReturnOverride = true
        fixture.systemAudioReturnOverride = true
        let permissions = fixture.makePermissions()
        #expect(!(await permissions.requestRequiredAccess()))
        #expect(permissions.microphoneStatus == .denied && !permissions.hasSystemAudioAccess)
        #expect(!permissions.canCreateConversation)
        #expect(fixture.actions == [.requestMicrophone, .requestSystemAudio, .openSettings(.microphone)])
    }

    #if DEBUG
    @Test("UI fixtures hold automatic onboarding and grant only explicit individual actions")
    func fictionalUIAccess() async {
        let permissions = RelayPermissions.testing(microphone: .notDetermined, systemAudio: false)
        #expect(!(await permissions.requestRequiredAccess()))
        #expect(permissions.microphoneStatus == .notDetermined && !permissions.hasSystemAudioAccess)
        #expect(await permissions.requestMicrophone())
        #expect(!permissions.isReady)
        #expect(await permissions.requestSystemAudio())
        #expect(permissions.isReady)
        permissions.setTestingAccess(microphone: .restricted, systemAudio: false)
        #expect(!permissions.isReady)
        #expect(!(await permissions.requestMicrophone()))
        #expect(permissions.microphoneStatus == .restricted)
    }
    #endif

    private func waitForMicrophoneRequest(_ fixture: PermissionFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.microphoneContinuation == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("The injected microphone request did not begin.")
                throw PermissionFixtureError.timedOut
            }
            await Task.yield()
        }
    }
}

private enum PermissionFixtureError: Error { case timedOut }

@MainActor
private final class PermissionFixture {
    enum Action: Equatable {
        case requestMicrophone
        case requestSystemAudio
        case openSettings(RelayPermissions.Permission)
    }
    var microphone: RelayPermissions.AccessStatus
    var systemAudio: Bool
    var microphoneGrant = false
    var systemAudioGrant = false
    var microphoneReturnOverride: Bool?
    var systemAudioReturnOverride: Bool?
    var suspendMicrophoneRequest = false
    var microphoneContinuation: CheckedContinuation<Bool, Never>?
    var actions: [Action] = []

    init(microphone: RelayPermissions.AccessStatus = .notDetermined, systemAudio: Bool = false) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    func makePermissions() -> RelayPermissions {
        RelayPermissions(operations: .init(microphoneStatus: { self.microphone },
            systemAudioGranted: { self.systemAudio }, requestMicrophone: {
                self.actions.append(.requestMicrophone)
                let granted: Bool
                if self.suspendMicrophoneRequest {
                    granted = await withCheckedContinuation { self.microphoneContinuation = $0 }
                } else { granted = self.microphoneGrant }
                self.microphone = granted ? .authorized : .denied
                return self.microphoneReturnOverride ?? granted
            }, requestSystemAudio: {
                self.actions.append(.requestSystemAudio)
                self.systemAudio = self.systemAudioGrant
                return self.systemAudioReturnOverride ?? self.systemAudioGrant
            }, openSettings: { permission in
                self.actions.append(.openSettings(permission))
                return true
            }))
    }

    func completeMicrophoneRequest(granted: Bool) {
        let continuation = microphoneContinuation
        microphoneContinuation = nil
        continuation?.resume(returning: granted)
    }
}
