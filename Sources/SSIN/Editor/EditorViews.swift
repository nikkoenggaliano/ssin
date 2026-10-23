import AppKit
import SwiftUI

/// Commands the SwiftUI chrome triggers on the window controller.
struct EditorActions {
    var copy: () -> Void
    var save: () -> Void
    var copyText: () -> Void
    var pin: () -> Void
    var zoom: (ZoomCommand) -> Void
    var dragFile: () -> URL?
}

enum ZoomCommand {
    case fit, percent(CGFloat)
}

// MARK: - Top bar

struct EditorTopBar: View {
    @ObservedObject var doc: EditorDocument
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64, height: 1)
            ToolPalette(doc: doc)
            UndoRedo(doc: doc)
            Spacer(minLength: 6)
            InfoCluster(doc: doc, status: doc.status, actions: actions)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 24)
            ActionButtons(doc: doc, actions: actions)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .bottom) {
                Color(white: 0.125)
                Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1)
            }
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct ToolPalette: View {
    @ObservedObject var doc: EditorDocument
    private let groups: [[Tool]] = [[.select], [.arrow, .line, .rect, .ellipse], [.text, .counter], [.pen, .highlight],
                                    [.blur, .spotlight], [.crop]]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(groups.indices, id: \.self) { g in
                if g > 0 {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 16).padding(.horizontal, 3)
                }
                ForEach(groups[g]) { tool in
                    BarButton(symbol: tool.symbol, active: doc.tool == tool,
                              help: tool.title, shortcut: String(tool.shortcut).uppercased()) {
                        doc.selectTool(tool)
                    }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

private struct UndoRedo: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        HStack(spacing: 2) {
            BarButton(symbol: "arrow.uturn.backward", help: "Undo", shortcut: "⌘Z") { doc.undoManager.undo() }
                .disabled(!doc.undoManager.canUndo)
            BarButton(symbol: "arrow.uturn.forward", help: "Redo", shortcut: "⇧⌘Z") { doc.undoManager.redo() }
                .disabled(!doc.undoManager.canRedo)
        }
    }
}

private struct InfoCluster: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var status: EditorStatus
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                let color = status.hoverColor
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.map { Color(nsColor: $0.nsColor) } ?? Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(color?.hex ?? "—")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    Text("Tab to copy")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, alignment: .leading)
            .tip("Color under the cursor", shortcut: "Tab", detail: "Copies its hex code")

            let size = doc.outputPixelSize
            Stat(value: "\(Int(size.width))×\(Int(size.height))", label: doc.pixelScale > 1 ? "px · @\(Int(doc.pixelScale))x" : "px")

            Menu {
                Button("Zoom to Fit  ⌘0") { actions.zoom(.fit) }
                Button("50%") { actions.zoom(.percent(50)) }
                Button("Actual Size  ⌘1") { actions.zoom(.percent(100)) }
                Button("200%") { actions.zoom(.percent(200)) }
                Button("400%") { actions.zoom(.percent(400)) }
            } label: {
                Stat(value: "\(status.zoomPercent)%", label: "Zoom")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("Zoom", detail: "⌘0 fit  ·  ⌘1 actual size  ·  ⌘= / ⌘− in and out")
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

private struct ActionButtons: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject private var settings = AppSettings.shared
    let actions: EditorActions
    private let keepOpenHint = "⌥-click keeps the preview open"

    var body: some View {
        HStack(spacing: 3) {
            BarButton(symbol: "sparkles", active: doc.state.background.enabled, help: "Beautify background", shortcut: "⌘B",
                      detail: "Gradient backdrop, padding and shadow") {
                doc.toggleBeautify()
            }
            BarButton(symbol: "text.viewfinder", help: "Copy text (OCR)", shortcut: "⇧⌘C",
                      detail: "Copies the words in the image as text", action: actions.copyText)
            BarButton(symbol: "pin", help: "Pin to screen", shortcut: "⌘P", detail: "Floats above all windows", action: actions.pin)
            DragOutButton(doc: doc, provider: actions.dragFile)
                .tip("Drag into any app", detail: "Drop it into Slack, Finder, Mail…")
            BarButton(symbol: "square.and.arrow.down", help: "Save to folder", shortcut: "⌘S",
                      detail: "Saves a \(settings.imageFormat.fileExtension.uppercased()) file to “\(settings.saveFolder.lastPathComponent)”, then closes\n\(keepOpenHint)",
                      action: actions.save)
            Button(action: actions.copy) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 11, weight: .semibold))
                    Text("Copy").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(Capsule().fill(Color.accentColor.gradient))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .tip("Copy to clipboard", shortcut: "⌘C", detail: "Paste it anywhere with ⌘V, then closes\n\(keepOpenHint)")
            .padding(.leading, 5)
        }
    }
}

