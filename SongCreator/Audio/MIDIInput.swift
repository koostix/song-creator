import AppKit
import CoreMIDI

/// Listens to every MIDI source and reports channel messages with host timestamps.
final class MIDIInput {
    /// (status, data1, data2, hostTime). Called on a CoreMIDI thread.
    var onEvent: ((UInt8, UInt8, UInt8, UInt64) -> Void)?
    private(set) var sourceNames: [String] = []
    var sourcesChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    /// One connection for the app's lifetime, so the MIDI server stays up while the app runs.
    static let shared = MIDIInput()
    private init() {}

    /// Connect before any window opens. A process that connects while the MIDI server is shutting down (it does,
    /// a few seconds after its last client quits) is refused for as long as it lives, retries included, but a new
    /// process gets in at once. So on refusal the app starts a fresh copy of itself, once, and leaves.
    static func connectAtLaunch() {
        let retried = "SONG_CREATOR_MIDI_RETRIED"
        guard !shared.connect(), getenv(retried) == nil, let path = Bundle.main.executablePath else { return }
        fputs("Core MIDI refused the connection; restarting to reconnect.\n", stderr)

        // Command-line test runs keep their output and exit code by staying in this process.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            setenv(retried, "1", 1)
            execv(path, CommandLine.unsafeArgv)
            return
        }
        // A normal launch has to go through Launch Services: replacing the process in place leaves it with no window.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = [retried: "1"]
        let done = DispatchSemaphore(value: 0)
        var launched = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, _ in
            launched = app != nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        if launched { exit(0) }
    }

    var isConnected: Bool { client != 0 }

    private let handlerLock = NSLock()
    private weak var owner: AnyObject?

    /// Route incoming MIDI to `owner`'s handler, replacing whoever had it.
    func attach(owner: AnyObject, onEvent: @escaping (UInt8, UInt8, UInt8, UInt64) -> Void, sourcesChanged: @escaping () -> Void) {
        handlerLock.lock()
        self.owner = owner
        self.onEvent = onEvent
        self.sourcesChanged = sourcesChanged
        handlerLock.unlock()
        if client == 0 { connect() } else { connectAll() }
    }

    /// Stop routing to `owner` (a song that's closed shouldn't keep listening). Does nothing if another song took over.
    func detach(owner: AnyObject) {
        handlerLock.lock()
        if self.owner === owner {
            onEvent = nil
            sourcesChanged = nil
            self.owner = nil
        }
        handlerLock.unlock()
    }

    @discardableResult
    private func connect() -> Bool {
        guard client == 0 else { return true }
        let status = MIDIClientCreateWithBlock("Song Creator" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        guard status == noErr else {
            client = 0
            return false
        }
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectAll()
        return true
    }

    private func connectAll() {
        guard client != 0 else { return }
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name {
                names.append(n.takeRetainedValue() as String)
            }
        }
        sourceNames = names
        sourcesChanged?()
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            let ts = packet.pointee.timeStamp == 0 ? HostTime.now : packet.pointee.timeStamp
            let count = Int(packet.pointee.wordCount)
            let words: [UInt32] = withUnsafeBytes(of: packet.pointee.words) {
                Array($0.bindMemory(to: UInt32.self).prefix(count))
            }
            for word in words {
                // MIDI 1.0 channel voice messages in UMP form: type 0x2.
                guard word >> 28 == 0x2 else { continue }
                let status = UInt8((word >> 16) & 0xFF)
                let d1 = UInt8((word >> 8) & 0x7F)
                let d2 = UInt8(word & 0x7F)
                handlerLock.lock()
                let handler = onEvent
                handlerLock.unlock()
                handler?(status, d1, d2, ts)
            }
        }
    }
}
