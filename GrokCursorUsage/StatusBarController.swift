import AppKit
import SwiftUI

enum QuotaMenuBarSummary {
    struct Display: Equatable {
        var label: String
        var value: String
        var fraction: Double?
    }

    static func display(for bars: [QuotaBar], activeKind: QuotaKind?) -> Display {
        let ready = bars.filter(\.isReady)
        let chosen = ready.first { $0.kind == activeKind }
            ?? ready.max(by: { $0.usedPercent < $1.usedPercent })
        guard let chosen else {
            return Display(label: "USE", value: "—", fraction: nil)
        }
        let percent = Int(chosen.usedPercent.rounded())
        return Display(label: shortLabel(chosen.kind), value: "\(percent)%", fraction: chosen.usedFraction)
    }

    static func tooltip(for bars: [QuotaBar]) -> String {
        bars.map { bar in
            if bar.isReady {
                let pace = bar.pace.map { " · \($0.text)" } ?? ""
                return "\(bar.title) \(bar.usedText)\(pace)"
            }
            let detail = bar.detail.isEmpty ? "unavailable" : bar.detail
            return "\(bar.title): \(detail)"
        }.joined(separator: "\n")
    }

    private static func shortLabel(_ kind: QuotaKind) -> String {
        switch kind {
        case .cursorModels: "CUR"
        case .otherModels: "API"
        case .superGrok: "GRK"
        case .grokBot: "BOT"
        case .onDemand: "OD"
        case .xaiCredits: "X"
        }
    }
}