/// Icon button used across the editor chrome.
struct BarButton: View {
    let symbol: String
    var active = false
    var help: String
    var shortcut: String?
    var detail: String?
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(enabled ? 0.88 : 0.3))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.white.opacity(hovering && enabled ? 0.09 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .tip(help, shortcut: shortcut, detail: detail)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Drag out

private struct DragOutButton: View {
    @ObservedObject var doc: EditorDocument
    let provider: () -> URL?
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.75))
            }
            DragSourceRepresentable(provider: provider, thumbnail: thumbnail)
        }
        .frame(width: 30, height: 28)
        .onAppear {
            if let small = doc.image.downscaled(by: min(1, 96 / CGFloat(max(doc.image.width, doc.image.height)))) {
                thumbnail = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
            }
        }
    }
}

private struct DragSourceRepresentable: NSViewRepresentable {
    let provider: () -> URL?
    let thumbnail: NSImage?

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.provider = provider
        view.thumbnail = thumbnail
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var provider: (() -> URL?)?
    var thumbnail: NSImage?

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let url = provider?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 96, height: 96 * image.size.height / max(1, image.size.width))
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - Inspector

struct InspectorBar: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        HStack(spacing: 12) {
            if doc.tool == .crop {
                CropControls(doc: doc)
            } else if doc.beautifyPanel {
                BackgroundControls(doc: doc)
            } else {
                StyleControls(doc: doc)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Capsule().fill(Color(white: 0.11).opacity(0.86)))
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .padding(22)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.18), value: doc.tool)
        .animation(.snappy(duration: 0.18), value: doc.beautifyPanel)
    }
}

