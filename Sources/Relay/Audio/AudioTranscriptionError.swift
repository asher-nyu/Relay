import Foundation

enum AudioTranscriptionError: LocalizedError, Equatable {
    case noSource
    case unavailable
    case unsupportedLanguage(String)
    case microphonePermission
    case microphoneUnavailable
    case systemAudioPermission
    case speakerEchoReferencePermission
    case noDisplay
    case noMicrophone
    case audioFormat
    case audioConversion
    case audioBacklog
    case languageUncertain
    case languagePreparationTooLong
    case speakerEchoReductionUnavailable

    var errorDescription: String? {
        switch self {
        case .noSource: "Choose System Audio, Microphone, or both before starting."
        case .unavailable: "On-device transcription isn’t available on this Mac. Relay requires a Mac that supports Apple’s SpeechTranscriber."
        case let .unsupportedLanguage(language): "On-device transcription isn’t available for \(language). Choose another language."
        case .microphonePermission: "Allow Relay to use the microphone in System Settings → Privacy & Security → Microphone, then try again."
        case .microphoneUnavailable: "Relay couldn’t start the microphone. Check your microphone in System Settings → Sound, then try again."
        case .systemAudioPermission: "Allow Relay in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. You may need to reopen Relay after changing this permission."
        case .speakerEchoReferencePermission: "To reduce speaker echo, allow Relay in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noDisplay: "Relay couldn’t access a display for system audio capture. Connect a display and try again."
        case .noMicrophone: "No microphone is available. Connect a microphone or choose System Audio."
        case .audioFormat: "The selected audio device uses a format Relay couldn’t read. Check your sound settings and try again."
        case .audioConversion: "Relay couldn’t prepare the incoming audio for transcription. Check your sound settings and try again."
        case .audioBacklog: "Transcription couldn’t keep up with the incoming audio. The session has stopped to avoid missing words. Close other audio-intensive apps and try again."
        case .languageUncertain: "Relay couldn’t confidently identify the spoken language. Choose a language and start a new session."
        case .languagePreparationTooLong: "Preparing this language took too long. Choose the language directly to finish downloading its transcription model before starting a new session."
        case .speakerEchoReductionUnavailable: "Speaker echo reduction isn’t available for this audio setup. Choose another audio input or output in System Settings → Sound, then try again."
        }
    }
}
