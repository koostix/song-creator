import CoreMIDI
import Foundation

/// A MIDI output macOS knows about (an interface's MIDI port, a USB synth, a virtual port).
struct MIDIDestination: Identifiable, Hashable {
    /// Core MIDI's unique ID: stays the same across launches and reconnects.
    let id: Int32
    let name: String
}

/// Sends MIDI to outboard gear. Notes can carry a host-time timestamp, so Core MIDI delivers them on time.
final class MIDIOutput: @unchecked Sendable {
    static let shared = MIDIOutput()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    private init() {
        MIDIClientCreateWithBlock("Song Creator Out" as CFString, &client, nil)
        MIDIOutputPortCreate(client, "Out" as CFString, &port)
    }

    static func destinations() -> [MIDIDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let ep = MIDIGetDestination(i)
            guard ep != 0 else { return nil }
            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &uid)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name)
            return MIDIDestination(id: uid, name: name?.takeRetainedValue() as String? ?? "MIDI output")
        }
    }

    private func endpoint(_ uid: Int32) -> MIDIEndpointRef? {
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.destination
        guard MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr, type == .destination || type == .externalDestination else { return nil }
        return obj
    }

    /// Send one channel message to `device` on `channel` (1–16). `hostTime` 0 means now.
    func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, to device: Int32, channel: Int, at hostTime: UInt64 = 0) {
        guard let ep = endpoint(device) else { return }
        let ch = UInt32(max(1, min(16, channel)) - 1)
        var word: UInt32 = 0x2000_0000 | ((UInt32(status & 0xF0) | ch) << 16) | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, MIDITimeStamp(hostTime), 1, &word)
        MIDISendEventList(port, ep, &list)
    }

    /// Cancel anything still scheduled for the device and turn every note off on the channel.
    func silence(device: Int32, channel: Int) {
        guard let ep = endpoint(device) else { return }
        MIDIFlushOutput(ep)
        send(0xB0, 64, 0, to: device, channel: channel)    // sustain off
        send(0xB0, 123, 0, to: device, channel: channel)   // all notes off
        send(0xB0, 120, 0, to: device, channel: channel)   // all sound off
    }
}
