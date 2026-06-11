import SwiftUI

extension Color {
  init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a, r, g, b: UInt64
    switch hex.count {
    case 3:
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      (a, r, g, b) = (255, 0, 0, 0)
    }

    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }
}

enum DesignSystem {
  enum colors {
    static let adminBackground = Color(hex: "#F9FAF7")
    static let adminSurface = Color(hex: "#FFFFFF")
    static let adminInk = Color(hex: "#2C2C2C")
    static let adminMuted = Color(hex: "#646464")
    static let adminSubtle = Color(hex: "#B4B8B4")
    static let adminStroke = Color(hex: "#DEE2DE")
    static let brandOrange = Color(hex: "#DD6B2E")
    static let brandOrangeDeep = Color(hex: "#B85222")
    static let successGreen = Color(hex: "#1F9D6F")
    static let adminWarning = Color(hex: "#D8A838")

    static let deepNavy = Color(hex: "#080D18")
    static let surface = Color(hex: "#111827")
    static let surfaceRaised = Color(hex: "#1F2937")
    static let border = Color(hex: "#374151")
    static let vibrantTeal = Color(hex: "#06B6D4")
    static let deepGreen = Color(hex: "#10B981")
    static let warningAmber = Color(hex: "#F59E0B")
    static let dangerRed = Color(hex: "#EF4444")
    static let white = Color(hex: "#FFFFFF")
    static let blueGrey = Color(hex: "#9CA3AF")
  }

  enum fonts {
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
      .system(size: size, weight: weight, design: .monospaced)
    }

    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
      .system(size: size, weight: weight, design: .default)
    }
  }
}

struct BrutalistCardModifier: ViewModifier {
  let stroke: Color

  func body(content: Content) -> some View {
    content
      .padding(16)
      .background(DesignSystem.colors.surface)
      .overlay(
        Rectangle()
          .stroke(stroke, lineWidth: 1)
      )
  }
}

struct BrutalistPrimaryButtonModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(DesignSystem.fonts.mono(size: 16, weight: .semibold))
      .foregroundColor(DesignSystem.colors.deepNavy)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(DesignSystem.colors.vibrantTeal)
      .overlay(Rectangle().stroke(DesignSystem.colors.border, lineWidth: 1))
  }
}

struct BrutalistDangerButtonModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(DesignSystem.fonts.mono(size: 16, weight: .semibold))
      .foregroundColor(DesignSystem.colors.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(DesignSystem.colors.surface)
      .overlay(Rectangle().stroke(DesignSystem.colors.vibrantTeal, lineWidth: 1))
  }
}

extension View {
  func brutalistCard(stroke: Color = DesignSystem.colors.blueGrey) -> some View {
    modifier(BrutalistCardModifier(stroke: stroke))
  }

  func brutalistPrimaryButton() -> some View {
    modifier(BrutalistPrimaryButtonModifier())
  }

  func brutalistDangerButton() -> some View {
    modifier(BrutalistDangerButtonModifier())
  }
}
