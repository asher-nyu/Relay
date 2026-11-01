@preconcurrency import AVFoundation
import Foundation

/// Native voice processing needs a rendered downlink as well as microphone uplink.
/// Supply an engine-owned, silent output clock; never monitor the microphone or
/// replay system capture through the speakers.
enum VoiceProcessingOutput {
    static func voiceFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw AudioTranscriptionError.audioFormat
        }
        return format
    }

    @MainActor
    static func attach(to engine: AVAudioEngine, output: AVAudioOutputNode, format: AVAudioFormat) throws {
        let silence = AVAudioSourceNode(format: format, renderBlock: makeSilentRenderBlock())
        engine.attach(silence)
        let mixer = engine.mainMixerNode
        if #available(macOS 27, *) {
            do {
                AudioCaptureDiagnostics.connectionStage("connect silence to mixer", details: AudioCaptureDiagnostics.describe(format))
                try engine.connectNode(silence, to: mixer, format: format)
            } catch {
                AudioCaptureDiagnostics.connectionStage("connect silence to mixer", error: error)
                throw error
            }
            do {
                AudioCaptureDiagnostics.connectionStage("connect mixer to voice output", details: AudioCaptureDiagnostics.describe(format))
                try engine.connectNode(mixer, to: output, format: format)
            } catch {
                AudioCaptureDiagnostics.connectionStage("connect mixer to voice output", error: error)
                throw error
            }
        } else {
            engine.connect(silence, to: mixer, format: format)
            engine.connect(mixer, to: output, format: format)
        }
    }

    // The hardware render thread must never inherit a caller's MainActor isolation.
    nonisolated static func makeSilentRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { @Sendable isSilence, _, _, outputData in
            isSilence.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
}
