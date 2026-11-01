import AVFoundation

@MainActor
protocol VoiceProcessingConfigurationTarget: AnyObject {
    var isEngineRunning: Bool { get }
    var isVoiceProcessingEnabled: Bool { get }
    func enableVoiceProcessing() throws
    func minimizeOtherAudioDucking()
}

/// Voice processing is configured before the microphone's format is queried or its tap is installed.
/// Keeping this hardware boundary explicit also allows failure behavior to be verified without capture.
@MainActor
enum SpeakerEchoReduction {
    nonisolated static func isRequested(sources: Set<TranscriptSource>, preference: Bool) -> Bool {
        preference && sources.contains(.systemAudio) && sources.contains(.microphone)
    }

    static func configure(_ target: any VoiceProcessingConfigurationTarget, requested: Bool) throws {
        guard requested else { return }
        guard !target.isEngineRunning else { throw AudioTranscriptionError.speakerEchoReductionUnavailable }
        do { try target.enableVoiceProcessing() }
        catch { throw AudioTranscriptionError.speakerEchoReductionUnavailable }
        guard target.isVoiceProcessingEnabled else { throw AudioTranscriptionError.speakerEchoReductionUnavailable }
        target.minimizeOtherAudioDucking()
    }
}

@MainActor
final class VoiceProcessingEngineConfiguration: VoiceProcessingConfigurationTarget {
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine) { self.engine = engine }
    var isEngineRunning: Bool { engine.isRunning }
    var isVoiceProcessingEnabled: Bool { engine.inputNode.isVoiceProcessingEnabled }

    func enableVoiceProcessing() throws {
        do { try engine.inputNode.setVoiceProcessingEnabled(true) }
        catch {
            AudioCaptureDiagnostics.connectionStage("native setVoiceProcessingEnabled", error: error)
            throw error
        }
    }

    func minimizeOtherAudioDucking() {
        // macOS exposes Default/Min/Mid/Max, with no documented fully-off setting.
        // Disable activity-based ducking and choose the least intrusive supported level.
        var configuration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
        configuration.enableAdvancedDucking = false
        configuration.duckingLevel = .min
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = configuration
    }
}
