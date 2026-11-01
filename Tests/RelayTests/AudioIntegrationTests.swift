import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing
@testable import Relay

/// Opt in with RELAY_AUDIO_INTEGRATION=1. These checks may download speech models.
/// They use fictional synthesized audio files and never open a microphone or capture system sound.
@Suite("On-device audio integration", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_AUDIO_INTEGRATION"] == "1"),
       .enabled(if: SpeechTranscriber.isAvailable))
@MainActor
struct AudioIntegrationTests {
    @Test("Two source analyzers deliver final words before the session ends", .timeLimit(.minutes(2)))
    func twoSourceFinalDrain() async throws {
        let first = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        let second = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [first, second]) {
            try await installation.downloadAndInstall()
        }
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [first, second]))
        let results = IntegrationResults()
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let modules: [(TranscriptSource, SpeechTranscriber)] = [(.systemAudio, first), (.microphone, second)]
        var pipelines: [SpeechPipeline] = []
        do {
            for (source, transcriber) in modules {
                let pipeline = SpeechPipeline(source: source, transcriber: transcriber, format: format, origin: origin,
                    onUpdate: { results.apply($0) }, onLevel: { results.levels.append($0) },
                    onFailure: { results.errors.append($0.localizedDescription) })
                pipelines.append(pipeline)
            }
            try await AudioPipelineStartup.start(pipelines)
            for pipeline in pipelines {
                try feedFixture("English", into: pipeline, origin: origin)
            }
            for pipeline in pipelines { try await pipeline.finish() }
        } catch {
            for pipeline in pipelines { await pipeline.cancel() }
            throw error
        }
        #expect(results.errors.isEmpty)
        #expect(results.partials > 0)
        #expect(results.levels.contains { $0 > 0.1 })
        #expect(Set(results.transcript.segments.map(\.source)) == Set(TranscriptSource.allCases))
        #expect(results.transcript.segments.allSatisfy { $0.isFinal })
        for source in TranscriptSource.allCases {
            let text = results.transcript.segments.filter { $0.source == source }.map(\.text).joined(separator: " ")
            #expect(text.localizedCaseInsensitiveContains("Welcome to Relay"))
            #expect(text.localizedCaseInsensitiveContains("latest design"))
        }
    }

    @Test("A silent microphone analyzer never inherits speech from the concurrent system analyzer", .timeLimit(.minutes(2)))
    func silentMicrophoneDoesNotInheritSystemSpeech() async throws {
        let systemModule = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        let microphoneModule = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [systemModule, microphoneModule]) {
            try await installation.downloadAndInstall()
        }
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [systemModule, microphoneModule]))
        let systemResults = IntegrationResults()
        let microphoneResults = IntegrationResults()
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let system = SpeechPipeline(source: .systemAudio, transcriber: systemModule, format: format, origin: origin,
            onUpdate: { systemResults.apply($0) }, onLevel: { systemResults.levels.append($0) },
            onFailure: { systemResults.errors.append($0.localizedDescription) })
        let microphone = SpeechPipeline(source: .microphone, transcriber: microphoneModule, format: format, origin: origin,
            onUpdate: { microphoneResults.apply($0) }, onLevel: { microphoneResults.levels.append($0) },
            onFailure: { microphoneResults.errors.append($0.localizedDescription) })
        do {
            try await AudioPipelineStartup.start([system, microphone])
            let file = try AVAudioFile(forReading: fixtureURL("English"))
            var cursor: Int64 = 0
            while file.framePosition < file.length {
                let speech = try nextBuffer(file)
                let silence = try #require(AVAudioPCMBuffer(pcmFormat: speech.format, frameCapacity: speech.frameLength))
                silence.frameLength = speech.frameLength
                for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                let hostTime = origin + Double(cursor) / file.processingFormat.sampleRate
                // The two independent streams cover the same interval. Only
                // System receives speech; Microphone receives actual zero PCM.
                system.accept(speech, hostTime: hostTime)
                microphone.accept(silence, hostTime: hostTime)
                cursor += Int64(speech.frameLength)
            }
            #expect(cursor == file.length && cursor > 0)
            async let systemFinished: Void = system.finish()
            async let microphoneFinished: Void = microphone.finish()
            _ = try await (systemFinished, microphoneFinished)
        } catch {
            await system.cancel()
            await microphone.cancel()
            throw error
        }
        #expect(systemResults.errors.isEmpty && microphoneResults.errors.isEmpty)
        #expect(systemResults.transcript.text.localizedCaseInsensitiveContains("Welcome to Relay"))
        #expect(systemResults.transcript.text.localizedCaseInsensitiveContains("latest design"))
        #expect(systemResults.transcript.segments.allSatisfy { $0.source == .systemAudio && $0.isFinal })
        #expect(systemResults.levels.contains { $0 > 0.1 })
        #expect(!microphoneResults.levels.isEmpty)
        #expect(microphoneResults.levels.allSatisfy { $0 == 0 })
        #expect(microphoneResults.transcript.segments.isEmpty)
        #expect(!microphoneResults.updates.contains { update in
            update.text.contains { $0.isLetter || $0.isNumber }
        }, "Digital silence must produce no spoken words, including temporary hypotheses from the other analyzer.")
    }

    @Test("Auto identifies real English and Spanish waveforms and rejects silence", .timeLimit(.minutes(2)))
    func identifiesAudioLanguage() async throws {
        let detector = AutoLanguageDetector()
        try await detector.prepare()
        for (fixture, language) in [("English", "en"), ("Spanish", "es")] {
            let samples = try detectionSamples(fixture)
            let detected = try await detector.detect(samples: samples)
            #expect(detected == language)
            let opening = try await detector.detect(samples: Array(samples.prefix(16_000 * 5)))
            #expect(opening == language)
        }
        do {
            _ = try await detector.detect(samples: Array(repeating: 0, count: 16_000 * 5))
            Issue.record("Silence must not silently select English or another language.")
        } catch {
            #expect(error as? AudioTranscriptionError == .languageUncertain)
        }
    }

    @Test("A microphone reconnection preserves real elapsed time and drains final words", .timeLimit(.minutes(2)))
    func microphoneGap() async throws {
        let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installation.downloadAndInstall()
        }
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        let results = IntegrationResults()
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let pipeline = SpeechPipeline(source: .microphone, transcriber: module, format: format, origin: origin,
            onUpdate: { results.apply($0) }, onLevel: { _ in },
            onFailure: { results.errors.append($0.localizedDescription) })
        do {
            try await pipeline.start()
            let file = try AVAudioFile(forReading: fixtureURL("English"))
            var cursor: Int64 = 0
            while file.framePosition < file.length {
                let buffer = try nextBuffer(file)
                let position = Double(cursor) / file.processingFormat.sampleRate
                // Five real seconds without a microphone: no replacement silence or fabricated speech.
                pipeline.accept(buffer, hostTime: origin + position + (position > 6 ? 5 : 0))
                cursor += Int64(buffer.frameLength)
            }
            try await pipeline.finish()
        } catch {
            await pipeline.cancel()
            throw error
        }
        #expect(results.errors.isEmpty)
        #expect(results.transcript.segments.allSatisfy { $0.isFinal })
        #expect(results.transcript.text.localizedCaseInsensitiveContains("Welcome to Relay"))
        let finalPhrase = try #require(results.transcript.segments.last { $0.text.localizedCaseInsensitiveContains("latest design") })
        #expect(finalPhrase.timestamp > 12)
    }

    @Test("Twenty seconds of initial silence keep volatile and final spoken timestamps aligned", .timeLimit(.minutes(2)))
    func leadingSilenceTiming() async throws {
        for source in TranscriptSource.allCases {
            let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
            try await verifyLeadingSilenceTiming(module: module, source: source)
        }
    }

    private func verifyLeadingSilenceTiming(module: SpeechTranscriber, source: TranscriptSource) async throws {
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installation.downloadAndInstall()
        }
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        let results = IntegrationResults()
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let pipeline = SpeechPipeline(source: source, transcriber: module, format: format, origin: origin,
            onUpdate: { results.apply($0) }, onLevel: { _ in },
            onFailure: { results.errors.append($0.localizedDescription) },
            onTimingMetadata: { results.timingMetadata.append($0) })
        do {
            try await pipeline.start()
            let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)))
            silence.frameLength = silence.frameCapacity
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            for second in 0..<20 { pipeline.accept(silence, hostTime: origin + Double(second)) }
            try feedFixture("English", into: pipeline, origin: origin + 20)
            try await pipeline.finish()
        } catch {
            await pipeline.cancel()
            throw error
        }
        #expect(results.errors.isEmpty)
        let firstPhrase = try #require(results.transcript.segments.first {
            $0.text.localizedCaseInsensitiveContains("Welcome to Relay")
        })
        #expect(firstPhrase.isFinal)
        #expect(firstPhrase.timestamp >= 19.8)
        #expect(firstPhrase.timestamp < 21)
        let openingUpdates = results.updates.filter {
            $0.text.localizedCaseInsensitiveContains("Welcome")
        }
        #expect(openingUpdates.contains { !$0.isFinal }, "The fixture must exercise live timing before finalization.")
        for update in openingUpdates {
            #expect(update.timestamp >= 19.8 && update.timestamp < 21,
                    "Live opening speech must remain at its spoken time; finalization must not repair an earlier jump to zero.")
        }
        if ProcessInfo.processInfo.environment["RELAY_SPEECH_TIMING_METRICS"] == "1" {
            for metadata in results.timingMetadata {
                print("Relay fictional timing evidence: source=\(source.rawValue) final=\(metadata.isFinal) rangeStart=\(metadata.resultStart ?? -1) rangeEnd=\(metadata.resultEnd ?? -1) finalizedThrough=\(metadata.finalizationTime ?? -1) missing=\(metadata.missingWordRanges) zeroDuration=\(metadata.zeroDurationWordRanges) positive=\(metadata.positiveDurationWordRanges) earliestPositive=\(metadata.earliestPositiveWordStart ?? -1) chosen=\(metadata.chosenStart)")
            }
        }
        #expect(results.transcript.text.localizedCaseInsensitiveContains("latest design"))
    }

    @Test("Live onset after a finalized utterance and long silence stays on each source clock", .timeLimit(.minutes(2)))
    func silenceBetweenUtterancesTiming() async throws {
        for source in TranscriptSource.allCases {
            let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await installation.downloadAndInstall()
            }
            let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
            let results = IntegrationResults()
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let pipeline = SpeechPipeline(source: source, transcriber: module, format: format, origin: origin,
                onUpdate: { results.apply($0) }, onLevel: { _ in },
                onFailure: { results.errors.append($0.localizedDescription) },
                onTimingMetadata: { results.timingMetadata.append($0) })
            let fixture = try AVAudioFile(forReading: fixtureURL("English"))
            let duration = Double(fixture.length) / fixture.processingFormat.sampleRate
            let nextOpening = duration + 20
            do {
                try await pipeline.start()
                try feedFixture("English", into: pipeline, origin: origin)
                let silence = try #require(AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(format.sampleRate)))
                silence.frameLength = silence.frameCapacity
                for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                for second in 0..<20 { pipeline.accept(silence, hostTime: origin + duration + Double(second)) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while !results.updates.contains(where: { $0.isFinal && $0.text.localizedCaseInsensitiveContains("latest design") }) {
                    try #require(ContinuousClock.now < deadline, "The first utterance must finalize before the next one begins.")
                    try await Task.sleep(for: .milliseconds(5))
                }
                let firstPhaseUpdateCount = results.updates.count
                try feedFixture("English", into: pipeline, origin: origin + nextOpening)
                try await pipeline.finish()
                let resumedOpening = results.updates.dropFirst(firstPhaseUpdateCount).filter {
                    $0.text.localizedCaseInsensitiveContains("Welcome")
                }
                #expect(resumedOpening.contains { !$0.isFinal }, "Both source kinds must exercise the second live utterance.")
                for update in resumedOpening {
                    #expect(update.timestamp >= nextOpening - 0.2 && update.timestamp < nextOpening + 1,
                        "A new live utterance must use its voice onset, not the previous finalized range or gap boundary.")
                }
            } catch {
                await pipeline.cancel()
                throw error
            }
            #expect(results.errors.isEmpty)
            #expect(results.transcript.segments.allSatisfy { $0.source == source && $0.isFinal })
            let normalized = results.transcript.text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
            #expect(normalized.components(separatedBy: "welcome to relay").count - 1 == 2)
            #expect(normalized.components(separatedBy: "latest design").count - 1 == 2)
        }
    }

    @Test("Unrecognized startup activity cannot timestamp later live speech at zero", .timeLimit(.minutes(2)))
    func unclaimedStartupActivityTiming() async throws {
        for source in TranscriptSource.allCases {
            let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await installation.downloadAndInstall()
            }
            let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
            let results = IntegrationResults()
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let pipeline = SpeechPipeline(source: source, transcriber: module, format: format, origin: origin,
                onUpdate: { results.apply($0) }, onLevel: { _ in },
                onFailure: { results.errors.append($0.localizedDescription) })
            do {
                try await pipeline.start()
                let toneFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000, channels: 1, interleaved: false))
                let startup = try #require(AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: 16_000))
                startup.frameLength = startup.frameCapacity
                for index in 0..<16_000 {
                    let time = Double(index) / 16_000
                    startup.floatChannelData![0][index] = Float((sin(time * 2 * .pi * 180)
                        + 0.5 * sin(time * 2 * .pi * 360)) * 0.15)
                }
                // A harmonic nonverbal startup signal is VAD-positive but has
                // no intended words. Its old episode precedes 20 seconds quiet.
                pipeline.accept(startup, hostTime: origin)
                let silence = try #require(AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(format.sampleRate)))
                silence.frameLength = silence.frameCapacity
                for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                for second in 0..<20 { pipeline.accept(silence, hostTime: origin + 1 + Double(second)) }
                try feedFixture("English", into: pipeline, origin: origin + 21)
                try await pipeline.finish()
            } catch {
                await pipeline.cancel()
                throw error
            }
            let opening = results.updates.filter { $0.text.localizedCaseInsensitiveContains("Welcome") }
            #expect(opening.contains { !$0.isFinal })
            for update in opening {
                #expect(update.timestamp >= 20.8 && update.timestamp < 22,
                    "A startup VAD episode without recognized words must not claim speech after a long quiet gap.")
            }
            #expect(results.errors.isEmpty)
            #expect(results.transcript.text.localizedCaseInsensitiveContains("Welcome to Relay"))
            #expect(results.transcript.text.localizedCaseInsensitiveContains("latest design"))
        }
    }

    @Test("Auto preserves the buffered opening and the live tail", .timeLimit(.minutes(2)))
    func openingReplayAndLiveTail() async throws {
        let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installation.downloadAndInstall()
        }
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        let results = IntegrationResults()
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let bridge = try BufferedAudioPipeline(source: .systemAudio,
            onSamples: { _ in }, onLevel: { _ in }, onFailure: { results.errors.append($0.localizedDescription) })
        let pipeline = SpeechPipeline(source: .systemAudio, transcriber: module, format: format, origin: origin,
            onUpdate: { results.apply($0) }, onLevel: { _ in }, onFailure: { results.errors.append($0.localizedDescription) })
        do {
            let file = try AVAudioFile(forReading: fixtureURL("English"))
            var cursor: Int64 = 0
            while file.framePosition < file.length, Double(cursor) / file.processingFormat.sampleRate < 6 {
                let buffer = try nextBuffer(file)
                bridge.accept(buffer, hostTime: origin + Double(cursor) / file.processingFormat.sampleRate)
                cursor += Int64(buffer.frameLength)
            }
            let opening = await bridge.detectionSamples()
            #expect(opening.count > 3 * 16_000)
            try await pipeline.start()
            try await bridge.install(pipeline)
            while file.framePosition < file.length {
                let buffer = try nextBuffer(file)
                bridge.accept(buffer, hostTime: origin + Double(cursor) / file.processingFormat.sampleRate)
                cursor += Int64(buffer.frameLength)
            }
            try await bridge.finish()
        } catch {
            await bridge.cancel()
            await pipeline.cancel()
            throw error
        }
        #expect(results.errors.isEmpty)
        #expect(results.transcript.segments.allSatisfy { $0.isFinal })
        #expect(results.transcript.text.localizedCaseInsensitiveContains("Welcome to Relay"))
        #expect(results.transcript.text.localizedCaseInsensitiveContains("latest design"))
    }

    private func feedFixture(_ name: String, into pipeline: SpeechPipeline, origin: Double) throws {
        let file = try AVAudioFile(forReading: fixtureURL(name))
        var cursor: Int64 = 0
        while file.framePosition < file.length {
            let buffer = try nextBuffer(file)
            pipeline.accept(buffer, hostTime: origin + Double(cursor) / file.processingFormat.sampleRate)
            cursor += Int64(buffer.frameLength)
        }
    }

    private func nextBuffer(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount(min(4096, file.length - file.framePosition))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        return buffer
    }

    private func detectionSamples(_ name: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: fixtureURL(name))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let converter = PCMBufferConversion(targetFormat: target)
        var samples: [Float] = []
        while file.framePosition < file.length {
            if let converted = try converter.convert(nextBuffer(file)) {
                samples.append(contentsOf: UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
            }
        }
        for tail in try converter.flush() {
            samples.append(contentsOf: UnsafeBufferPointer(start: tail.floatChannelData![0], count: Int(tail.frameLength)))
        }
        return samples
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: AudioFixtureBundle.self)
        return try #require(bundle.url(forResource: name, withExtension: "aiff", subdirectory: "Fixtures")
                            ?? bundle.url(forResource: name, withExtension: "aiff"))
    }
}

private final class AudioFixtureBundle: NSObject {}

@MainActor
private final class IntegrationResults {
    var transcript = SessionTranscript()
    var timingMetadata: [SpeechResultTiming.Metadata] = []
    var errors: [String] = []
    var levels: [Double] = []
    var partials = 0
    var updates: [TranscriptUpdate] = []

    func apply(_ update: TranscriptUpdate) {
        updates.append(update)
        if !update.isFinal { partials += 1 }
        transcript.apply(update)
    }
}
