import AppKit
import SwiftUI

struct ReleaseNotesView: View {
    var appearance: AppearancePreferenceStore
    var notice: AppUpdateNotice
    var onClose: () -> Void

    private var scale: Double { appearance.interfaceScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What’s new in \(notice.versionLabel)")
                    .font(MenuMetrics.font(22, scale: scale, weight: .semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .glassPlainButton(compact: true)
            }
            .padding(.horizontal, MenuMetrics.points(20, scale: scale))
            .padding(.top, MenuMetrics.points(18, scale: scale))
            .padding(.bottom, MenuMetrics.points(8, scale: scale))

            ScrollView {
                Text(renderedNotes)
                    .font(MenuMetrics.font(15, scale: scale))
                    .foregroundStyle(LiquidGlass.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, MenuMetrics.points(20, scale: scale))
                    .padding(.bottom, MenuMetrics.points(12, scale: scale))
            }

            VStack(alignment: .leading, spacing: MenuMetrics.points(8, scale: scale)) {
                Button("Download") {
                    NSWorkspace.shared.open(notice.downloadURL)
                }
                .glassProminentButton(compact: true)
                .accessibilityHint("Opens the download in your browser. The app does not install it.")
                Text("Opens the new copy. Quit the app, then replace Grok & Cursor Usage.app in /Applications. The app does not install it for you.")
                    .font(MenuMetrics.font(13, scale: scale))
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MenuMetrics.points(20, scale: scale))
            .padding(.bottom, MenuMetrics.points(18, scale: scale))
        }
        .frame(
            minWidth: MenuMetrics.points(440, scale: scale),
            minHeight: MenuMetrics.points(420, scale: scale)
        )
        .environment(\.menuScale, scale)
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                return .discarded
            }
            NSWorkspace.shared.open(url)
            return .handled
        })
        .liquidGlassBackground(scheme: appearance.resolvedScheme)
    }

    private var renderedNotes: AttributedString {
        let trimmed = notice.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "This release did not include notes." : notice.notes
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: source, options: options), !parsed.characters.isEmpty {
            return parsed
        }
        return AttributedString(stringLiteral: source)
    }
}
