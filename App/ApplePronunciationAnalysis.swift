import AVFoundation
import Foundation
import Speech

struct AppleAudioFeatures: Equatable, Sendable {
    var duration: Double
    var normalizedPitchContour: [Double]
}

struct ApplePronunciationAssessment: Equatable, Sendable {
    var recognizedText: String?
    var overall: Double
    var textMatch: Double?
    var pitchContour: Double
    var rhythm: Double
    var recognitionNote: String?
}

enum ApplePronunciationAnalyzer {
    static func analyze(
        referenceURL: URL,
        recordingURL: URL,
        expectedTexts: [String]
    ) async throws -> ApplePronunciationAssessment {
        async let reference = Task.detached(priority: .userInitiated) {
            try AudioFeatureExtractor.extract(from: referenceURL)
        }.value
        async let recording = Task.detached(priority: .userInitiated) {
            try AudioFeatureExtractor.extract(from: recordingURL)
        }.value

        let (referenceFeatures, recordingFeatures) = try await (reference, recording)
        let transcription: String?
        let recognitionNote: String?
        do {
            transcription = try await AppleJapaneseTranscriber.transcribe(recordingURL)
            recognitionNote = nil
        } catch ApplePronunciationError.onDeviceRecognitionUnavailable {
            transcription = nil
            recognitionNote = "Японское распознавание на устройстве недоступно; оценены контур высоты и ритм."
        } catch ApplePronunciationError.speechPermissionDenied {
            transcription = nil
            recognitionNote = "Нет разрешения на распознавание речи; оценены контур высоты и ритм."
        } catch {
            transcription = nil
            recognitionNote = "Текст не распознан; оценены контур высоты и ритм."
        }
        return LocalPronunciationScoring.score(
            reference: referenceFeatures,
            recording: recordingFeatures,
            recognizedText: transcription,
            expectedTexts: expectedTexts,
            recognitionNote: recognitionNote
        )
    }
}

enum LocalPronunciationScoring {
    static func score(
        reference: AppleAudioFeatures,
        recording: AppleAudioFeatures,
        recognizedText: String?,
        expectedTexts: [String],
        recognitionNote: String? = nil
    ) -> ApplePronunciationAssessment {
        let pitch = contourScore(reference.normalizedPitchContour, recording.normalizedPitchContour)
        let ratio = max(reference.duration, recording.duration) / max(min(reference.duration, recording.duration), 0.05)
        let rhythm = max(0, min(100, 100 - abs(log(ratio)) * 65))
        let text = recognizedText.map { recognized in
            expectedTexts.map { textSimilarity(recognized, $0) }.max() ?? 0
        }
        let overall = text.map { $0 * 0.35 + pitch * 0.45 + rhythm * 0.20 }
            ?? (pitch * 0.70 + rhythm * 0.30)
        return ApplePronunciationAssessment(
            recognizedText: recognizedText,
            overall: overall,
            textMatch: text,
            pitchContour: pitch,
            rhythm: rhythm,
            recognitionNote: recognitionNote
        )
    }

