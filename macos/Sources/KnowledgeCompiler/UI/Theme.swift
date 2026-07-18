import SwiftUI

enum Theme {
    static let panelBG = Color(red: 6 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.55)
    static let panelBorder = Color(red: 0, green: 240 / 255, blue: 1).opacity(0.12)
    static let baseDeep = Color(red: 3 / 255, green: 16 / 255, blue: 16 / 255)
    static let baseTeal = Color(red: 5 / 255, green: 36 / 255, blue: 36 / 255)
    static let textPrimary = Color(red: 230 / 255, green: 249 / 255, blue: 249 / 255)
    static let textSecondary = Color(red: 138 / 255, green: 184 / 255, blue: 184 / 255)
    static let cyan = Color(red: 77 / 255, green: 1, blue: 210 / 255)
    static let aqua = Color(red: 0, green: 240 / 255, blue: 1)
    static let teal = Color(red: 0, green: 188 / 255, blue: 212 / 255)
    static let tealDark = Color(red: 0, green: 119 / 255, blue: 136 / 255)
    static let green = Color(red: 46 / 255, green: 204 / 255, blue: 113 / 255)
    static let orange = Color(red: 243 / 255, green: 156 / 255, blue: 18 / 255)

    static func display(_ size: CGFloat) -> Font {
        .custom("AvenirNext-UltraLight", size: size)
    }

    static func body(_ size: CGFloat = 13) -> Font {
        .custom("AvenirNext-Regular", size: size)
    }

    static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, design: .monospaced).weight(.light)
    }
}

extension View {
    func glowTitle(_ size: CGFloat, rotation: Double = -1.4) -> some View {
        self
            .font(Theme.display(size))
            .foregroundStyle(Color(red: 242 / 255, green: 1, blue: 1))
            .shadow(color: Theme.aqua.opacity(0.45), radius: 9)
            .shadow(color: Theme.cyan.opacity(0.22), radius: 21)
            .rotationEffect(.degrees(rotation), anchor: .leading)
    }
}
