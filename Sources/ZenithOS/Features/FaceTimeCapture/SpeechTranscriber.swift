import AVFoundation
import Speech

// Wraps SFSpeechRecognizer with a rolling recognition task.
// SFSpeechRecognizer tasks time out after ~60s — this restarts automatically.
// Results are accumulated in `segments` array, which is safe to read from any thread.

final class SpeechTranscriber: NSObject {

    let speaker: String
    private let recognizer: SFSpeechRecognizer

    private(set) var segments: [TranscriptSegment] = []
    private let segmentsLock = NSLock()

    private var callStart: Date?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastFinalResult: String = ""

    init(speaker: String, locale: Locale = .init(identifier: "en-US")) {
        self.speaker = speaker
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()!
        super.init()
        recognizer.defaultTaskHint = .dictation
    }

    // MARK: - Lifecycle

    func start(callStart: Date) {
        self.callStart = callStart
        startTask()
    }

    func stop() {
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }

    // MARK: - Feed audio

    /// Feed a buffer from AVAudioEngine tap or ScreenCaptureKit audio output.
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    // MARK: - Private

    private func startTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false         // only emit on silence boundary
        req.requiresOnDeviceRecognition = false        // set true to avoid network calls
        req.addsPunctuation = true
        self.request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text != self.lastFinalResult {
                    self.lastFinalResult = text
                    let ts = Date().timeIntervalSince(self.callStart ?? Date())
                    let seg = TranscriptSegment(timestamp: ts, speaker: self.speaker, text: text)
                    self.segmentsLock.lock()
                    self.segments.append(seg)
                    self.segmentsLock.unlock()
                }
                // Restart task — speech recognition has a 1-minute limit per task
                self.startTask()
            }

            if let error = error as NSError?,
               error.domain != "kAFAssistantErrorDomain" {   // filter expected cancellation errors
                print("[SpeechTranscriber:\(self.speaker)] Error: \(error.localizedDescription)")
                self.startTask()
            }
        }
    }
}