@MainActor
final class StatusBarController {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var menuPanel: NSPanel?
    private var menuHosting: NSHostingController<UsageMenuView>?
    private var guideWindow: NSWindow?
    private var releaseNotesWindow: NSWindow?
    private nonisolated(unsafe) var updateTimer: Timer?
    private nonisolated(unsafe) var localMouseMonitor: Any?
    private nonisolated(unsafe) var globalMouseMonitor: Any?
    private var cachedStatusImage: NSImage?
    private var cachedStatusImageKey: StatusImageCacheKey?
    private var reflowScheduled = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        refreshStatusItem()
        observeModel()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusItem()
            }
        }
        if let updateTimer {
            RunLoop.main.add(updateTimer, forMode: .common)
        }
    }

    deinit {
        updateTimer?.invalidate()
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.quotas.bars
            _ = model.quotas.menuBarKind
            _ = model.quotas.isRefreshing
            _ = model.quotas.lastUpdated
            _ = model.appearance.preference
            _ = model.appearance.systemScheme
            _ = model.appearance.interfaceScale
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatusItem()
                self.applyWindowAppearances()
                self.scheduleReflow()
                self.observeModel()
            }
        }
    }

    private func applyWindowAppearances() {
        let appearance = model.appearance.resolvedNSAppearance
        menuPanel?.appearance = appearance
        menuPanel?.contentView?.appearance = appearance
        guideWindow?.appearance = appearance
        guideWindow?.contentView?.appearance = appearance
        releaseNotesWindow?.appearance = appearance
        releaseNotesWindow?.contentView?.appearance = appearance
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(toggleMenu(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func refreshStatusItem() {
        configureStatusButton()
        guard let button = statusItem.button else { return }
        let summary = QuotaMenuBarSummary.display(for: model.quotas.bars, activeKind: model.quotas.menuBarKind)
        button.toolTip = QuotaMenuBarSummary.tooltip(for: model.quotas.bars)
        button.setAccessibilityLabel("Grok and Cursor usage, \(summary.label) \(summary.value)")
        let appearance = button.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = StatusImageCacheKey(label: summary.label, value: summary.value, fraction: summary.fraction, isDark: isDark)
        if cachedStatusImageKey != key || cachedStatusImage == nil {
            cachedStatusImage = Self.makeStatusImage(summary: summary, appearance: appearance)
            cachedStatusImageKey = key
            button.image = cachedStatusImage
        }
    }

    @objc
    private func toggleMenu(_ sender: NSStatusBarButton) {
        if menuPanel?.isVisible == true {
            closeMenu()
            return
        }
        showMenu(relativeTo: statusItem.button ?? sender)
    }

    private func showMenu(relativeTo button: NSStatusBarButton) {
        closeMenu()
        let rootView = UsageMenuView(
            quotas: model.quotas,
            launchAtLogin: model.launchAtLogin,
            appearance: model.appearance,
            notifier: model.notifier,
            grokSource: model.grokSource,
            updates: model.updates,
            onShowGuide: { [weak self] in
                self?.closeMenu()
                self?.showGuide()
            },
            onShowUpdate: { [weak self] in
                self?.closeMenu()
                self?.showReleaseNotes()
            },
            onLayout: { [weak self] in
                self?.scheduleReflow()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        // The panel is sized by hand. A hosting view that is the window's
        // content view also resizes the window during layout, and the two
        // fight until AppKit aborts on too many update-constraints passes.
        hosting.sizingOptions = []
        let width = MenuMetrics.width(for: model.appearance.interfaceScale)
        let fitted = hosting.sizeThatFits(in: NSSize(width: width, height: 10_000))
        let size = NSSize(width: width, height: max(200, ceil(fitted.height)))

        let panel = KeyableMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = model.appearance.resolvedNSAppearance
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        container.addSubview(hosting.view)
        panel.contentView = container
        panel.setContentSize(size)
        menuHosting = hosting
        Self.applyMenuShellMask(to: panel)
        positionMenu(panel, relativeTo: button)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        menuPanel = panel
        // The opening click is still in flight. Wait until it finishes before
        // watching for a click outside, or that same click closes the menu.
        DispatchQueue.main.async { [weak self] in
            self?.installClickOutsideMonitor()
        }
    }

    private static func applyMenuShellMask(to panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = LiquidGlass.menuShellCorner
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func scheduleReflow() {
        guard !reflowScheduled else { return }
        reflowScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reflowScheduled = false
            self.reflowMenu()
        }
    }

    private func reflowMenu() {
        guard let panel = menuPanel, panel.isVisible,
              let hosting = menuHosting,
              let button = statusItem.button
        else { return }
        let width = MenuMetrics.width(for: model.appearance.interfaceScale)
        let fitted = hosting.sizeThatFits(in: NSSize(width: width, height: 10_000))
        guard fitted.height > 80 else { return }
        let size = NSSize(width: width, height: ceil(fitted.height))
        guard abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        panel.setContentSize(size)
        positionMenu(panel, relativeTo: button)
        Self.applyMenuShellMask(to: panel)
        panel.invalidateShadow()
    }

    private func positionMenu(_ panel: NSPanel, relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        button.layoutSubtreeIfNeeded()
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(
            x: buttonRectOnScreen.midX - size.width / 2,
            y: buttonRectOnScreen.minY - size.height - 5
        )
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y < visible.minY + 8 {
                origin.y = buttonRectOnScreen.maxY + 5
            }
            origin.y = min(origin.y, visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func closeMenu() {
        removeClickOutsideMonitor()
        menuPanel?.orderOut(nil)
        menuPanel = nil
        menuHosting = nil
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.handlePotentialOutsideClick(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handler(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
    }

    private func handlePotentialOutsideClick(_ event: NSEvent) {
        guard let panel = menuPanel, panel.isVisible else { return }
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        if panel.frame.contains(screenPoint) { return }
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonScreenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonScreenRect.contains(screenPoint) { return }
        }
        closeMenu()
    }

    private func removeClickOutsideMonitor() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func showGuide() {
        if let guideWindow, guideWindow.isVisible {
            guideWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(
            rootView: GuideView(appearance: model.appearance) { [weak self] in
                self?.guideWindow?.close()
            }
        )
        let scale = model.appearance.interfaceScale
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MenuMetrics.points(480, scale: scale),
                height: MenuMetrics.points(560, scale: scale)
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Grok & Cursor Usage"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        LiquidGlass.applyChrome(to: window, appearance: model.appearance.resolvedNSAppearance)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        guideWindow = window
    }

    private func showReleaseNotes() {
        guard let notice = model.updates.notice else { return }
        if let releaseNotesWindow, releaseNotesWindow.isVisible {
            releaseNotesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(
            rootView: ReleaseNotesView(appearance: model.appearance, notice: notice) { [weak self] in
                self?.releaseNotesWindow?.close()
            }
        )
        let scale = model.appearance.interfaceScale
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MenuMetrics.points(480, scale: scale),
                height: MenuMetrics.points(520, scale: scale)
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "What’s new in \(notice.versionLabel)"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        LiquidGlass.applyChrome(to: window, appearance: model.appearance.resolvedNSAppearance)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        releaseNotesWindow = window
    }

    private static let statusValueFontSize: CGFloat = 10.5
    private static let statusLabelFontSize: CGFloat = 7.5
    private static let statusImageHeight: CGFloat = 22

    private static func makeStatusImage(summary: QuotaMenuBarSummary.Display, appearance: NSAppearance) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: statusLabelFontSize, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: statusValueFontSize, weight: .bold)
        let label = summary.label as NSString
        let value = summary.value as NSString
        let labelSize = label.size(withAttributes: [.font: labelFont, .kern: 0.2])
        let valueSize = value.size(withAttributes: [.font: valueFont])
        let bottomMargin: CGFloat = 1.5
        let bandGap: CGFloat = 4
        let dotDiameter: CGFloat = 6
        let dotGap: CGFloat = 3.5
        let width = ceil(max(valueSize.width, labelSize.width + dotGap + dotDiameter))
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let glyphColor: NSColor = isDark ? .white : .black
        let image = NSImage(size: NSSize(width: width, height: statusImageHeight), flipped: false) { _ in
            let valueBaseline = bottomMargin
            let labelBaseline = valueBaseline + valueFont.capHeight + bandGap
            value.draw(
                at: NSPoint(x: 0, y: valueBaseline + valueFont.descender),
                withAttributes: [.font: valueFont, .foregroundColor: glyphColor]
            )
            label.draw(
                at: NSPoint(x: 0, y: labelBaseline + labelFont.descender),
                withAttributes: [.font: labelFont, .foregroundColor: glyphColor, .kern: 0.2]
            )
            let dotRect = NSRect(
                x: labelSize.width + dotGap,
                y: labelBaseline + (labelFont.capHeight - dotDiameter) / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            dotColor(for: summary.fraction, isDark: isDark).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func dotColor(for fraction: Double?, isDark: Bool) -> NSColor {
        guard let fraction else {
            return isDark ? .secondaryLabelColor : NSColor(calibratedWhite: 0.35, alpha: 1)
        }
        let percent = fraction * 100
        if percent < 40 { return .systemGreen }
        if percent < 80 { return .systemOrange }
        return .systemRed
    }
}

private struct StatusImageCacheKey: Equatable {
    var label: String
    var value: String
    var fraction: Double?
    var isDark: Bool
}

private final class KeyableMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
