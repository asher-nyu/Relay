@preconcurrency import AVFoundation
import CoreMedia

protocol AudioTranscriptionPipeline: AnyObject, Sendable {
    func start() async throws
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?)
    func accept(_ sample: CMSampleBuffer)
    func finish() async throws
    func cancel() async
}
