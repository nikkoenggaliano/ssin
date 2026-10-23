import AppKit

#if DEBUG
if MainActor.assumeIsolated({ DebugCommands.run(CommandLine.arguments) }) {
    exit(0)
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
