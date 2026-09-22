import AVFoundation
import SwiftUI

@MainActor
final class PronunciationAudioPlayer: ObservableObject {
    @Published private(set) var playingPath: String?
    @Published var error: String?
    private var player: AVAudioPlayer?

    func play(_ audio: FlashcardAudio, from store: FlashcardStore) {
        guard let url = store.pronunciationAudioURL(for: audio) else {
            error = "Аудиофайл недоступен"
            return
        }
        play(url: url, path: audio.relativePath)
    }

    func play(url: URL, path: String? = nil) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            guard player.play() else {
                error = "Не удалось воспроизвести запись"
                return
            }
            self.player = player
            playingPath = path ?? url.path
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PronunciationAudioButton: View {
    let audio: FlashcardAudio
    let store: FlashcardStore
    @StateObject private var player = PronunciationAudioPlayer()

    var body: some View {
        VStack(spacing: 4) {
            Button {
                player.play(audio, from: store)
            } label: {
                Label("Живая запись", systemImage: "waveform.circle.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("play-pronunciation-audio")

            Text(audio.source.title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let attribution = audio.attribution, !attribution.isEmpty {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = player.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

enum JapanesePronunciationLinks {
    static func forvo(_ term: String) -> URL {
        url(host: "forvo.com", path: "/word/\(term)/", fragment: "ja")
    }

    static func youGlish(_ term: String) -> URL {
        url(host: "youglish.com", path: "/pronounce/\(term)/japanese")
    }

    static let ojad = URL(string: "https://www.gavo.t.u-tokyo.ac.jp/ojad/eng/pages/home")!

    private static func url(host: String, path: String, fragment: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.fragment = fragment
        return components.url!
    }
}

struct PronunciationReferencesMenu: View {
    let term: String

    var body: some View {
        Menu {
            Link("Forvo · записи носителей", destination: JapanesePronunciationLinks.forvo(term))
            Link("YouGlish · речь в контексте", destination: JapanesePronunciationLinks.youGlish(term))
            Link("OJAD · акцент и интонация", destination: JapanesePronunciationLinks.ojad)
        } label: {
            Label("Проверить произношение", systemImage: "person.wave.2")
        }
        .accessibilityIdentifier("pronunciation-references")
    }
}
