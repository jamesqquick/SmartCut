import AppKit
import SwiftUI

/// SmartCut design tokens — a Stripe-inspired system with a two-tone
/// brand identity (Pulse Indigo + Signal Teal). All surface colors are
/// appearance-adaptive so the app reads intentionally in both light and
/// dark mode. See `docs/ui-mockup.html` for the visual reference.
enum Theme {
    /// Corner radius used across cards, buttons, inputs, and chips.
    /// Deliberately 6px (a softened step off Stripe's 4px discipline).
    static let radius: CGFloat = 6
    static let radiusSmall: CGFloat = 4

    // MARK: - Brand (appearance-invariant)

    /// Primary accent. Mirrors the app's `AccentColor` asset so
    /// `.accentColor` / `.borderedProminent` controls match.
    static let indigo = Color(srgb: 0x5848F2)
    static let indigoHover = Color(srgb: 0x6D5DFF)
    /// Companion accent used for gradients, halos, and the stitched preview.
    static let teal = Color(srgb: 0x19C8D6)
    static let tealSoft = Color(srgb: 0x5FE0E8)
    /// Lighter violet used as the gradient-title origin in dark mode.
    static let lumen = Color(srgb: 0x9AA0FF)

    // MARK: - Surfaces (adaptive)

    /// Page background — Mist in light, near-black blue in dark.
    static let canvas = Color(light: 0xE5EDF5, dark: 0x0A0E1A)
    /// Default card / panel surface — Snow in light.
    static let card = Color(light: 0xF8FAFD, dark: 0x121826)
    /// Highest elevation — floating cards, logs, modal surfaces.
    static let elevated = Color(light: 0xFFFFFF, dark: 0x1A2233)
    /// Brand-tinted wash for chips, active steps, ghost hovers.
    static let wash = Color(
        light: NSColor(srgb: 0xE2E4FF),
        dark: NSColor(srgb: 0x5848F2, alpha: 0.18)
    )

    // MARK: - Text

    static let ink = Color(light: 0x061B31, dark: 0xF0F3F9)
    static let bodyText = Color(light: 0x50617A, dark: 0xAAB6C8)
    static let muted = Color(light: 0x64748D, dark: 0x7D8BA4)
    static let tertiary = Color(light: 0x7D8BA4, dark: 0x64748D)

    // MARK: - Lines

    static let border = Color(
        light: NSColor(srgb: 0xD7E0EB),
        dark: NSColor(white: 1, alpha: 0.08)
    )
    static let borderStrong = Color(
        light: NSColor(srgb: 0xC2CEDD),
        dark: NSColor(white: 1, alpha: 0.16)
    )

    // MARK: - Status (desaturated so they never fight the indigo)

    static let good = Color(light: 0x5C9A12, dark: 0x9AD13A)
    static let danger = Color(light: 0xD23B2F, dark: 0xFF6B60)
    static let warn = Color(light: 0xB8860B, dark: 0xFFCF5E)

    // MARK: - Gradients

    /// Signature indigo→teal headline fill. Lightens in dark mode so it
    /// stays legible against the dark canvas.
    static func titleGradient(_ scheme: ColorScheme) -> LinearGradient {
        let stops: [Color] = scheme == .dark ? [lumen, tealSoft] : [indigo, teal]
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// Atmospheric halo bled from the top-right of a surface. Used only on
    /// the Drop and Done screens — decoration, never behind readable text.
    static func halo(_ scheme: ColorScheme) -> RadialGradient {
        let inner = indigo.opacity(scheme == .dark ? 0.40 : 0.42)
        let mid = teal.opacity(scheme == .dark ? 0.20 : 0.24)
        return RadialGradient(
            colors: [inner, mid, .clear],
            center: .topTrailing,
            startRadius: 0,
            endRadius: 620
        )
    }
}

// MARK: - Color helpers

extension Color {
    /// Build a color from a 24-bit sRGB hex literal (e.g. `0x5848F2`).
    init(srgb hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Appearance-adaptive color from two hex literals.
    init(light: UInt32, dark: UInt32) {
        self.init(light: NSColor(srgb: light), dark: NSColor(srgb: dark))
    }

    /// Appearance-adaptive color from two explicit `NSColor`s (for alpha).
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

extension NSColor {
    convenience init(srgb hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - View modifiers

extension View {
    /// Apply the signature indigo→teal gradient fill to a headline `Text`.
    func gradientTitle(_ scheme: ColorScheme) -> some View {
        foregroundStyle(Theme.titleGradient(scheme))
    }
}
