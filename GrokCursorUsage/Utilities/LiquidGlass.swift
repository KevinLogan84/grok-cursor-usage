import AppKit
import SwiftUI

/// Visual tokens for Liquid Glass. Materials stay; washes and rims follow
/// the current color scheme so Light is readable.
enum LiquidGlass {
    static let cornerLarge: CGFloat = 20
    static let cornerMedium: CGFloat = 14
    static let cornerSmall: CGFloat = 10
    /// Outer shell radius for the menu-bar dropdown (continuous, Apple-style).
    static let menuShellCorner: CGFloat = 16

    /// Follows System Settings → Appearance accent.
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.85)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    static func rim(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    .white.opacity(0.34),
                    .white.opacity(0.10),
                    .black.opacity(0.22)
                ]
                : [
                    .white.opacity(0.72),
                    .white.opacity(0.28),
                    .black.opacity(0.10)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func panelSheen(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    .white.opacity(0.10),
                    .white.opacity(0.03),
                    .clear
                ]
                : [
                    .white.opacity(0.42),
                    .white.opacity(0.10),
                    .clear
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func elevationShadowOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.35 : 0.12
    }

    @MainActor
    static func applyChrome(to window: NSWindow, appearance: NSAppearance? = nil) {
        window.appearance = appearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @MainActor
    static func applyChrome(to popover: NSPopover, appearance: NSAppearance? = nil) {
        popover.appearance = appearance
        popover.animates = true
    }
}

struct LiquidGlassWash: View {
    var colorScheme: ColorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color.white.opacity(0.06),
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.28)
                    ]
                    : [
                        Color.white.opacity(0.50),
                        Color.black.opacity(0.03),
                        Color.black.opacity(0.07)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.40),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 6,
                endRadius: 240
            )
        }
    }
}

struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = LiquidGlass.cornerMedium
    var padding: CGFloat = 8
    var elevated: Bool = true
    var fillWidth: Bool = true
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                content()
                    .frame(
                        maxWidth: fillWidth ? .infinity : nil,
                        maxHeight: fillHeight ? .infinity : nil,
                        alignment: .leading
                    )
                    .padding(padding)
                    .background(Color(nsColor: .controlBackgroundColor), in: shape)
            } else if #available(macOS 26, *) {
                content()
                    .frame(
                        maxWidth: fillWidth ? .infinity : nil,
                        maxHeight: fillHeight ? .infinity : nil,
                        alignment: .leading
                    )
                    .padding(padding)
                    .glassEffect(.regular, in: shape)
            } else {
                content()
                    .frame(
                        maxWidth: fillWidth ? .infinity : nil,
                        maxHeight: fillHeight ? .infinity : nil,
                        alignment: .leading
                    )
                    .padding(padding)
                    .background {
                        shape.fill(.regularMaterial)
                            .overlay { shape.fill(LiquidGlass.panelSheen(for: colorScheme)) }
                            .overlay { shape.strokeBorder(LiquidGlass.rim(for: colorScheme), lineWidth: 1) }
                            .shadow(
                                color: elevated
                                    ? .black.opacity(LiquidGlass.elevationShadowOpacity(for: colorScheme))
                                    : .clear,
                                radius: elevated ? 10 : 0,
                                y: elevated ? 4 : 0
                            )
                    }
            }
        }
    }
}

struct GlassChip<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        if reduceTransparency {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.tertiary, in: Capsule())
        } else if #available(macOS 26, *) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
        } else {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay {
                            Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                        }
                        .overlay { Capsule().strokeBorder(LiquidGlass.rim(for: colorScheme), lineWidth: 0.8) }
                        .shadow(
                            color: .black.opacity(LiquidGlass.elevationShadowOpacity(for: colorScheme) * 0.65),
                            radius: 3,
                            y: 1
                        )
                }
        }
    }
}

struct GlassProminentButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        GlassProminentButtonBody(configuration: configuration, compact: compact)
    }
}

private struct GlassProminentButtonBody: View {
    @Environment(\.menuScale) private var menuScale
    let configuration: ButtonStyleConfiguration
    let compact: Bool

