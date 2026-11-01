import Foundation
@preconcurrency import WhisperKit

/// Language identification uses the actual PCM waveform, never guessed English text.
/// The multilingual model is downloaded before capture. Only model files use the network.
@MainActor
final class AutoLanguageDetector {
    private var model: WhisperKit?

    func prepare() async throws {
        guard model == nil else { return }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appending(path: "Relay/Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        model = try await WhisperKit(WhisperKitConfig(model: "openai_whisper-tiny", downloadBase: directory,
                                                      verbose: false, logLevel: .error,
                                                      prewarm: false, load: true, download: true))
    }

    func detect(samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard samples.count >= 12_000, let model else { throw AudioTranscriptionError.languageUncertain }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        guard energy.isFinite, energy >= 0.000_016 else { throw AudioTranscriptionError.languageUncertain }
        // The publisher keeps this spelling in its public 1.1.1 API.
        let result = try await model.detectLangauge(audioArray: samples)
        try Task.checkCancellation()
        guard let logProbability = result.langProbs[result.language], logProbability.isFinite,
              exp(Double(logProbability)) >= 0.45 else {
            throw AudioTranscriptionError.languageUncertain
        }
        return result.language
    }
}