    private static func contourScore(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var totalError = 0.0
        for index in lhs.indices {
            totalError += abs(lhs[index] - rhs[index])
        }
        let error = totalError / Double(lhs.count)
        return max(0, min(100, 100 - error * 18))
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(normalize(lhs))
        let right = Array(normalize(rhs))
        guard !left.isEmpty || !right.isEmpty else { return 100 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        let distance = previous.last ?? max(left.count, right.count)
        return max(0, 100 * (1 - Double(distance) / Double(max(left.count, right.count))))
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja-JP"))
            .unicodeScalars
            .filter { CharacterSet.letters.union(.decimalDigits).contains($0) }
            .map(String.init)
            .joined()
    }
}

private enum AudioFeatureExtractor {
    static func extract(from url: URL) throws -> AppleAudioFeatures {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 30),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              )
        else { throw ApplePronunciationError.invalidAudio }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw ApplePronunciationError.invalidAudio }
        let original = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let stride = max(1, Int(file.processingFormat.sampleRate / 8_000))
        let sampleRate = file.processingFormat.sampleRate / Double(stride)
        let downsampled = Swift.stride(from: 0, to: original.count, by: stride).map { original[$0] }
        let samples = trimSilence(downsampled)
        guard samples.count >= Int(sampleRate * 0.12) else { throw ApplePronunciationError.insufficientSpeech }
        let pitch = pitchContour(samples: samples, sampleRate: sampleRate)
        guard pitch.count >= 3 else { throw ApplePronunciationError.insufficientSpeech }
        return AppleAudioFeatures(
            duration: Double(samples.count) / sampleRate,
            normalizedPitchContour: normalizeAndResample(pitch, count: 32)
        )
    }

    private static func trimSilence(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else { return [] }
        let threshold = max(0.004, peak * 0.06)
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold })
        else { return [] }
        return Array(samples[first...last])
    }

    private static func pitchContour(samples: [Float], sampleRate: Double) -> [Double] {
        let window = max(160, Int(sampleRate * 0.04))
        let hop = max(80, Int(sampleRate * 0.02))
        let minimumLag = max(1, Int(sampleRate / 420))
        let maximumLag = min(window / 2, Int(sampleRate / 70))
        guard samples.count >= window, minimumLag < maximumLag else { return [] }
        var contour: [Double] = []
        for start in Swift.stride(from: 0, through: samples.count - window, by: hop) {
            let frame = Array(samples[start..<(start + window)])
            let mean = frame.reduce(0, +) / Float(frame.count)
            let centered = frame.map { $0 - mean }
            let energy = sqrt(centered.reduce(0) { $0 + $1 * $1 } / Float(centered.count))
            guard energy > 0.008 else { continue }
            var bestLag = 0
            var bestCorrelation: Float = 0
            for lag in minimumLag...maximumLag {
                var cross: Float = 0
                var leftEnergy: Float = 0
                var rightEnergy: Float = 0
                for index in 0..<(window - lag) {
                    let left = centered[index]
                    let right = centered[index + lag]
                    cross += left * right
                    leftEnergy += left * left
                    rightEnergy += right * right
                }
                let denominator = sqrt(leftEnergy * rightEnergy)
                let correlation = denominator > 0 ? cross / denominator : 0
                if correlation > bestCorrelation {
                    bestCorrelation = correlation
                    bestLag = lag
                }
            }
            if bestLag > 0, bestCorrelation >= 0.45 {
                contour.append(12 * log2((sampleRate / Double(bestLag)) / 100))
            }
        }
        return contour
    }

    private static func normalizeAndResample(_ values: [Double], count: Int) -> [Double] {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let normalized = values.map { $0 - median }
        guard normalized.count > 1 else { return Array(repeating: 0, count: count) }
        return (0..<count).map { index in
            let position = Double(index) * Double(normalized.count - 1) / Double(count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, normalized.count - 1)
            let fraction = position - Double(lower)
            return normalized[lower] * (1 - fraction) + normalized[upper] * fraction
        }
    }
}

@MainActor
private enum AppleJapaneseTranscriber {
    static func transcribe(_ url: URL) async throws -> String {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw ApplePronunciationError.speechPermissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else { throw ApplePronunciationError.onDeviceRecognitionUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            let box = SpeechContinuationBox(continuation: continuation)
            box.task = recognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    if let error { box.finish(.failure(error)) }
                    else if let result, result.isFinal { box.finish(.success(result.bestTranscription.formattedString)) }
                }
            }
        }
    }
}

@MainActor
private final class SpeechContinuationBox {
    private var continuation: CheckedContinuation<String, Error>?
    var task: SFSpeechRecognitionTask?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task?.cancel()
        continuation.resume(with: result)
    }
}

enum ApplePronunciationError: LocalizedError {
    case invalidAudio
    case insufficientSpeech
    case speechPermissionDenied
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAudio: "Не удалось прочитать аудиозапись."
        case .insufficientSpeech: "В записи недостаточно отчётливой речи для сравнения."
        case .speechPermissionDenied: "Разрешите распознавание речи в настройках системы."
        case .onDeviceRecognitionUnavailable: "Японское распознавание на устройстве сейчас недоступно."
        }
    }
}
