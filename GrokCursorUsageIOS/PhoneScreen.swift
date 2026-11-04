import SwiftUI
import UIKit

struct PhoneScreen: View {
    @Bindable var reader: QuotaSnapshotReader
    @Bindable var appearance: AppearancePreferenceStore
    @State private var now = Date.now
    @State private var isRefreshing = false
    @State private var refreshFeedback: String?
    @State private var feedbackGeneration = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            viewerStack
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(contentFitsViewport)
        .background { ViewerBackdrop() }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = Self.safeViewportHeight(from: geo) }
                    .onChange(of: geo.size) { _, _ in
                        viewportHeight = Self.safeViewportHeight(from: geo)
                    }
            }
        }
        .task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var contentFitsViewport: Bool {
        guard contentHeight > 0, viewportHeight > 0 else { return true }
        return contentHeight <= viewportHeight + 1
    }

    private static func safeViewportHeight(from geo: GeometryProxy) -> CGFloat {
        let proposed = geo.size.height
        let insetTotal = geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        if insetTotal > 0 {
            return max(0, proposed - insetTotal)
        }
        if proposed >= 900 {
            return proposed - IOSGlass.portraitChromeFallback
        }
        return proposed
    }

    private var viewerStack: some View {
        GlassEffectContainer(spacing: IOSGlass.stackSpacing) {
            VStack(alignment: .leading, spacing: IOSGlass.stackSpacing) {
                header
                if let snapshot = reader.snapshot {
                    if snapshot.bars.isEmpty {
                        emptyPools
                    } else {
                        subscriptionCard(snapshot)
                    }
                } else {
                    emptyState
                }
                feedbackFooter
            }
            .padding(.horizontal, IOSGlass.screenHorizontalPadding)
            .padding(.top, IOSGlass.screenTopPadding)
            .padding(.bottom, IOSGlass.screenBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in
                        contentHeight = height
                    }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: IOSGlass.headerSpacing) {
            VStack(alignment: .leading, spacing: IOSGlass.titleStampSpacing) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Grok & Cursor Usage")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    refreshButton
                }
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let refreshFeedback {
                    Text(refreshFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            AppearancePicker(preference: $appearance.preference)
                .controlSize(.small)
        }
    }

    private var refreshButton: some View {
        Button(action: refreshFromICloud) {
            ZStack {
                Text("Refresh")
                    .font(.subheadline.weight(.semibold))
                    .opacity(isRefreshing ? 0 : 1)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.blue)
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh")
        .accessibilityHint("Re-read the latest subscription snapshot from iCloud")
        .accessibilityValue(isRefreshing ? "Refreshing" : "Idle")
    }

    private func refreshFromICloud() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFeedback = nil
        feedbackGeneration += 1
        Task { @MainActor in
            let result = await reader.refresh()
            isRefreshing = false
            presentRefreshFeedback(result)
        }
    }

    private func presentRefreshFeedback(_ result: QuotaSnapshotRefreshResult) {
        refreshFeedback = result.nearbyStampFeedback
        feedbackGeneration += 1
        let generation = feedbackGeneration
        UIAccessibility.post(notification: .announcement, argument: result.stampFeedback)
        guard refreshFeedback != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: QuotaSnapshotRefreshPolicy.feedbackDuration)
            if generation == feedbackGeneration {
                refreshFeedback = nil
            }
        }
    }

    private var feedbackFooter: some View {
        VStack(spacing: 4) {
            SendFeedbackButton()
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
            Text("Opens a mail draft. If that can’t open, the address is shown so you can copy it. Nothing is sent until you send it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var statusLine: String {
        guard let snapshot = reader.snapshot else {
            return "Waiting for the Mac"
        }
        return snapshot.statusLine(now: now)
    }

    private var emptyState: some View {
        ViewerGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "icloud.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Open Grok & Cursor Usage on the Mac while this iPhone is signed into the same iCloud account")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyPools: some View {
        ViewerGlassCard {
            Text("No usage pools on this Mac")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No usage pools on this Mac")
    }

    private func subscriptionCard(_ snapshot: QuotaSnapshot) -> some View {
        UltraUsagePhoneCard(
            bars: snapshot.bars,
            poolShares: snapshot.poolShares,
            now: now
        )
    }
}

/// One shared weekly bar. The total is the highest ready pool.
private struct UltraUsagePhoneCard: View {
    var bars: [SnapshotQuotaBar]
    var poolShares: [QuotaParsing.PoolShare]
    var now: Date

    /// Blue, yellow, red. Grok is a meter of the same total, not a fourth share.
    private static let segmentOrder: [QuotaKind] = [.grokBot, .cursorModels, .otherModels]
    /// Ready readings that can set the total, including Grok.
    private static let allowanceOrder: [QuotaKind] = [.grokBot, .cursorModels, .otherModels, .superGrok]

    var body: some View {
        ViewerGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ultra Usage")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                combinedBar

                if let shares = splitShares {
                    legend(shares)
                }

                if !resetLines.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(resetLines, id: \.self) { line in
                            Text(line)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }

                if !unavailableNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(unavailableNotes, id: \.self) { note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var readySamples: [SnapshotQuotaBar] {
        Self.allowanceOrder.compactMap { kind in
            guard let bar = bars.first(where: { $0.kind == kind }),
                  bar.isReady,
                  !bar.isLoadingPlaceholder
            else { return nil }
            return bar
        }
    }

    private var combined: (usedPercent: Double, pace: QuotaPace?)? {
        QuotaParsing.combinedAllowance(
            readySamples.map {
                QuotaParsing.AllowanceSample(
                    usedPercent: $0.allowanceUsedPercent,
                    start: $0.periodStart,
                    end: $0.periodEnd
                )
            },
            now: now
        )
    }

    /// Named shares that add up to the total. Nil when the snapshot has no split.
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

    private var drawnSegments: [PhoneSegmentedAllowanceBar.Segment] {
        if let shares = splitShares {
            let fractions = QuotaParsing.sharedPoolTrackFractions(
                totalPercent: combined?.usedPercent,
                shares: shares.map(\.percent)
            )
            return zip(shares, fractions).compactMap { share, fraction in
                guard fraction > 0 else { return nil }
                return PhoneSegmentedAllowanceBar.Segment(
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
                return PhoneSegmentedAllowanceBar.Segment(
                    id: "total-\(index)",
                    fraction: fraction,
                    color: usageFillColor(displayedPercent: displayedTotalPercent)
                )
            }
    }

    private var combinedBar: some View {
        HStack(alignment: .center, spacing: 10) {
            PhoneSegmentedAllowanceBar(
                segments: drawnSegments,
                height: 10
            )
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            VStack(alignment: .trailing, spacing: 1) {
                Text(totalUsedText)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(totalUsageColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let pace = combined?.pace {
                    Text(pace.text)
                        .font(.title2.weight(.semibold).monospacedDigit())
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
        guard combined != nil else { return .primary }
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
        let resets = readySamples.compactMap(\.periodEnd)
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
            guard let reset = sample.periodEnd else { continue }
            let line = QuotaParsing.subscriptionResetLine(reset: reset, now: now)
            if !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Sign-in and week-reset hints for pools that are not ready.
    private var unavailableNotes: [String] {
        var lines: [String] = []
        for kind in QuotaKind.subscriptionCases {
            guard let bar = bars.first(where: { $0.kind == kind }),
                  !bar.isReady,
                  !bar.isLoadingPlaceholder
            else { continue }
            let note = bar.unavailableMessage ?? bar.detail
            guard !note.isEmpty, !lines.contains(note) else { continue }
            lines.append(note)
        }
        return lines
    }

    private func legend(_ shares: [QuotaParsing.PoolShare]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(shares) { share in
                legendColumn(share)
            }
        }
    }

    private func legendColumn(_ share: QuotaParsing.PoolShare) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(segmentColor(share.kind))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(legendTitle(share.kind))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(legendPercent(share))
                .font(.title3.weight(.semibold).monospacedDigit())
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
        case .grokBot: return .blue
        case .cursorModels: return .yellow
        case .otherModels: return .red
        default: return .gray
        }
    }
}

private struct PhoneSegmentedAllowanceBar: View {
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
                    .fill(.tertiary)
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
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    }
}

private func usageLevelColor(displayedPercent: Int, unchanged: Color) -> Color {
    switch UsageTextLevel.level(displayedPercent: displayedPercent) {
    case .unchanged: return unchanged
    case .yellow: return .yellow
    case .red: return .red
    }
}

/// Single Ultra Usage bar and the total "% used" label.
private func usageFillColor(displayedPercent: Int) -> Color {
    switch UsageFillLevel.level(displayedPercent: displayedPercent) {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    }
}
