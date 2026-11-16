import SwiftUI

/// Islet's color themes (Settings → Appearance). Each is three related colors: the first
/// tints controls, and all three make the gradients in Portal, Standby and the sidebar.
enum AccentTheme: String, CaseIterable, Identifiable {
    case aurora, ocean, mint, sunset, candy, ember, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .mint: "Mint"
        case .sunset: "Sunset"
        case .candy: "Candy"
        case .ember: "Ember"
        case .mono: "Mono"
        }
    }

    var colors: [Color] {
        switch self {
        case .aurora: [Color(red: 0.62, green: 0.42, blue: 1), Color(red: 0.25, green: 0.8, blue: 1), Color(red: 1, green: 0.42, blue: 0.75)]
        case .ocean: [Color(red: 0.2, green: 0.52, blue: 1), Color(red: 0.2, green: 0.86, blue: 0.95), Color(red: 0.45, green: 0.4, blue: 1)]
        case .mint: [Color(red: 0.2, green: 0.82, blue: 0.62), Color(red: 0.56, green: 0.95, blue: 0.5), Color(red: 0.2, green: 0.7, blue: 0.9)]
        case .sunset: [Color(red: 1, green: 0.5, blue: 0.25), Color(red: 1, green: 0.78, blue: 0.3), Color(red: 1, green: 0.35, blue: 0.5)]
        case .candy: [Color(red: 1, green: 0.4, blue: 0.68), Color(red: 1, green: 0.7, blue: 0.55), Color(red: 0.7, green: 0.5, blue: 1)]
        case .ember: [Color(red: 1, green: 0.27, blue: 0.27), Color(red: 1, green: 0.55, blue: 0.2), Color(red: 0.85, green: 0.2, blue: 0.45)]
        case .mono: [Color(white: 0.92), Color(white: 0.62), Color(white: 0.78)]
        }
    }

    /// Tints toggles, sliders, selections and buttons.
    var tint: Color { self == .mono ? Color(white: 0.55) : colors[0] }

    /// A soft diagonal blend of the three colors.
    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The colors round a ring, ending where they started so the seam doesn't show.
    var ring: AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center)
    }
}

/// A row of round swatches; the chosen one wears a ring that springs between them.
struct ThemePicker: View {
    @Binding var selection: AccentTheme
    @Namespace private var ring
    @State private var hovered: AccentTheme?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentTheme.allCases) { theme in
                let chosen = selection == theme
                Button {
                    withAnimation(IslandMotion.playful) { selection = theme }
                } label: {
                    Circle()
                        .fill(theme.gradient)
                        .frame(width: 22, height: 22)
                        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                        .padding(3)
                        .background {
                            if chosen {
                                Circle().strokeBorder(theme.tint, lineWidth: 2)
                                    .matchedGeometryEffect(id: "ring", in: ring)
                            }
                        }
                        .scaleEffect(hovered == theme ? 1.12 : 1)
                        .animation(IslandMotion.quick, value: hovered)
                }
                .buttonStyle(.plain)
                .help(theme.title)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .onHover { hovered = $0 ? theme : (hovered == theme ? nil : hovered) }
            }
        }
    }
}

extension EnvironmentValues {
    /// The colors Portal's effects draw with (Settings → Portal, or the Appearance theme).
    @Entry var portalTheme: AccentTheme = .aurora
    /// Settings → Appearance, for surfaces outside the Settings window.
    @Entry var accentTheme: AccentTheme = .aurora
}

/// Hands Portal's colors to views hosted outside the island, and follows the setting live.
struct PortalThemed<Content: View>: View {
    let settings: AppSettings?
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.portalTheme, settings?.portalColors ?? .aurora)
    }
}
