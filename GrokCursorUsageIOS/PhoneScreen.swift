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
                        subscriptionCard(snapshot.bars)
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

    private func subscriptionCard(_ bars: [SnapshotQuotaBar]) -> some View {
        ViewerGlassCard {
            VStack(alignment: .leading, spacing: IOSGlass.subscriptionRowSpacing) {
                Text("Subscription Usage")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                ForEach(bars) { bar in
                    quotaRow(bar)
                }
            }
        }
    }

    private func quotaRow(_ bar: SnapshotQuotaBar) -> some View {
        VStack(alignment: .leading, spacing: IOSGlass.quotaRowSpacing) {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bar.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !bar.subtitle.isEmpty {
                        Text(bar.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(bar.usedText)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    if let pace = bar.pace {
                        Text(pace.text)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(paceColor(pace))
                    }
                }
            }
            if bar.isReady {
                ViewerMeterBar(fill: bar.usedFraction, color: usageBandColor(bar.usedFraction))
            }
            if let message = bar.unavailableMessage, !bar.isReady {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            } else if !bar.detail.isEmpty {
                Text(bar.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quotaAccessibility(bar))
    }

    private func quotaAccessibility(_ bar: SnapshotQuotaBar) -> String {
        if let message = bar.unavailableMessage, !bar.isReady {
            return "\(bar.label), \(message)"
        }
        if let pace = bar.pace {
            return "\(bar.label) \(bar.usedText), \(pace.text)"
        }
        return "\(bar.label) \(bar.usedText)"
    }
}

private struct ViewerMeterBar: View {
    let fill: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary)
                Capsule()
                    .fill(color)
                    .frame(width: max(fill > 0 ? 4 : 0, geo.size.width * min(1, max(0, fill))))
            }
        }
        .frame(height: IOSGlass.meterHeight)
        .accessibilityHidden(true)
    }
}

private func usageBandColor(_ usedFraction: Double) -> Color {
    let percent = usedFraction * 100
    if percent < 40 { return .green }
    if percent < 80 { return .orange }
    return .red
}

private func paceColor(_ pace: QuotaPace) -> Color {
    switch pace {
    case .over: return .orange
    case .under: return .green
    case .onPace: return .primary
    }
}
