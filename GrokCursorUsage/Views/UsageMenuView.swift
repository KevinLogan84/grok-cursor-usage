import SwiftUI

private enum MenuTab: String, CaseIterable, Identifiable {
    case usage
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: "Usage"
        case .settings: "Settings"
        }
    }
}

struct UsageMenuView: View {
    @Bindable var quotas: QuotaMonitor
    @Bindable var launchAtLogin: LaunchAtLoginManager
    @Bindable var appearance: AppearancePreferenceStore
    @Bindable var notifier: QuotaAlertNotifier
    var onShowGuide: () -> Void
    var onLayout: () -> Void = {}

    @State private var tab: MenuTab = .usage

    private var scale: Double { appearance.interfaceScale }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuMetrics.points(12, scale: scale)) {
            header
            Picker("Section", selection: $tab) {
                ForEach(MenuTab.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(MenuMetrics.font(14, scale: scale, weight: .semibold))
            .accessibilityLabel("Section")

            switch tab {
            case .usage:
                quotaCard
            case .settings:
                settings
            }
        }
        .padding(MenuMetrics.points(14, scale: scale))
        .frame(width: MenuMetrics.width(for: scale))
        .liquidGlassBackground(menuShell: true, scheme: appearance.resolvedScheme)
        .environment(\.menuScale, scale)
        .task {
            await notifier.refreshAuthorizationStatus()
        }
        .onChange(of: tab) { _, _ in onLayout() }
        .onChange(of: appearance.interfaceScale) { _, _ in onLayout() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MenuMetrics.points(2, scale: scale)) {
                Text("Grok & Cursor Usage")
                    .font(MenuMetrics.font(20, scale: scale, weight: .semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(updatedLabel)
                    .font(MenuMetrics.font(13, scale: scale))
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: MenuMetrics.points(8, scale: scale))
            if quotas.isRefreshing {
                ProgressView()
                    .controlSize(.regular)
            }
            Button("Refresh") {
                Task { await quotas.refresh() }
            }
            .glassPlainButton(compact: true)
            .keyboardShortcut("r")
            .disabled(quotas.isRefreshing)
            .accessibilityHint("Reads Cursor and Grok usage again")
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .glassPlainButton(compact: true)
        }
    }

    private var quotaCard: some View {
        GlassPanel(padding: MenuMetrics.points(16, scale: scale)) {
            VStack(alignment: .leading, spacing: MenuMetrics.points(16, scale: scale)) {
                Text("Subscription Usage")
                    .font(MenuMetrics.font(18, scale: scale, weight: .semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                if quotas.bars.isEmpty {
                    Text(quotas.isRefreshing ? "Checking which plans are on this Mac…" : "No usage pools found")
                        .font(MenuMetrics.font(14, scale: scale))
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
        VStack(alignment: .leading, spacing: MenuMetrics.points(4, scale: scale)) {
            HStack(alignment: .bottom, spacing: MenuMetrics.points(8, scale: scale)) {
                VStack(alignment: .leading, spacing: MenuMetrics.points(2, scale: scale)) {
                    Text(bar.title)
                        .font(MenuMetrics.font(16, scale: scale, weight: .semibold))
                        .foregroundStyle(LiquidGlass.textPrimary)
                    if !bar.subtitle.isEmpty {
                        Text(bar.subtitle)
                            .font(MenuMetrics.font(13, scale: scale))
                            .foregroundStyle(LiquidGlass.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer(minLength: MenuMetrics.points(6, scale: scale))
                VStack(alignment: .trailing, spacing: MenuMetrics.points(2, scale: scale)) {
                    Text(bar.usedText)
                        .font(MenuMetrics.font(16, scale: scale, weight: .semibold, monospaced: true))
                        .foregroundStyle(LiquidGlass.textPrimary)
                        .lineLimit(1)
                    if let pace = bar.pace {
                        Text(pace.text)
                            .font(MenuMetrics.font(14, scale: scale, weight: .semibold, monospaced: true))
                            .foregroundStyle(paceColor(pace))
                            .lineLimit(1)
                    }
                }
            }
            if bar.state == .ready {
                QuotaMeterBar(fill: bar.usedFraction, color: usageBandColor(bar.usedFraction))
                    .frame(height: MenuMetrics.points(10, scale: scale))
            }
            if !bar.detail.isEmpty {
                Text(bar.detail)
                    .font(MenuMetrics.font(13, scale: scale))
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quotaAccessibility(bar))
    }

    private var settings: some View {
        GlassPanel(padding: MenuMetrics.points(16, scale: scale)) {
            VStack(alignment: .leading, spacing: MenuMetrics.points(16, scale: scale)) {
                VStack(alignment: .leading, spacing: MenuMetrics.points(6, scale: scale)) {
                    HStack {
                        Text("Text Size")
                            .font(MenuMetrics.font(16, scale: scale, weight: .semibold))
                            .foregroundStyle(LiquidGlass.textPrimary)
                        Spacer()
                        Text("\(sizePercent)%")
                            .font(MenuMetrics.font(14, scale: scale, weight: .semibold, monospaced: true))
                            .foregroundStyle(LiquidGlass.textSecondary)
                            .accessibilityHidden(true)
                        if abs(scale - MenuMetrics.defaultScale) > 0.001 {
                            Button("Reset") {
                                appearance.interfaceScale = MenuMetrics.defaultScale
                            }
                            .font(MenuMetrics.font(14, scale: scale))
                            .buttonStyle(.borderless)
                            .accessibilityHint("Returns text to the default size")
                        }
                    }
                    Slider(
                        value: sizePercentBinding,
                        in: MenuMetrics.minimumPercent...MenuMetrics.maximumPercent,
                        step: MenuMetrics.percentStep
                    ) {
                        Text("Text Size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                            .accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                            .accessibilityHidden(true)
                    }
                    .labelsHidden()
                    .accessibilityValue("\(sizePercent) percent")
                    Text("Scales the text and the whole menu.")
                        .font(MenuMetrics.font(13, scale: scale))
                        .foregroundStyle(LiquidGlass.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: MenuMetrics.points(6, scale: scale)) {
                    Text("Appearance")
                        .font(MenuMetrics.font(16, scale: scale, weight: .semibold))
                        .foregroundStyle(LiquidGlass.textPrimary)
                    AppearancePicker(preference: $appearance.preference)
                    Text("System follows this Mac. Light or Dark keeps the menu that way.")
                        .font(MenuMetrics.font(13, scale: scale))
                        .foregroundStyle(LiquidGlass.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Open at Login", isOn: launchAtLoginBinding)
                    .font(MenuMetrics.font(16, scale: scale))
                VStack(alignment: .leading, spacing: MenuMetrics.points(4, scale: scale)) {
                    Toggle("Spike Alerts", isOn: $notifier.alertsEnabled)
                        .font(MenuMetrics.font(16, scale: scale))
                        .onChange(of: notifier.alertsEnabled) { _, enabled in
                            guard enabled else { return }
                            Task { await notifier.requestAuthorizationIfNeeded() }
                        }
                    Text("Notifies you once a day when a pool climbs \(QuotaBurnEvaluator.dailyPercentText) or more since your first reading that day.")
                        .font(MenuMetrics.font(13, scale: scale))
                        .foregroundStyle(LiquidGlass.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if notifier.authorization == .denied {
                    Button("Open Notification Settings") {
                        QuotaAlertNotifier.openNotificationSettings()
                    }
                    .font(MenuMetrics.font(14, scale: scale))
                    .buttonStyle(.borderless)
                }
                Text("Uses the Cursor and Grok sign-ins already on this Mac. Usage is requested only from Cursor and xAI. The latest numbers sync through your iCloud for the iPhone app.")
                    .font(MenuMetrics.font(13, scale: scale))
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Guide", action: onShowGuide)
                        .glassPlainButton(compact: true)
                    Spacer(minLength: MenuMetrics.points(8, scale: scale))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sizePercent: Int {
        Int(MenuMetrics.percent(for: scale).rounded())
    }

    private var sizePercentBinding: Binding<Double> {
        Binding(
            get: { MenuMetrics.percent(for: appearance.interfaceScale) },
            set: { appearance.interfaceScale = MenuMetrics.scale(forPercent: $0) }
        )
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
