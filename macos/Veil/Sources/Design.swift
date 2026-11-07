import SwiftUI
import AppKit

// MARK: - Дизайн-система «Veil»
// Дружелюбная тёплая тема. Палитра сознательно сведена к 3 основным цветам:
//   • Акцент  — тёплый коралловый (#FF7A59)
//   • Фон     — тёплый угольный (#16161A)
//   • Текст   — тёплый белый (#F7F4F0)
// Никаких вторичных сигнальных цветов (зелёный/красный/жёлтый/голубой) — их роль
// выполняет акцент и приглушённый нейтральный серый.

extension Color {
    // Поверхности
    static let vBg       = Color(red: 0.086, green: 0.086, blue: 0.102) // #16161A
    static let vBgRaised = Color(red: 0.114, green: 0.114, blue: 0.137) // #1D1D23
    static let vPanel    = Color(red: 0.137, green: 0.137, blue: 0.161) // #232329
    static let vBubbleIn = Color(red: 0.165, green: 0.165, blue: 0.196) // #2A2A32
    static let vField    = Color.white.opacity(0.06)
    static let vHairline = Color.white.opacity(0.07)

    // Акцент (единственный сигнальный цвет)
    static let vAccent    = Color(red: 1.000, green: 0.478, blue: 0.349) // #FF7A59
    static let vAccentDark = Color(red: 0.902, green: 0.357, blue: 0.243) // #E65B3E

    // Текст
    static let vText  = Color(red: 0.969, green: 0.957, blue: 0.941) // #F7F4F0
    static let vMuted = Color(red: 0.663, green: 0.651, blue: 0.627) // #A9A6A0
}

/// Фирменный градиент — оттенки тепла (коралловый → глубокий красно-оранжевый).
struct VeilGradient {
    static let brand = LinearGradient(
        colors: [Color.vAccent, Color.vAccentDark],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let capsule = LinearGradient(
        colors: [Color.vAccent, Color.vAccentDark],
        startPoint: .leading, endPoint: .trailing)
}

/// Логотип-«вуаль»: мягкий градиентный квадрат с тёплым «светом в центре».
struct VeilLogo: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(VeilGradient.brand)
            // Два тёплых «занавеса», открывающих свет в центре
            Path { p in
                p.move(to: CGPoint(x: size*0.16, y: size*0.26))
                p.addArc(center: CGPoint(x: size*0.16, y: size*0.26),
                         radius: size*0.36, startAngle: .degrees(180), endAngle: .degrees(40), clockwise: true)
            }
            .fill(Color(red: 0.15, green: 0.05, blue: 0.03).opacity(0.55))
            Path { p in
                p.move(to: CGPoint(x: size*0.84, y: size*0.26))
                p.addArc(center: CGPoint(x: size*0.84, y: size*0.26),
                         radius: size*0.36, startAngle: .degrees(0), endAngle: .degrees(140), clockwise: false)
            }
            .fill(Color(red: 0.15, green: 0.05, blue: 0.03).opacity(0.55))
            Path { p in
                p.move(to: CGPoint(x: size*0.30, y: size*0.20))
                p.addArc(center: CGPoint(x: size*0.50, y: size*0.20),
                         radius: size*0.20, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            }
            .fill(Color(red: 0.15, green: 0.05, blue: 0.03).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: size*0.30, style: .continuous))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Аватар

struct VeilAvatar: View {
    let name: String
    var isSelf = false
    var online = false
    var size: CGFloat = 36

    private var initial: String {
        if isSelf { return "★" }
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(isSelf ? Color.vField : Color.vAccent.opacity(0.16))
                Text(initial)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(isSelf ? Color.vText : Color.vAccent)
            }
            .frame(width: size, height: size)
            if online {
                Circle().fill(Color.vAccent)
                    .frame(width: size * 0.30, height: size * 0.30)
                    .overlay(Circle().stroke(Color.vBgRaised, lineWidth: 2))
            }
        }
    }
}

/// Простая CTA-кнопка в капсуле с мягкой тенью.
struct VeilPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(VeilGradient.capsule)
            .clipShape(Capsule())
            .shadow(color: Color.vAccent.opacity(0.35), radius: 12, y: 5)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}