import AppKit
import Carbon.HIToolbox

private let hotKeySignature: OSType = 0x5353_494E // 'SSIN'

/// Registers system-wide shortcuts through the Carbon hot key API (works without Accessibility permission).
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    /// Actions whose shortcut could not be registered (usually taken by another app).
    @Published private(set) var failed: Set<HotKeyAction> = []

    private var bindings: [HotKeyAction: (combo: KeyCombo, handler: () -> Void)] = [:]
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false

    func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            let index = Int(hotKeyID.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(index) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    func setBindings(_ new: [HotKeyAction: (combo: KeyCombo, handler: () -> Void)]) {
        unregisterAll()
        bindings = new
        if !suspended { registerAll() }
    }

    /// Temporarily releases every shortcut, e.g. while the user records a new one.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    private func registerAll() {
        var failures = Set<HotKeyAction>()
        for (action, binding) in bindings {
            guard let index = HotKeyAction.allCases.firstIndex(of: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySignature, id: UInt32(index))
            let status = RegisterEventHotKey(binding.combo.keyCode, binding.combo.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failures.insert(action)
            }
        }
        failed = failures
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    fileprivate func fire(_ index: Int) {
        guard HotKeyAction.allCases.indices.contains(index) else { return }
        bindings[HotKeyAction.allCases[index]]?.handler()
    }
}