private struct StyleControls: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        if let kind = doc.inspectorKind {
            if kind.usesColor {
                ColorRow(selected: doc.currentColor) { doc.setColor($0) }
            }
            if kind.usesStroke {
                Divider().frame(height: 20)
                LabeledSlider(symbol: "lineweight", value: Binding(get: { doc.currentStrokeWidth }, set: { doc.setStrokeWidth($0.rounded()) }),
                              range: 1...20, help: "Stroke width")
            }
            if kind.usesFill {
                Picker("", selection: Binding(get: { doc.currentFill }, set: { doc.setFill($0) })) {
                    ForEach(FillStyle.allCases) { Image(systemName: $0.symbol).help($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 104)
            }
            if kind == .text {
                Divider().frame(height: 20)
                Picker("", selection: Binding(get: { doc.currentTextStyle }, set: { doc.setTextStyle($0) })) {
                    ForEach(TextStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
            }
            if kind == .text || kind == .counter {
                LabeledSlider(symbol: "textformat.size", value: Binding(get: { doc.currentFontSize }, set: { doc.setFontSize($0.rounded()) }),
                              range: kind == .counter ? 8...40 : 10...96, help: "Size")
            }
            if kind == .blur {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { doc.currentBlurStyle }, set: { doc.setBlurStyle($0) })) {
                    ForEach(BlurStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            if kind == .spotlight {
                Label("Drag to focus areas — everything else is dimmed", systemImage: "flashlight.on.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if kind.usesShadow {
                Divider().frame(height: 20)
                PillToggle(title: "Shadow", isOn: doc.currentShadow) { doc.setShadow(!doc.currentShadow) }
            }
            if doc.selected != nil {
                BarButton(symbol: "square.3.layers.3d.top.filled", help: "Bring to front") { doc.bringSelectedToFront() }
                BarButton(symbol: "trash", help: "Delete", shortcut: "⌫") { doc.deleteSelected() }
            }
        } else {
            Label("Click an annotation to edit it  ·  Shortcuts: A R O T P H B S N C", systemImage: "cursorarrow.rays")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ColorRow: View {
    let selected: RGBA
    let onSelect: (RGBA) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { index, color in
                let isSelected = color.hex == selected.hex
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.75))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .tip("Color \(index + 1)")
            }
            let isCustom = !RGBA.palette.contains { $0.hex == selected.hex }
            Button {
                ColorPanelBridge.shared.open(color: selected, onChange: onSelect)
            } label: {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .overlay(Circle().fill(isCustom ? Color(nsColor: selected.nsColor) : .clear).padding(4))
                    .frame(width: 18, height: 18)
                    .padding(2.5)
                    .overlay(Circle().strokeBorder(isCustom ? Color.white : .clear, lineWidth: 1.75))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .tip("Custom color…")
        }
    }
}

private struct LabeledSlider: View {
    let symbol: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let help: String
    var format: (CGFloat) -> String = { "\(Int($0))" }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
            Slider(value: $value, in: range).frame(width: 100).controlSize(.small)
            Text(format(value)).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
        }
        .tip(help)
    }
}

private struct BackgroundControls: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let bg = doc.state.background
        HStack(spacing: 5) {
            ForEach(BackgroundPreset.all) { preset in
                Button {
                    doc.updateBackground("preset") { $0.presetID = preset.id }
                } label: {
                    PresetSwatch(preset: preset)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(bg.presetID == preset.id ? Color.white : .clear, lineWidth: 1.75))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .tip(preset.name)
            }
        }
        Divider().frame(height: 20)
        LabeledSlider(symbol: "arrow.up.left.and.arrow.down.right", value: Binding(get: { bg.padding }, set: { v in doc.updateBackground("padding") { $0.padding = v.rounded() } }),
                      range: 0...160, help: "Padding")
        LabeledSlider(symbol: "square.on.square", value: Binding(get: { bg.cornerRadius }, set: { v in doc.updateBackground("radius") { $0.cornerRadius = v.rounded() } }),
                      range: 0...40, help: "Corner radius")
        LabeledSlider(symbol: "square.filled.on.square", value: Binding(get: { bg.shadow * 100 }, set: { v in doc.updateBackground("shadow") { $0.shadow = v / 100 } }),
                      range: 0...100, help: "Shadow")
        BarButton(symbol: "xmark", help: "Remove background") { doc.toggleBeautify() }
    }
}

private struct PresetSwatch: View {
    let preset: BackgroundPreset

    var body: some View {
        Group {
            if preset.isTransparent {
                Circle()
                    .fill(Color(white: 0.22))
                    .overlay(Image(systemName: "checkerboard.rectangle").font(.system(size: 9)).foregroundStyle(.secondary))
            } else {
                Circle().fill(LinearGradient(colors: preset.colors.map { Color(nsColor: $0.nsColor) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        .frame(width: 20, height: 20)
    }
}

private struct CropControls: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let r = doc.cropDraft ?? doc.fullRect
        Label("\(Int(r.width.rounded())) × \(Int(r.height.rounded()))", systemImage: "crop")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
        Text("Drag to crop · double-click or ↩ to apply")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        Divider().frame(height: 20)
        Button("Reset") { doc.resetCropDraft() }.buttonStyle(.borderless)
        Button("Cancel") { doc.cancelCrop() }.buttonStyle(.borderless)
        Button {
            doc.applyCrop()
        } label: {
            Text("Apply").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Capsule().fill(Color.accentColor.gradient))
        }
        .buttonStyle(PressableStyle())
    }
}

private struct PillToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.08))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .tip("Drop shadow")
    }
}

/// Routes the shared NSColorPanel back to whoever opened it.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((RGBA) -> Void)?

    func open(color: RGBA, onChange: @escaping (RGBA) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = color.nsColor
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(RGBA(sender.color))
    }
}
