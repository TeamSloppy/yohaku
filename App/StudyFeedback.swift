import AVFoundation
import SwiftUI

@MainActor
final class StudyFeedback {
    static let shared = StudyFeedback()
    static let soundKey = "study-feedback-sounds-enabled"
    enum Effect: String, CaseIterable { case correct, completion }
    private var players: [Effect: AVAudioPlayer] = [:]

    private init() {
        for effect in Effect.allCases {
            if let url = Bundle.main.url(forResource: "study-" + effect.rawValue, withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.volume = 0.6
                player.prepareToPlay()
                players[effect] = player
            }
        }
    }

    func play(_ effect: Effect) {
        guard UserDefaults.standard.object(forKey: Self.soundKey) as? Bool ?? true else { return }
        // Finish the little fanfare cleanly when an answer arrives at the end of a round.
        for player in players.values { player.stop(); player.currentTime = 0 }
        players[effect]?.play()
    }
}

struct StudyCelebrationView: View {
    let title: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var celebrated = false

    var body: some View {
        Group {
            if verticalSizeClass == .compact && !typeSize.isAccessibilitySize {
                HStack(spacing: 28) { medal; message }
            } else {
                VStack(spacing: 18) { medal; message }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .overlay {
            if !reduceMotion { confetti }
        }
        .task {
            guard !celebrated else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6)) { celebrated = true }
        }
    }

    private var medal: some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(0.12)).frame(width: 132, height: 132)
            Image(systemName: "star.circle.fill")
                .font(.system(size: 82, weight: .light))
                .foregroundStyle(Palette.accent)
                .scaleEffect(reduceMotion || celebrated ? 1 : 0.75)
            Image(systemName: "sparkle").font(.title2).foregroundStyle(.orange)
                .offset(x: 64, y: -42)
            Image(systemName: "sparkle").font(.headline).foregroundStyle(Palette.accent)
                .offset(x: -65, y: 30)
        }
        .accessibilityHidden(true)
    }

    private var message: some View {
        VStack(spacing: 18) {
            Text(title).font(.title2.bold()).accessibilityIdentifier("study-complete")
            Text("Ещё один шаг вперёд!").font(.title3).foregroundStyle(Palette.accent)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var confetti: some View {
        GeometryReader { geometry in
            ForEach(0..<28) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill([Palette.accent, Color.orange, Color.yellow, Color.pink][index % 4])
                    .frame(width: 6, height: index.isMultiple(of: 3) ? 6 : 12)
                    .rotationEffect(.degrees(celebrated ? Double(index * 47) : 0))
                    .position(x: celebrated ? geometry.size.width * CGFloat((index * 37) % 101) / 100 : geometry.size.width / 2,
                              y: celebrated ? geometry.size.height * CGFloat(40 + (index * 23) % 65) / 100 : 64)
                    .opacity(celebrated ? 0 : 1)
                    .animation(.easeOut(duration: 1.8).delay(Double(index % 5) * 0.045), value: celebrated)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
