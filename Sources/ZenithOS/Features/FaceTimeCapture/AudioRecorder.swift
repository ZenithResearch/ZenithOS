import AVFoundation
import Foundation

/// Writes a stream of AVAudioPCMBuffers to a 16 kHz mono WAV file on disk.
/// Thread-safe — append may be called from any queue.
final class AudioRecorder {

    let url: URL
    private var audioFile: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "com.zenith.audiorecorder", qos: .utility)

    /// - Parameters:
    ///   - url: Destination file URL (.wav)
    ///   - format: The format of buffers that will be passed to `append(_:)`.
    ///             The file is written in 16-bit PCM at the same sample rate.
    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVSampleRateKey:           format.sampleRate,
            AVNumberOfChannelsKey:     1,
            AVLinearPCMBitDepthKey:    16,
            AVLinearPCMIsFloatKey:     false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
    }

    /// Append a buffer. Safe to call from any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        writeQueue.async { [weak self] in
            try? self?.audioFile?.write(from: buffer)
        }
    }

    /// Flush pending writes and close the file. Returns the file URL and duration.
    func finalize() -> (url: URL, duration: Double) {
        var frames: AVAudioFramePosition = 0
        var sampleRate: Double = 16000
        writeQueue.sync {
            frames = audioFile?.length ?? 0
            sampleRate = audioFile?.processingFormat.sampleRate ?? 16000
            audioFile = nil   // closes the file
        }
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        return (url, duration)
    }
}
