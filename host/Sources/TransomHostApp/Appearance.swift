import AppKit
import SwiftUI

/// The accent color: one of the presets, or a custom color stored as `#RRGGBB`.
///
/// Stored as a string under `HostDefaults.accentColor` so it round-trips through
/// `@AppStorage` and every window (main, Settings, menu bar) reads the same value.
enum AccentChoice {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    static let defaultID = "blue"

    static let presets: [Preset] = [
        Preset(id: "blue", name: "Blue", color: Color(red: 0.15, green: 0.36, blue: 0.86)),
        Preset(id: "indigo", name: "Indigo", color: Color(red: 0.35, green: 0.30, blue: 0.85)),
        Preset(id: "purple", name: "Purple", color: Color(red: 0.58, green: 0.30, blue: 0.82)),
        Preset(id: "pink", name: "Pink", color: Color(red: 0.90, green: 0.26, blue: 0.55)),
        Preset(id: "red", name: "Red", color: Color(red: 0.86, green: 0.22, blue: 0.22)),
        Preset(id: "orange", name: "Orange", color: Color(red: 0.95, green: 0.50, blue: 0.10)),
        Preset(id: "yellow", name: "Yellow", color: Color(red: 0.88, green: 0.68, blue: 0.05)),
        Preset(id: "green", name: "Green", color: Color(red: 0.18, green: 0.62, blue: 0.32)),
        Preset(id: "teal", name: "Teal", color: Color(red: 0.08, green: 0.58, blue: 0.62)),
        Preset(id: "graphite", name: "Graphite", color: Color(red: 0.45, green: 0.47, blue: 0.50)),
    ]

    static func color(for id: String) -> Color {
        if let preset = presets.first(where: { $0.id == id }) { return preset.color }
        return color(hex: id) ?? presets[0].color
    }

    static func isCustom(_ id: String) -> Bool { !presets.contains { $0.id == id } }

    static func hex(for color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent),
            byte(ns.blueComponent))
    }

    static func color(hex: String) -> Color? {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16)
        else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// Light, dark, or follow the system. Applied app-wide through `NSApp.appearance`
/// so the Settings window and the menu bar panel follow it too.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor static func apply(_ raw: String) {
        switch AppTheme(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// How large the app and window cards are in the main window.
enum CardSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .large: "Large"
        }
    }

    var appCardMinWidth: CGFloat {
        switch self {
        case .compact: 140
        case .regular: 180
        case .large: 230
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: 32
        case .regular: 44
        case .large: 60
        }
    }

    var windowCardMinWidth: CGFloat {
        switch self {
        case .compact: 180
        case .regular: 240
        case .large: 320
        }
    }

    var thumbnailHeight: CGFloat {
        switch self {
        case .compact: 120
        case .regular: 170
        case .large: 230
        }
    }

    var padding: CGFloat {
        switch self {
        case .compact: 12
        case .regular: 18
        case .large: 22
        }
    }
}

/// The menu bar icon. Each symbol has a filled variant, shown while sharing, so
/// the state reads at a glance in a monochrome menu bar.
enum MenuBarSymbol {
    static let defaultSymbol = "rectangle.on.rectangle"

    static let choices: [(symbol: String, name: String)] = [
        ("rectangle.on.rectangle", "Windows"),
        ("square.on.square", "Squares"),
        ("rectangle.3.group", "Grid"),
        ("pip", "Picture in Picture"),
        ("play.rectangle", "Stream"),
        ("tv", "Screen"),
    ]
}

// MARK: - Settings tab

struct AppearanceSettings: View {
    @AppStorage(HostDefaults.accentColor) private var accentID = AccentChoice.defaultID
    @AppStorage(HostDefaults.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(HostDefaults.cardSize) private var cardSize = CardSize.regular.rawValue
    @AppStorage(HostDefaults.menuBarSymbol) private var menuBarSymbol = MenuBarSymbol.defaultSymbol
    @AppStorage(HostDefaults.menuBarShowsCount) private var menuBarShowsCount = true
    @AppStorage(HostDefaults.showSidebar) private var showSidebar = true
    @AppStorage(HostDefaults.tintSidebar) private var tintSidebar = false
    @AppStorage(HostDefaults.showThumbnails) private var showThumbnails = true
    @AppStorage(HostDefaults.showMenuBarIcon) private var showMenuBarIcon = true

    private var customColor: Binding<Color> {
        Binding(
            get: { AccentChoice.color(for: accentID) },
            set: { accentID = AccentChoice.hex(for: $0) })
    }

    var body: some View {
        Form {
            Section("Color") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, raw in AppTheme.apply(raw) }
                LabeledContent("Accent") {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.presets) { preset in
                            swatch(preset)
                        }
                        ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                            .labelsHidden()
                            .help("Pick a custom accent color")
                            .overlay {
                                if AccentChoice.isCustom(accentID) {
                                    Circle().stroke(Color.primary, lineWidth: 2)
                                        .frame(width: 26, height: 26).allowsHitTesting(false)
                                }
                            }
                    }
                }
                Toggle("Tint the sidebar with the accent color", isOn: $tintSidebar)
                    .disabled(!showSidebar)
            }
            Section("Main window") {
                Picker("Card size", selection: $cardSize) {
                    ForEach(CardSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Show the sidebar", isOn: $showSidebar)
                Toggle("Show live previews of shared windows", isOn: $showThumbnails)
            }
            Section("Menu bar") {
                Picker("Icon", selection: $menuBarSymbol) {
                    ForEach(MenuBarSymbol.choices, id: \.symbol) { choice in
                        Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
                    }
                }
                Toggle("Show the number of shared windows next to the icon", isOn: $menuBarShowsCount)
            }
            .disabled(!showMenuBarIcon)
        }
        .formStyle(.grouped)
    }

    private func swatch(_ preset: AccentChoice.Preset) -> some View {
        let selected = accentID == preset.id
        return Button {
            accentID = preset.id
        } label: {
            Circle().fill(preset.color)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
