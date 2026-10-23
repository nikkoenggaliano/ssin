import AppKit
import SwiftUI

/// What a hover tip shows: a title, an optional shortcut chip and an optional hint below.
struct Tip: Equatable {
    var title: String
    var shortcut: String?
    var detail: String?
}

extension View {
    /// A styled tooltip that appears quicker than `.help` and says what a button does, its shortcut and side effects.
    func tip(_ title: String, shortcut: String? = nil, detail: String? = nil) -> some View {
        background(TipAnchor(tip: Tip(title: title, shortcut: shortcut, detail: detail)))
    }
}

private struct TipAnchor: NSViewRepresentable {
    let tip: Tip

    func makeNSView(context: Context) -> TipAnchorView { TipAnchorView() }
    func updateNSView(_ view: TipAnchorView, context: Context) { view.tip = tip }
}

/// Sits behind a button and reports hover; it never takes clicks.
final class TipAnchorView: NSView {
    var tip = Tip(title: "") {
        didSet { if tip != oldValue, HoverTip.shared.owner === self { HoverTip.shared.show(for: self) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { HoverTip.shared.hover(self) }
    override func mouseExited(with event: NSEvent) { HoverTip.shared.leave(self) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { HoverTip.shared.leave(self) }
    }
}

/// One floating bubble shared by every anchor, shown below (or above) the hovered button.
@MainActor
final class HoverTip {
    static let shared = HoverTip()

    private(set) weak var owner: TipAnchorView?
    private(set) var panel: NSPanel?
    private var hosting: NSHostingView<TipBubble>?
    private var pending: DispatchWorkItem?
    private var lastHidden = Date.distantPast
    private var monitor: Any?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hover(_ anchor: TipAnchorView) {
        pending?.cancel()
        owner = anchor
        // Sliding from one button to the next shows the next tip right away, like the menu bar does.
        let warm = panel?.isVisible == true || Date().timeIntervalSince(lastHidden) < 0.4
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, self.owner === anchor else { return }
            self.show(for: anchor)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0 : 0.35), execute: work)
    }

    func leave(_ anchor: TipAnchorView) {
        if owner === anchor { hide() }
    }

    func show(for anchor: TipAnchorView) {
        guard let window = anchor.window else { return }
        owner = anchor
        let panel = self.panel ?? makePanel()
        hosting?.rootView = TipBubble(tip: anchor.tip)
        let size = hosting?.fittingSize ?? .zero
        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? target.insetBy(dx: -500, dy: -500)
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.minY - 7 - size.height)
        if origin.y < screen.minY { origin.y = target.maxY + 7 }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)
        panel.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.floating.rawValue) + 1)
        panel.orderFrontRegardless()

        if monitor == nil {
            // Clicking, typing or scrolling dismisses the tip until the pointer enters a button again.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.hide() }
                return event
            }
        }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        if panel?.isVisible == true { lastHidden = Date() }
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false  // NSPanel defaults to true; we hide on resign-active ourselves
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        let hosting = NSHostingView(rootView: TipBubble(tip: Tip(title: "")))
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

struct TipBubble: View {
    let tip: Tip

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(tip.title).font(.system(size: 12, weight: .semibold))
                if let shortcut = tip.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.1)))
                }
            }
            if let detail = tip.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}
