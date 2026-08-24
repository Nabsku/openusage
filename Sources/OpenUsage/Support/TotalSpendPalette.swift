import AppKit
import SwiftUI

/// Stable provider and account colors shared by the Total Spend chart, legend, and export.
enum TotalSpendPalette {
    private static let accountBrandHex: [String: UInt32] = [
        "claude": 0xDE7356,
        "codex": 0x10A37F,
    ]

    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),
        "codex": hex(0x10A37F),
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),
        "openrouter": hex(0x6467F2),
        "antigravity": hex(0x4285F4),
        "copilot": hex(0xA855F7),
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6),
    ]

    private static let fallback = [hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        if let components = accountComponents(for: providerID) {
            return Color(hue: components.hue, saturation: components.saturation, brightness: components.brightness)
        }
        let hash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[hash % fallback.count]
    }

    struct AccountColorComponents: Equatable {
        let hue: Double
        let saturation: Double
        let brightness: Double
    }

    static func accountComponents(for providerID: String) -> AccountColorComponents? {
        guard let separator = providerID.firstIndex(of: "@"),
              let brandHex = accountBrandHex[String(providerID[..<separator])]
        else { return nil }

        var accountKey = String(providerID[providerID.index(after: separator)...]).lowercased()
        if accountKey.hasPrefix("peer-") { accountKey.removeFirst("peer-".count) }
        guard !accountKey.isEmpty else { return nil }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in accountKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }

        let brand = hueSaturationBrightness(for: brandHex)
        let direction = hash & 1 == 0 ? -1.0 : 1.0
        let hueOffset = direction * (0.035 + Double((hash >> 1) & 0x7FFF) / Double(0x7FFF) * 0.055)
        let hue = (brand.hue + hueOffset + 1).truncatingRemainder(dividingBy: 1)
        let saturationSpread = Double((hash >> 16) & 0xFFFF) / Double(0xFFFF)
        let brightnessSpread = Double((hash >> 32) & 0xFFFF) / Double(0xFFFF)
        return AccountColorComponents(
            hue: hue,
            saturation: min(0.92, max(0.50, brand.saturation * (0.82 + saturationSpread * 0.25))),
            brightness: min(0.94, max(0.62, brand.brightness * (0.78 + brightnessSpread * 0.32)))
        )
    }

    private static func hueSaturationBrightness(for value: UInt32) -> AccountColorComponents {
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let brightness = max(red, max(green, blue))
        let delta = brightness - min(red, min(green, blue))
        guard delta > 0 else {
            return AccountColorComponents(hue: 0, saturation: 0, brightness: brightness)
        }

        let rawHue: Double
        if brightness == red {
            rawHue = (green - blue) / delta
        } else if brightness == green {
            rawHue = 2 + (blue - red) / delta
        } else {
            rawHue = 4 + (red - green) / delta
        }
        return AccountColorComponents(
            hue: (rawHue / 6 + 1).truncatingRemainder(dividingBy: 1),
            saturation: delta / brightness,
            brightness: brightness
        )
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        })
    }
}
