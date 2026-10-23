import AppKit
import SwiftUI

/// The frame around the recorded area plus a floating stop/discard bar. Both are excluded from the recording.
@MainActor
final class RecordingHUD {
    private var border: NSWindow?
    private var controls: NSPanel?
    private let model = RecordingHUDModel()
    private var timer: Timer?

    func show(around rect: CGRect, on screen: NSScreen, showBorder: Bool, onStop: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        hide()
        model.elapsed = 0
        model.onStop = onStop
        model.onDiscard = onDiscard

        if showBorder {
            let window = NSWindow(contentRect: rect.insetBy(dx: -4, dy: -4), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = RecordingBorderView()
            window.orderFrontRegardless()
            border = window
        }

        let host = NSHostingView(rootView: RecordingControlsView(model: model))
        let size = host.fittingSize
        let vf = screen.frame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < vf.minY + 8 { origin.y = rect.maxY + 10 }
        if origin.y + size.height > vf.maxY - 30 { origin.y = rect.minY + 20 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)

        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        panel.orderFrontRegardless()
        controls = panel
    }

    func startTimer(from start: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.elapsed = Date().timeIntervalSince(start) }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        border?.orderOut(nil)
        controls?.orderOut(nil)
        border = nil
        controls = nil
    }
}

@MainActor
final class RecordingHUDModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    var onStop: () -> Void = {}
    var onDiscard: () -> Void = {}
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var model: RecordingHUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(Self.format(model.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .leading)
            Button(action: model.onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.red.gradient))
            }
            .buttonStyle(.plain)
            .help("Stop and save")
            Button(action: model.onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Discard recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(14)
        .environment(\.colorScheme, .dark)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
