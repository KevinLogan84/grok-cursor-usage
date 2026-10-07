import SwiftUI

enum MenuLayout {
    static let width: CGFloat = 360
}

struct UsageMenuView: View {
    @Bindable var quotas: QuotaMonitor
    @Bindable var launchAtLogin: LaunchAtLoginManager
    @Bindable var appearance: AppearancePreferenceStore
    @Bindable var notifier: QuotaAlertNotifier
    var onShowGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quotaCard
            controls
        }
        .padding(12)
        .frame(width: MenuLayout.width)
        .liquidGlassBackground(menuShell: true, preference: appearance.preference)
        .task {
            await notifier.refreshAuthorizationStatus()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Grok & Cursor Usage")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(updatedLabel)
                    .font(.caption)
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if quotas.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") {
                Task { await quotas.refresh() }
            }
            .glassPlainButton(compact: true)
            .keyboardShortcut("r")
            .disabled(quotas.isRefreshing)
            .accessibilityHint("Reads Cursor and Grok usage again")
        }
    }

    private var quotaCard: some View {
        GlassPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Subscription Usage")
                    .font(.headline)
                    .foregroundStyle(LiquidGlass.textPrimary)
                if quotas.bars.isEmpty {
                    Text(quotas.isRefreshing ? "Checking which plans are on this Mac…" : "No usage pools found")
                        .font(.caption)
                        .foregroundStyle(LiquidGlass.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(quotas.bars) { bar in
                        quotaRow(bar)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quotaRow(_ bar: QuotaBar) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bar.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LiquidGlass.textPrimary)
                    if !bar.subtitle.isEmpty {
                        Text(bar.subtitle)
                            .font(.caption2)
                            .foregroundStyle(LiquidGlass.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(bar.usedText)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(LiquidGlass.textPrimary)
                        .lineLimit(1)
                    if let pace = bar.pace {
                        Text(pace.text)
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(paceColor(pace))
                            .lineLimit(1)
                    }
                }
            }
            if bar.state == .ready {
                QuotaMeterBar(fill: bar.usedFraction, color: usageBandColor(bar.usedFraction))
                    .frame(height: 8)
            }
            if !bar.detail.isEmpty {
                Text(bar.detail)
                    .font(.caption2)
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quotaAccessibility(bar))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Open at Login", isOn: launchAtLoginBinding)
                .font(.callout)
            Toggle("Spike alerts", isOn: $notifier.alertsEnabled)
                .font(.callout)
                .onChange(of: notifier.alertsEnabled) { _, enabled in
                    guard enabled else { return }
                    Task { await notifier.requestAuthorizationIfNeeded() }
                }
            if notifier.authorization == .denied {
                Button("Open Notification Settings") {
                    QuotaAlertNotifier.openNotificationSettings()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            Text("Reads the Cursor and Grok sign-in already on this Mac. The iPhone app shows this card from iCloud.")
                .font(.caption2)
                .foregroundStyle(LiquidGlass.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Guide", action: onShowGuide)
                    .glassPlainButton(compact: true)
                Spacer(minLength: 8)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
                .glassPlainButton(compact: true)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var updatedLabel: String {
        if quotas.isRefreshing, quotas.lastUpdated == nil {
            return "Reading usage…"
        }
        guard let date = quotas.lastUpdated else { return "Waiting for the first read" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: date, relativeTo: .now))"
    }

    private func quotaAccessibility(_ bar: QuotaBar) -> String {
        if bar.state != .ready {
            return "\(bar.title), \(bar.detail)"
        }
        if let pace = bar.pace {
            return "\(bar.title) \(bar.usedText), \(pace.text)"
        }
        return "\(bar.title) \(bar.usedText)"
    }
}

struct QuotaMeterBar: View {
    let fill: Double
    var color: Color = LiquidGlass.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LiquidGlass.textSecondary.opacity(0.25))
                Capsule()
                    .fill(color)
                    .frame(width: max(fill > 0 ? 4 : 0, geo.size.width * min(1, max(0, fill))))
            }
        }
        .accessibilityHidden(true)
    }
}

func usageBandColor(_ usedFraction: Double) -> Color {
    let percent = usedFraction * 100
    if percent < 40 { return Color(nsColor: .systemGreen) }
    if percent < 80 { return Color(nsColor: .systemOrange) }
    return Color(nsColor: .systemRed)
}

func paceColor(_ pace: QuotaPace) -> Color {
    switch pace {
    case .over: return Color(nsColor: .systemOrange)
    case .under: return Color(nsColor: .systemGreen)
    case .onPace: return LiquidGlass.textPrimary
    }
}
