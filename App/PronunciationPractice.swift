import AVFoundation
import SwiftUI

@MainActor
final class PronunciationRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordingURL: URL?
    @Published var error: String?
    private var recorder: AVAudioRecorder?

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Разрешите Yohaku доступ к микрофону в настройках системы."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yohaku-pronunciation-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else { throw PronunciationRecorderError.couldNotStart }
            self.recorder = recorder
            recordingURL = nil
            isRecording = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        guard let recorder else { return }
        recorder.stop()
        recordingURL = recorder.url
        self.recorder = nil
        isRecording = false
    }
}

private enum PronunciationRecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "Не удалось начать запись." }
}

struct PronunciationPracticePanel: View {
    let card: Flashcard
    let store: FlashcardStore
    @StateObject private var recorder = PronunciationRecorder()
    @StateObject private var player = PronunciationAudioPlayer()
    @State private var audio: FlashcardAudio?
    @State private var assessment: ApplePronunciationAssessment?
    @State private var busy = false
    @State private var error: String?
    @State private var provider = PronunciationServiceSettings.currentProvider

    init(card: Flashcard, store: FlashcardStore) {
        self.card = card
        self.store = store
        _audio = State(initialValue: card.pronunciationAudio)
    }

    var body: some View {
        VStack(spacing: 12) {
            Divider().padding(.vertical, 4)
            Text("Проверьте произношение")
                .font(.headline)

            if let audio {
                PronunciationAudioButton(audio: audio, store: store)
            } else {
                Button {
                    Task { await loadPronunciationSample() }
                } label: {
                    if busy { ProgressView() }
                    else { Label(sampleButtonTitle, systemImage: "waveform.badge.plus") }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityIdentifier("load-pronunciation-sample")
            }

            HStack {
                Button {
                    if recorder.isRecording { recorder.stop() }
                    else { Task { await recorder.start() } }
                } label: {
                    Label(recorder.isRecording ? "Остановить" : "Записать себя", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : Palette.accent)
                .accessibilityIdentifier("record-pronunciation")

                if let recordingURL = recorder.recordingURL {
                    Button {
                        player.play(url: recordingURL)
                    } label: {
                        Label("Моя запись", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("play-own-pronunciation")
                }
            }

            if recorder.recordingURL != nil {
                Button {
                    Task { await assessRecording() }
                } label: {
                    if busy { ProgressView() }
                    else { Label("Оценить произношение", systemImage: "checkmark.seal") }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityIdentifier("assess-pronunciation")
            }

            if let assessment {
                PronunciationAssessmentView(assessment: assessment)
            }

            if let error = error ?? recorder.error ?? player.error {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Text("Слушайте образец и свою запись по очереди. Apple Speech проверяет текст, AVFoundation сравнивает контур высоты и ритм локально.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var sampleButtonTitle: String {
        switch provider {
        case .kanjiAlive: "Загрузить пример Kanji alive"
        case .forvo: "Получить запись Forvo"
        }
    }

    private func loadPronunciationSample() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let stored: FlashcardAudio
            switch provider {
            case .kanjiAlive:
                let pronunciation = try await KanjiAliveAudioCatalog.fetchBest(term: card.japanese)
                let data = try await KanjiAliveAudioCatalog.download(pronunciation)
                stored = try await store.storePronunciationAudio(
                    data,
                    fileName: "kanji-alive-\(card.id.uuidString).mp3",
                    source: .kanjiAlive,
                    attribution: "Kanji alive · \(pronunciation.term)（\(pronunciation.reading)）",
                    sourceURL: pronunciation.audioURL
                )
            case .forvo:
                let pronunciation = try await ForvoAPI.fetchBest(term: card.japanese, key: PronunciationServiceSettings.storedForvoKey)
                let data = try await ForvoAPI.download(pronunciation)
                let country = pronunciation.country.map { " · \($0)" } ?? ""
                stored = try await store.storePronunciationAudio(
                    data,
                    fileName: "forvo-\(card.id.uuidString).mp3",
                    source: .forvo,
                    attribution: "Forvo · \(pronunciation.username)\(country)",
                    sourceURL: pronunciation.audioURL
                )
            }
            var updated = card
            updated.pronunciationAudio = stored
            await store.update(updated)
            audio = stored
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func assessRecording() async {
        guard let recordingURL = recorder.recordingURL,
              let audio,
              let referenceURL = store.pronunciationAudioURL(for: audio)
        else {
            error = "Сначала добавьте или загрузите образец произношения."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            assessment = try await ApplePronunciationAnalyzer.analyze(
                referenceURL: referenceURL,
                recordingURL: recordingURL,
                expectedTexts: [card.japanese, card.reading].filter { !$0.isEmpty }
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PronunciationAssessmentView: View {
    let assessment: ApplePronunciationAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Итог").font(.headline)
                Spacer()
                Text("\(Int(assessment.overall.rounded())) / 100")
                    .font(.title3.bold())
                    .foregroundStyle(scoreColor(assessment.overall))
            }
            if let textMatch = assessment.textMatch { score("Текст", textMatch) }
            score("Контур высоты", assessment.pitchContour)
            score("Ритм", assessment.rhythm)
            if let recognizedText = assessment.recognizedText {
                Text("Распознано: \(recognizedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = assessment.recognitionNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("pronunciation-assessment-result")
    }

    private func score(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title).font(.caption)
            ProgressView(value: value, total: 100)
            Text("\(Int(value.rounded()))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return Palette.accent }
        if score >= 60 { return .orange }
        return .red
    }
}
