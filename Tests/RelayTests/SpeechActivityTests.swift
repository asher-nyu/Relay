import Foundation
import RelayAEC
import Testing

/// These fixtures exercise the bundled classifier without audio devices or
/// speech recognition. Decisions are timing metadata; input PCM is untouched.
@Suite("Local speech activity metadata")
struct SpeechActivityTests {
    @Test("All supported modes classify sustained digital silence as non-speech")
    func silenceInEveryMode() throws {
        let silence = [Float](repeating: 0, count: 160)
        let modes: [Int32] = [0, 1, 2, 3]
        for mode in modes {
            let detector = try #require(relay_vad_create(mode))
            defer { relay_vad_destroy(detector) }
            for _ in 0..<200 { #expect(process(silence, using: detector) == 0) }
        }
    }

    @Test("A voiced harmonic onset is detected after two seconds of silence")
    func voicedOnsetAfterSilence() throws {
        let detector = try #require(relay_vad_create(2))
        defer { relay_vad_destroy(detector) }
        for _ in 0..<200 {
            #expect(process([Float](repeating: 0, count: 160), using: detector) == 0)
        }
        let firstFrame = voicedFrame(0)
        let original = firstFrame
        #expect(process(firstFrame, using: detector) == 1)
        #expect(firstFrame == original, "Activity classification never filters or rewrites its input.")
        let followingDecisions = (1..<20).map { process(voicedFrame($0), using: detector) }
        #expect(followingDecisions.allSatisfy { $0 == 1 })
    }

    @Test("Reset restores a fresh classifier while preserving the requested mode")
    func resetRestoresFreshState() throws {
        let detector = try #require(relay_vad_create(3))
        let fresh = try #require(relay_vad_create(3))
        defer { relay_vad_destroy(detector); relay_vad_destroy(fresh) }
        for index in 0..<100 { _ = process(voicedFrame(index), using: detector) }
        #expect(relay_vad_reset(detector) == 0)
        let silence = [Float](repeating: 0, count: 160)
        for _ in 0..<20 {
            #expect(process(silence, using: detector) == process(silence, using: fresh))
        }
        for index in 0..<100 {
            #expect(process(voicedFrame(index), using: detector) == process(voicedFrame(index), using: fresh))
        }
    }

    @Test("Source handles have independent histories and resetting one does not affect the other")
    func independentSourceHistories() throws {
        let system = try #require(relay_vad_create(2))
        let microphone = try #require(relay_vad_create(2))
        defer { relay_vad_destroy(system); relay_vad_destroy(microphone) }
        let silence = [Float](repeating: 0, count: 160)
        for index in 0..<30 {
            #expect(process(voicedFrame(index), using: system) == 1)
            #expect(process(silence, using: microphone) == 0)
        }
        #expect(relay_vad_reset(system) == 0)
        #expect(process(silence, using: system) == 0)
        #expect(process(voicedFrame(0), using: microphone) == 1)
    }

    @Test("Unsupported modes, null handles, and non-10-ms input fail explicitly")
    func invalidArguments() throws {
        #expect(relay_vad_create(-1) == nil)
        #expect(relay_vad_create(4) == nil)
        #expect(relay_vad_reset(nil) < 0)
        let detector = try #require(relay_vad_create(2))
        defer { relay_vad_destroy(detector) }
        let samples = voicedFrame(0)
        #expect(samples.withUnsafeBufferPointer { relay_vad_process(nil, $0.baseAddress, $0.count) } < 0)
        #expect(relay_vad_process(detector, nil, 160) < 0)
        for count in [0, 159, 161, 320] {
            #expect(samples.withUnsafeBufferPointer { relay_vad_process(detector, $0.baseAddress, count) } < 0)
        }
        relay_vad_destroy(nil)
    }

    @Test("Nonfinite input is rejected without changing the classifier history")
    func invalidFrameDoesNotChangeHistory() throws {
        let detector = try #require(relay_vad_create(2))
        let fresh = try #require(relay_vad_create(2))
        defer { relay_vad_destroy(detector); relay_vad_destroy(fresh) }
        for invalid in [Float.nan, Float.infinity, -Float.infinity] {
            var frame = voicedFrame(0)
            frame[159] = invalid
            #expect(process(frame, using: detector) < 0)
        }
        for index in 0..<30 {
            #expect(process(voicedFrame(index), using: detector) == process(voicedFrame(index), using: fresh))
        }
    }

    @Test("Out-of-range finite samples saturate locally without wrapping their sign")
    func saturatedSamplesMatchClampedInput() throws {
        let detector = try #require(relay_vad_create(2))
        let clamped = try #require(relay_vad_create(2))
        defer { relay_vad_destroy(detector); relay_vad_destroy(clamped) }
        for index in 0..<40 {
            let amplified = voicedFrame(index).map { $0 * 20 }
            let bounded = amplified.map { min(1, max(-1, $0)) }
            #expect(process(amplified, using: detector) == process(bounded, using: clamped))
        }
    }

    private func process(_ samples: [Float], using detector: OpaquePointer) -> Int32 {
        samples.withUnsafeBufferPointer { relay_vad_process(detector, $0.baseAddress, $0.count) }
    }

    private func voicedFrame(_ frame: Int) -> [Float] {
        (0..<160).map { offset in
            let time = Double(frame * 160 + offset) / 16_000
            let fundamental = 0.12 * sin(2 * Double.pi * 137 * time)
            let second = 0.06 * sin(2 * Double.pi * 274 * time)
            let third = 0.04 * sin(2 * Double.pi * 411 * time)
            return Float(fundamental + second + third)
        }
    }
}
