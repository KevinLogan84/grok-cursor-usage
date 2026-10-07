import SwiftUI

enum IOSGlass {
    static let cardCorner: CGFloat = 22
    static let stackSpacing: CGFloat = 14
    static let screenTopPadding: CGFloat = 10
    static let screenBottomPadding: CGFloat = 12
    static let screenHorizontalPadding: CGFloat = 16
    static let headerSpacing: CGFloat = 8
    static let titleStampSpacing: CGFloat = 4
    static let cardPadding: CGFloat = 15
    static let subscriptionRowSpacing: CGFloat = 12
    static let quotaRowSpacing: CGFloat = 3
    static let meterHeight: CGFloat = 8
    static let portraitChromeFallback: CGFloat = 102

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
    }
}

struct ViewerBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12),
                    Color.clear
                ],
                center: UnitPoint(x: 0.86, y: 0.06),
                startRadius: 4,
                endRadius: 340
            )
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.06),
                    Color.clear
                ],
                center: UnitPoint(x: 0.14, y: 0.78),
                startRadius: 8,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

struct ViewerGlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var padding: CGFloat = IOSGlass.cardPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = IOSGlass.cardShape
        let padded = content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)

        if reduceTransparency {
            padded.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        } else {
            padded.glassEffect(.regular, in: shape)
        }
    }
}