    var body: some View {
        configuration.label
            .font(MenuMetrics.font(compact ? 13 : 14, scale: menuScale, weight: .semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, MenuMetrics.points(compact ? 10 : 14, scale: menuScale))
            .padding(.vertical, MenuMetrics.points(compact ? 7 : 8, scale: menuScale))
            .background {
                Capsule()
                    .fill(LiquidGlass.accent.opacity(configuration.isPressed ? 0.82 : 1))
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
                    }
                    .shadow(
                        color: .black.opacity(0.28),
                        radius: configuration.isPressed ? 2 : 6,
                        y: 2
                    )
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassPlainButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        GlassPlainButtonBody(configuration: configuration, compact: compact)
    }
}

private struct GlassPlainButtonBody: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.menuScale) private var menuScale
    let configuration: ButtonStyleConfiguration
    let compact: Bool

    var body: some View {
        let label = configuration.label
            .font(MenuMetrics.font(compact ? 13 : 14, scale: menuScale, weight: .medium))
            .foregroundStyle(LiquidGlass.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, MenuMetrics.points(compact ? 10 : 14, scale: menuScale))
            .padding(.vertical, MenuMetrics.points(compact ? 7 : 8, scale: menuScale))

        Group {
            if reduceTransparency {
                label.background(.fill.tertiary, in: Capsule())
            } else if #available(macOS 26, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label.background {
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay {
                            Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.05))
                        }
                        .overlay {
                            Capsule().strokeBorder(LiquidGlass.rim(for: colorScheme), lineWidth: 1)
                        }
                        .shadow(
                            color: .black.opacity(LiquidGlass.elevationShadowOpacity(for: colorScheme) * 0.65),
                            radius: 3,
                            y: 1
                        )
                }
            }
        }
        .contentShape(Capsule())
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var clippedToMenuShell: Bool = false
    var scheme: ColorScheme

    func body(content: Content) -> some View {
        let themed = content
            .preferredColorScheme(scheme)
            .tint(LiquidGlass.accent)

        if clippedToMenuShell {
            let shape = RoundedRectangle(cornerRadius: LiquidGlass.menuShellCorner, style: .continuous)
            if reduceTransparency {
                themed
                    .background(Color(nsColor: .controlBackgroundColor), in: shape)
                    .clipShape(shape)
            } else if #available(macOS 26, *) {
                themed
                    .glassEffect(.regular, in: shape)
            } else {
                themed
                    .background {
                        shape.fill(.regularMaterial)
                        shape.fill(shellWash)
                    }
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(LiquidGlass.rim(for: scheme), lineWidth: 1)
                    }
            }
        } else {
            themed
                .background {
                    LiquidGlassWash(colorScheme: scheme)
                        .ignoresSafeArea()
                }
        }
    }

    private var shellWash: LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [
                    Color.white.opacity(0.07),
                    Color.black.opacity(0.22)
                ]
                : [
                    Color.white.opacity(0.45),
                    Color.black.opacity(0.05)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    func liquidGlassBackground(
        menuShell: Bool = false,
        scheme: ColorScheme
    ) -> some View {
        modifier(GlassBackground(clippedToMenuShell: menuShell, scheme: scheme))
    }

    func glassProminentButton(compact: Bool = false) -> some View {
        self
            .buttonStyle(GlassProminentButtonStyle(compact: compact))
            .buttonBorderShape(.capsule)
            .focusEffectDisabled()
    }

    func glassPlainButton(compact: Bool = false) -> some View {
        self
            .buttonStyle(GlassPlainButtonStyle(compact: compact))
            .buttonBorderShape(.capsule)
            .focusEffectDisabled()
    }

    func hotspotCardChrome(cornerRadius: CGFloat = LiquidGlass.cornerSmall) -> some View {
        modifier(HotspotCardChrome(cornerRadius: cornerRadius))
    }
}

private struct HotspotCardChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(LiquidGlass.panelSheen(for: colorScheme)) }
                    .overlay { shape.strokeBorder(LiquidGlass.rim(for: colorScheme), lineWidth: 1) }
            }
        }
    }
}
