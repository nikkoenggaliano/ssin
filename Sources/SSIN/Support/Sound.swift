import AppKit

@MainActor
enum Sound {
    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var cache: [String: NSSound] = [:]

    static func shutter() { play("Screen Capture.aif") }
    static func recordStart() { play("begin_record.caf") }
    static func recordStop() { play("end_record.caf") }

    private static func play(_ name: String) {
        guard AppSettings.shared.playSounds else { return }
        let sound = cache[name] ?? NSSound(contentsOfFile: folder + name, byReference: true)
        cache[name] = sound
        sound?.stop()
        sound?.play()
    }
}
