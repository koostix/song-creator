import CoreMIDI
import Foundation

/// Listens to every MIDI source and reports channel messages with host timestamps.
final class MIDIInput {
    /// (status, data1, data2, hostTime). Called on a CoreMIDI thread.
    var onEvent: ((UInt8, UInt8, UInt8, UInt64) -> Void)?
    private(set) var sourceNames: [String] = []
    var sourcesChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    func start() {
        MIDIClientCreateWithBlock("Song Creator" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectAll()
    }

    private func connectAll() {
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
                onEvent?(status, d1, d2, ts)
            }
        }
    }
}
