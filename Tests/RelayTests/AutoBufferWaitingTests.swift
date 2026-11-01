import AVFoundation
import Foundation
import Testing
@testable import Relay

@Suite("Auto language waiting")
@MainActor
struct AutoBufferWaitingTests {
    @Test("More than two minutes of silence can wait for the first spoken audio")
    func quietRoom() async throws {
        var failures: [String] = []
        var detections: [[Float]] = []
        let bridge = try BufferedAudioPipeline(source: .microphone,
            onSamples: { detections.append($0) }, onLevel: { _ in },
            onFailure: { failures.append($0.localizedDescription) })
        let quiet = try buffer(amplitude: 0)
        for second in 0..<130 { bridge.accept(quiet, hostTime: 1_000 + Double(second)) }
        #expect(await bridge.detectionSamples().isEmpty)
        let voice = try buffer(amplitude: 0.1)
        for second in 130..<134 { bridge.accept(voice, hostTime: 1_000 + Double(second)) }
        let detected = await bridge.detectionSamples()
        await Task.yield()
        #expect(failures.isEmpty)
        #expect(detected.count == 4 * 16_000)
        #expect(detections.count == 1)
        await bridge.cancel()
    }

    @Test("Once speech starts, stalled model preparation remains bounded")
    func boundedPreparation() async throws {
        var failures: [String] = []
        let bridge = try BufferedAudioPipeline(source: .microphone,
            onSamples: { _ in }, onLevel: { _ in },
            onFailure: { failures.append($0.localizedDescription) })
        let voice = try buffer(amplitude: 0.1)
        for second in 0..<122 { bridge.accept(voice, hostTime: 1_000 + Double(second)) }
        _ = await bridge.detectionSamples()
        await Task.yield()
        #expect(failures == [AudioTranscriptionError.languagePreparationTooLong.localizedDescription])
        await bridge.cancel()
    }

    private func buffer(amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = amplitude }
        return buffer
    }
}
