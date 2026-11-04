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
    @Bindable var grokSource: GrokSignInSourceStore
    @Bindable var updates: AppUpdateChecker
    var onShowGuide: () -> Void
    var onShowUpdate: () -> Void
    var onLayout: () -> Void = {}

    @State private var tab: MenuTab = .usage

    private var scale: Double { appearance.interfaceScale }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuMetrics.points(12, scale: scale)) {
            header
            if let notice = updates.notice {
                updateBanner(notice)
            }
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
        .onChange(of: updates.notice) { _, _ in onLayout() }
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
                Task { await quotas.refresh(userInitiated: true) }
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
        UltraUsageCard(
            bars: quotas.bars,
            poolShares: quotas.poolShares,
            scale: scale,
            isRefreshing: quotas.isRefreshing
        )
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

                VStack(alignment: .leading, spacing: MenuMetrics.points(6, scale: scale)) {
                    Text("Grok Sign-In")
                        .font(MenuMetrics.font(16, scale: scale, weight: .semibold))
                        .foregroundStyle(LiquidGlass.textPrimary)
                    Picker("Grok Sign-In", selection: $grokSource.source) {
                        ForEach(GrokSignInSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .font(MenuMetrics.font(14, scale: scale))
                    Text(grokSourceHint)
                        .font(MenuMetrics.font(13, scale: scale))
                        .foregroundStyle(LiquidGlass.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if grokSource.source.usesGrokApp {
                        Button("Open Full Disk Access Settings") {
                            Self.openFullDiskAccessSettings()
                        }
                        .font(MenuMetrics.font(14, scale: scale))
                        .buttonStyle(.borderless)
                    }
                }
                .onChange(of: grokSource.source) { _, _ in
                    Task { await quotas.refresh() }
                }

                Toggle("Open at Login", isOn: launchAtLoginBinding)
                    .font(MenuMetrics.font(16, scale: scale))
                VStack(alignment: .leading, spacing: MenuMetrics.points(8, scale: scale)) {
                    Toggle("Spike Alerts", isOn: $notifier.alertsEnabled)
                        .font(MenuMetrics.font(16, scale: scale))
                        .onChange(of: notifier.alertsEnabled) { _, enabled in
                            guard enabled else { return }
                            Task { await notifier.requestAuthorizationIfNeeded() }
                        }
                    if notifier.alertsEnabled {
                        Picker("Notify", selection: $notifier.repeatMode) {
                            ForEach(SpikeAlertRepeat.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .font(MenuMetrics.font(14, scale: scale))
                        .accessibilityLabel("Notify")
                        VStack(alignment: .leading, spacing: MenuMetrics.points(6, scale: scale)) {
                            HStack {
                                Text("Amount")
                                    .font(MenuMetrics.font(16, scale: scale, weight: .semibold))
                                    .foregroundStyle(LiquidGlass.textPrimary)
                                Spacer()
                                Text("\(notifier.stepPercent)%")
                                    .font(MenuMetrics.font(14, scale: scale, weight: .semibold, monospaced: true))
                                    .foregroundStyle(LiquidGlass.textSecondary)
                                    .accessibilityHidden(true)
                            }
                            Slider(
                                value: stepPercentBinding,
                                in: Double(QuotaBurnEvaluator.minimumPercent)...Double(QuotaBurnEvaluator.maximumPercent),
                                step: Double(QuotaBurnEvaluator.percentStep)
                            ) {
                                Text("Amount")
                            } minimumValueLabel: {
                                Text("\(QuotaBurnEvaluator.minimumPercent)%")
                                    .font(MenuMetrics.font(12, scale: scale))
                                    .foregroundStyle(LiquidGlass.textSecondary)
                            } maximumValueLabel: {
                                Text("\(QuotaBurnEvaluator.maximumPercent)%")
                                    .font(MenuMetrics.font(12, scale: scale))
                                    .foregroundStyle(LiquidGlass.textSecondary)
                            }
                            .labelsHidden()
                            .accessibilityValue("\(notifier.stepPercent) percent")
                        }
                        Text(notifier.spikeHint)
                            .font(MenuMetrics.font(13, scale: scale))
                            .foregroundStyle(LiquidGlass.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    SendFeedbackButton()
                        .glassPlainButton(compact: true)
                }
                Text("Send Feedback opens a mail draft. If this Mac’s default email app is a browser, the address is shown so you can copy it. Nothing is sent until you send it.")
                    .font(MenuMetrics.font(13, scale: scale))
                    .foregroundStyle(LiquidGlass.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func updateBanner(_ notice: AppUpdateNotice) -> some View {
        HStack(alignment: .center, spacing: MenuMetrics.points(8, scale: scale)) {
            VStack(alignment: .leading, spacing: MenuMetrics.points(2, scale: scale)) {
                Text("Update available")
                    .font(MenuMetrics.font(14, scale: scale, weight: .semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                Text("\(notice.versionLabel) is ready.")
                    .font(MenuMetrics.font(13, scale: scale))
                    .foregroundStyle(LiquidGlass.textSecondary)
            }
            Spacer(minLength: MenuMetrics.points(8, scale: scale))
            Button("Update", action: onShowUpdate)
                .glassPlainButton(compact: true)
                .accessibilityHint("Shows what’s new and where to download it")
        }
    }

    private var grokSourceHint: String {
        switch grokSource.source {
        case .cli:
            "Uses the grok CLI login (run grok login in Terminal). No extra permissions."
        case .cliAndGrokApp:
            "Falls back to Grok.app’s sign-in when the CLI has none. Needs Full Disk Access for Grok & Cursor Usage."
        }
    }

    private static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private var sizePercent: Int {
        Int(MenuMetrics.percent(for: scale).rounded())
    }

    private var stepPercentBinding: Binding<Double> {
        Binding(
            get: { Double(notifier.stepPercent) },
            set: { notifier.stepPercent = Int($0.rounded()) }
        )
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

}

/// One shared weekly bar. The total is the highest ready pool.
private struct UltraUsageCard: View {
    var bars: [QuotaBar]
    var poolShares: [QuotaParsing.PoolShare]
    var scale: Double
    var isRefreshing: Bool
    var now: Date = .now

    /// Blue, yellow, red. Grok is a meter of the same total, not a fourth share.
    private static let segmentOrder: [QuotaKind] = [.grokBot, .cursorModels, .otherModels]
    /// Ready readings that can set the total, including Grok.
    private static let allowanceOrder: [QuotaKind] = [.grokBot, .cursorModels, .otherModels, .superGrok]

    var body: some View {
        GlassPanel(padding: MenuMetrics.points(16, scale: scale)) {
            VStack(alignment: .leading, spacing: MenuMetrics.points(12, scale: scale)) {
                Text("Ultra Usage")
                    .font(MenuMetrics.font(18, scale: scale, weight: .semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if bars.isEmpty {
                    Text(isRefreshing ? "Checking which plans are on this Mac…" : "No usage pools found")
                        .font(MenuMetrics.font(14, scale: scale))
                        .foregroundStyle(LiquidGlass.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    combinedBar
                    if let shares = splitShares {
                        legend(shares)
                    }
                    if !resetLines.isEmpty {
                        VStack(spacing: MenuMetrics.points(2, scale: scale)) {
                            ForEach(resetLines, id: \.self) { line in
                                Text(line)
                                    .font(MenuMetrics.font(14, scale: scale))
                                    .foregroundStyle(LiquidGlass.textPrimary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .accessibilityLabel(line)
                            }
                        }
                    }
                    if !unavailableNotes.isEmpty {
                        VStack(alignment: .leading, spacing: MenuMetrics.points(4, scale: scale)) {
                            ForEach(unavailableNotes, id: \.self) { note in
                                Text(note)
                                    .font(MenuMetrics.font(13, scale: scale))
                                    .foregroundStyle(LiquidGlass.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var readySamples: [(kind: QuotaKind, bar: QuotaBar)] {
        Self.allowanceOrder.compactMap { kind in
            guard let bar = bars.first(where: { $0.kind == kind }), bar.state == .ready else {
                return nil
            }
            return (kind, bar)
        }
    }

    private var combined: (usedPercent: Double, pace: QuotaPace?)? {
        QuotaParsing.combinedAllowance(
            readySamples.map {
                QuotaParsing.AllowanceSample(
                    usedPercent: $0.bar.usedPercent,
                    start: $0.bar.periodStart,
                    end: $0.bar.periodEnd
                )
            },
            now: now
        )
    }

    /// Named shares that add up to the total. Nil when the sources did not
    /// send that split, which is the usual case: one mark at the total.
    private var splitShares: [QuotaParsing.PoolShare]? {
        guard !poolShares.isEmpty else { return nil }
        let ordered = Self.segmentOrder.compactMap { kind in
            poolShares.first { $0.kind == kind }
        }
        guard ordered.count == poolShares.count,
              QuotaParsing.isAdditiveSplit(ordered.map(\.percent), totalPercent: combined?.usedPercent ?? -1)
        else { return nil }
        return ordered
    }

    private var drawnSegments: [SegmentedAllowanceBar.Segment] {
        if let shares = splitShares {
            let fractions = QuotaParsing.sharedPoolTrackFractions(
                totalPercent: combined?.usedPercent,
                shares: shares.map(\.percent)
            )
            return zip(shares, fractions).compactMap { share, fraction in
                guard fraction > 0 else { return nil }
                return SegmentedAllowanceBar.Segment(
                    id: share.kind.rawValue,
                    fraction: fraction,
                    color: segmentColor(share.kind)
                )
            }
        }
        return QuotaParsing.sharedPoolTrackFractions(totalPercent: combined?.usedPercent, shares: nil)
            .enumerated()
            .compactMap { index, fraction in
                guard fraction > 0 else { return nil }
                return SegmentedAllowanceBar.Segment(
                    id: "total-\(index)",
                    fraction: fraction,
                    color: usageFillColor(displayedPercent: displayedTotalPercent)
                )
            }
    }

    private var combinedBar: some View {
        HStack(alignment: .center, spacing: MenuMetrics.points(8, scale: scale)) {
            SegmentedAllowanceBar(
                segments: drawnSegments,
                height: MenuMetrics.points(10, scale: scale)
            )
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            VStack(alignment: .trailing, spacing: MenuMetrics.points(1, scale: scale)) {
                Text(totalUsedText)
                    .font(MenuMetrics.font(18, scale: scale, weight: .semibold, monospaced: true))
                    .foregroundStyle(totalUsageColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let pace = combined?.pace {
                    Text(pace.text)
                        .font(MenuMetrics.font(15, scale: scale, weight: .semibold, monospaced: true))
                        .foregroundStyle(subscriptionPaceColor(pace))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(totalAccessibility)
        }
    }

    private var totalUsedText: String {
        guard combined != nil else { return "—" }
        return "\(displayedTotalPercent)% used"
    }

    private var displayedTotalPercent: Int {
        Int((combined?.usedPercent ?? 0).rounded())
    }

    /// Matches the single bar. The dash stays the current primary color.
    private var totalUsageColor: Color {
        guard combined != nil else { return LiquidGlass.textPrimary }
        return usageFillColor(displayedPercent: displayedTotalPercent)
    }

    private var totalAccessibility: String {
        guard let combined else { return "Ultra usage unavailable" }
        if let pace = combined.pace {
            return "Ultra usage, \(totalUsedText), \(pace.text)"
        }
        return "Ultra usage, \(totalUsedText)"
    }

    /// Ready pools that print as the same Chicago minute share one reset line.
    private var sharedReset: Date? {
        let resets = readySamples.compactMap(\.bar.periodEnd)
        guard resets.count == readySamples.count,
              QuotaParsing.subscriptionResetsShareOneLine(resets) else {
            return nil
        }
        return resets.first
    }

    /// The shared Chicago minute, or each distinct reset when the pools differ.
    private var resetLines: [String] {
        if let reset = sharedReset {
            return [QuotaParsing.subscriptionResetLine(reset: reset, now: now)]
        }
        var lines: [String] = []
        for sample in readySamples {
            guard let reset = sample.bar.periodEnd else { continue }
            let line = QuotaParsing.subscriptionResetLine(reset: reset, now: now)
            if !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Sign-in and week-reset hints for pools that are not ready. Repeated
    /// sentences, such as the same Cursor message on Auto and API, show once.
    private var unavailableNotes: [String] {
        var lines: [String] = []
        for kind in QuotaKind.subscriptionCases {
            guard let bar = bars.first(where: { $0.kind == kind }),
                  bar.state != .ready,
                  !bar.isLoadingPlaceholder,
                  !bar.detail.isEmpty,
                  !lines.contains(bar.detail)
            else { continue }
            lines.append(bar.detail)
        }
        return lines
    }

    private func legend(_ shares: [QuotaParsing.PoolShare]) -> some View {
        HStack(alignment: .top, spacing: MenuMetrics.points(10, scale: scale)) {
            ForEach(shares) { share in
                legendColumn(share)
            }
        }
    }

    private func legendColumn(_ share: QuotaParsing.PoolShare) -> some View {
        VStack(alignment: .leading, spacing: MenuMetrics.points(3, scale: scale)) {
            HStack(spacing: MenuMetrics.points(6, scale: scale)) {
                Circle()
                    .fill(segmentColor(share.kind))
                    .frame(
                        width: MenuMetrics.points(9, scale: scale),
                        height: MenuMetrics.points(9, scale: scale)
                    )
                    .accessibilityHidden(true)
                Text(legendTitle(share.kind))
                    .font(MenuMetrics.font(14, scale: scale, weight: .semibold))
                    .foregroundStyle(LiquidGlass.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(legendPercent(share))
                .font(MenuMetrics.font(16, scale: scale, weight: .semibold, monospaced: true))
                .foregroundStyle(legendPercentColor(share))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(legendTitle(share.kind)), \(legendPercent(share))")
    }

    private func legendTitle(_ kind: QuotaKind) -> String {
        switch kind {
        case .grokBot: return "Grok Bot"
        case .cursorModels: return "Cursor"
        case .otherModels: return "Other"
        default: return kind.title
        }
    }

    private func legendPercent(_ share: QuotaParsing.PoolShare) -> String {
        "\(Int(share.percent.rounded()))% used"
    }

    /// The dot keeps the app color. The percent text changes only at 50 and 80.
    private func legendPercentColor(_ share: QuotaParsing.PoolShare) -> Color {
        usageLevelColor(
            displayedPercent: Int(share.percent.rounded()),
            unchanged: segmentColor(share.kind)
        )
    }

    private func segmentColor(_ kind: QuotaKind) -> Color {
        switch kind {
        case .grokBot: return Color(nsColor: .systemBlue)
        case .cursorModels: return Color(nsColor: .systemYellow)
        case .otherModels: return Color(nsColor: .systemRed)
        default: return Color(nsColor: .systemGray)
        }
    }
}

private struct SegmentedAllowanceBar: View {
    struct Segment: Identifiable {
        var id: String
        var fraction: Double
        var color: Color
    }

    var segments: [Segment]
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let drawn = segments.filter { $0.fraction > 0 }
            let widths = QuotaParsing.exactSegmentWidths(
                fractions: drawn.map(\.fraction),
                usable: Double(geo.size.width)
            )
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LiquidGlass.textSecondary.opacity(0.25))
                HStack(spacing: 0) {
                    ForEach(Array(drawn.enumerated()), id: \.element.id) { index, segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: widths.indices.contains(index) ? CGFloat(widths[index]) : 0)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: height)
    }
}

/// Subscription pace label. Green under, yellow on pace or slightly over,
/// red when over by 5 or more.
private func subscriptionPaceColor(_ pace: QuotaPace) -> Color {
    switch pace.colorBand {
    case .green: return Color(nsColor: .systemGreen)
    case .yellow: return Color(nsColor: .systemYellow)
    case .red: return Color(nsColor: .systemRed)
    }
}

private func usageLevelColor(displayedPercent: Int, unchanged: Color) -> Color {
    switch UsageTextLevel.level(displayedPercent: displayedPercent) {
    case .unchanged: return unchanged
    case .yellow: return Color(nsColor: .systemYellow)
    case .red: return Color(nsColor: .systemRed)
    }
}

/// Single Ultra Usage bar and the total "% used" label.
private func usageFillColor(displayedPercent: Int) -> Color {
    switch UsageFillLevel.level(displayedPercent: displayedPercent) {
    case .green: return Color(nsColor: .systemGreen)
    case .yellow: return Color(nsColor: .systemYellow)
    case .red: return Color(nsColor: .systemRed)
    }
}
