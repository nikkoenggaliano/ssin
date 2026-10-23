import AppKit
import SwiftUI

/// A small HUD at the top of the screen for quick feedback ("Copied", "Saved", ...).
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, symbol: String = "checkmark.circle.fill", detail: String? = nil, tint: Color = .green) {
        let host = NSHostingView(rootView: ToastView(title: title, symbol: symbol, detail: detail, tint: tint))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        panel.setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue < 0.01 { panel.orderOut(nil) }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 1.4 : 2.4), execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        panel = p
        return p
    }
}

private struct ToastView: View {
    let title: String
    let symbol: String
    let detail: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 340, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .padding(18)
        .environment(\.colorScheme, .dark)
    }
}
