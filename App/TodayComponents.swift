import SwiftUI
import UIKit

enum TodayColors {
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.67, green: 0.71, blue: 0.69, alpha: 1)
            : UIColor(red: 0.36, green: 0.40, blue: 0.38, alpha: 1)
    })
}

struct TodayPanel<Content: View>: View {
    private let tinted: Bool
    private let content: Content
    init(tinted: Bool = false, @ViewBuilder content: () -> Content) {
        self.tinted = tinted
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .background {
                RoundedRectangle(cornerRadius: 26).fill(Palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 26).fill(Palette.accent.opacity(tinted ? 0.045 : 0)))
            }
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Palette.accent.opacity(0.13)))
    }
}

struct TodayPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .foregroundStyle(scheme == .dark ? Palette.background : .white)
            .padding(.horizontal, 20).padding(.vertical, 17).frame(maxWidth: .infinity, minHeight: 54)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct TodayResourceLabel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: symbol).font(.title3).foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !typeSize.isAccessibilitySize { Text(subtitle).font(.caption).foregroundStyle(TodayColors.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent).accessibilityHidden(true) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.accent.opacity(0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct TodayNotebookIllustration: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(0.06)).frame(width: size * 0.96, height: size * 0.96)
            RoundedRectangle(cornerRadius: size * 0.09).fill(Palette.accent.opacity(0.12))
                .frame(width: size * 0.63, height: size * 0.78).rotationEffect(.degrees(-13)).offset(x: -size * 0.05, y: size * 0.015)
            RoundedRectangle(cornerRadius: size * 0.09).fill(Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: size * 0.09).strokeBorder(Palette.accent.opacity(0.22)))
                .overlay {
                    VStack(spacing: size * 0.06) {
                        Text("あ").font(.system(size: size * 0.36, weight: .regular, design: .serif)).foregroundStyle(Palette.accent)
                        Capsule().fill(Palette.accent.opacity(0.20)).frame(width: size * 0.30, height: 2)
                        Capsule().fill(Palette.accent.opacity(0.10)).frame(width: size * 0.21, height: 2)
                    }
                }
                .frame(width: size * 0.63, height: size * 0.78).rotationEffect(.degrees(9)).offset(x: size * 0.06, y: -size * 0.025)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
