import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneFormatSignature: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let formatID: UInt32
    let formatFlags: UInt32
    let bytesPerFrame: UInt32
    let interleaved: Bool

    init(format: AVAudioFormat) {
        let description = format.streamDescription.pointee
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        formatID = description.mFormatID
        formatFlags = description.mFormatFlags
        bytesPerFrame = description.mBytesPerFrame
        interleaved = format.isInterleaved
    }

    init(sampleRate: Double, channelCount: UInt32, formatID: UInt32 = kAudioFormatLinearPCM,
         formatFlags: UInt32 = 1, bytesPerFrame: UInt32 = 4, interleaved: Bool = false) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerFrame = bytesPerFrame
        self.interleaved = interleaved
    }
}

struct MicrophoneDeviceRoute: Equatable, Sendable {
    let inputDeviceID: UInt32
    let outputDeviceID: UInt32
    var hasInput: Bool { inputDeviceID != kAudioObjectUnknown }

    static func current(includesSpeakerReference: Bool) -> Self {
        Self(inputDeviceID: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
             outputDeviceID: includesSpeakerReference ? defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) : 0)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return result == noErr ? device : kAudioObjectUnknown
    }
}

struct MicrophoneConfigurationSnapshot: Equatable, Sendable {
    let inputDeviceID: UInt32
    let outputDeviceID: UInt32
    let format: MicrophoneFormatSignature
    let isRunning: Bool
    let voiceProcessingEnabled: Bool
    let boundInputDeviceID: UInt32
    let boundOutputDeviceID: UInt32

    init(inputDeviceID: UInt32, outputDeviceID: UInt32, format: MicrophoneFormatSignature,
         isRunning: Bool, voiceProcessingEnabled: Bool,
         boundInputDeviceID: UInt32 = 0, boundOutputDeviceID: UInt32 = 0) {
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        self.format = format
        self.isRunning = isRunning
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.boundInputDeviceID = boundInputDeviceID
        self.boundOutputDeviceID = boundOutputDeviceID
    }

    @MainActor
    static func read(engine: AVAudioEngine, includesSpeakerReference: Bool) -> Self {
        let route = MicrophoneDeviceRoute.current(includesSpeakerReference: includesSpeakerReference)
        return Self(inputDeviceID: route.inputDeviceID, outputDeviceID: route.outputDeviceID,
                    format: MicrophoneFormatSignature(format: engine.inputNode.outputFormat(forBus: 0)),
                    isRunning: engine.isRunning,
                    voiceProcessingEnabled: engine.inputNode.isVoiceProcessingEnabled,
                    boundInputDeviceID: engine.inputNode.auAudioUnit.deviceID,
                    boundOutputDeviceID: includesSpeakerReference ? engine.outputNode.auAudioUnit.deviceID : 0)
    }
}

enum MicrophoneConfigurationDecision: Equatable, Sendable {
    case unchanged
    case restart
    case reconnect
    case waitForDevice
}

/// A notification alone does not prove the microphone changed. Device choices reconnect the
/// hardware while preserving the continuing recognition pipeline and system-audio stream.
enum MicrophoneConfigurationPolicy {
    static func initialDecision(route: MicrophoneDeviceRoute,
                                format: MicrophoneFormatSignature,
                                requiresVoiceProcessing: Bool,
                                current: MicrophoneConfigurationSnapshot) -> MicrophoneConfigurationDecision {
        guard current.inputDeviceID != kAudioObjectUnknown else { return .waitForDevice }
        guard current.inputDeviceID == route.inputDeviceID,
              current.outputDeviceID == route.outputDeviceID,
              current.format == format,
              current.voiceProcessingEnabled == requiresVoiceProcessing else { return .reconnect }
        return current.isRunning ? .unchanged : .restart
    }

    static func decision(installed: MicrophoneConfigurationSnapshot,
                         current: MicrophoneConfigurationSnapshot,
                         requiresVoiceProcessing: Bool) -> MicrophoneConfigurationDecision {
        guard current.inputDeviceID != kAudioObjectUnknown else { return .waitForDevice }
        let sameRoute = current.inputDeviceID == installed.inputDeviceID
            && current.outputDeviceID == installed.outputDeviceID
            && current.boundInputDeviceID == installed.boundInputDeviceID
            && current.boundOutputDeviceID == installed.boundOutputDeviceID
        if sameRoute, current.format == installed.format,
           current.voiceProcessingEnabled == requiresVoiceProcessing {
            return current.isRunning ? .unchanged : .restart
        }
        return .reconnect
    }
}

@MainActor
protocol MicrophoneRestartTarget: AnyObject {
    var isRunning: Bool { get }
    func start() throws
}

enum MicrophoneRestartError: Error, Equatable {
    case remainedStopped
}

/// A configuration notification stops the engine but retains its nodes and graph.
/// Restart that same graph before considering a fresh voice-processing aggregate.
@MainActor
enum MicrophoneEngineRestart {
    static func perform(on target: any MicrophoneRestartTarget,
                        shouldContinue: @escaping @MainActor () -> Bool,
                        sleep: @escaping @MainActor (Duration) async throws -> Void = {
                            try await Task.sleep(for: $0)
                        }) async throws {
        for attempt in 0..<3 {
            if attempt > 0 { try await sleep(.milliseconds(attempt == 1 ? 160 : 500)) }
            try Task.checkCancellation()
            guard shouldContinue() else { throw CancellationError() }
            if target.isRunning { return }
            do {
                // AVAudioEngine.start prepares retained resources itself when needed.
                try target.start()
                guard target.isRunning else { throw MicrophoneRestartError.remainedStopped }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 2 { throw error }
            }
        }
    }
}
