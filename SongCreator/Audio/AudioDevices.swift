import AVFoundation
import CoreAudio

extension Notification.Name {
    static let audioDevicesChanged = Notification.Name("SongCreator.audioDevicesChanged")
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !name.hasPrefix("CADefaultDeviceAggregate"),                    // AVAudioEngine's private aggregate
                  !uid.hasPrefix("com.paulshuler.SongCreator.aggregate") else { return nil }   // ours
            return AudioDevice(id: id, uid: uid, name: name,
                               inputChannels: channels(id, kAudioDevicePropertyScopeInput),
                               outputChannels: channels(id, kAudioDevicePropertyScopeOutput))
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return all().first { $0.uid == uid }
    }

    static func setDevice(_ device: AudioDeviceID, on node: AVAudioIONode) {
        guard let unit = node.audioUnit else { return }
        var id = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// The output's current data source, e.g. 'ispk' (internal speakers) or 'hdpn' (headphones).
    static func outputDataSource(_ id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static let internalSpeakers: UInt32 = 0x6973_706B // 'ispk'

    /// True when sound comes out of the computer's own speakers, where a live mic can feed back.
    /// Headphones show up either as their own device or as a 'hdpn' data source, so they don't count.
    static func isBuiltInSpeakers(_ id: AudioDeviceID) -> Bool {
        guard transportType(id) == kAudioDeviceTransportTypeBuiltIn else { return false }
        if let source = outputDataSource(id) { return source == internalSpeakers }
        return (name(id) ?? "").localizedCaseInsensitiveContains("speaker")
    }

    /// Call `handler` on the main queue whenever `selector` changes on `id`. Returns a token for `removeListener`.
    static func addListener(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            _ handler: @escaping () -> Void) -> (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        return (id, addr, block)
    }

    static func removeListener(_ token: (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)) {
        var addr = token.1
        AudioObjectRemovePropertyListenerBlock(token.0, &addr, DispatchQueue.main, token.2)
    }

    /// The buffer size the device actually uses (it may round what was asked for).
    static func bufferSize(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? Int(value) : 0
    }

    /// Posts `.audioDevicesChanged` when devices are plugged in or out, or the system defaults change.
    static func startWatching() {
        guard !watching else { return }
        watching = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            _ = addListener(system, sel) { NotificationCenter.default.post(name: .audioDevicesChanged, object: nil) }
        }
    }
    private static var watching = false

    /// I/O buffer size in frames. Smaller means less monitoring latency and more CPU.
    static func setBufferSize(_ id: AudioDeviceID, frames: Int) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(frames)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// The device's current sample rate, read without opening any stream (so a Bluetooth
    /// headset isn't pushed into its low-quality call mode just by asking).
    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    static func name(_ id: AudioDeviceID) -> String? { all().first { $0.id == id }?.name }

    /// Whether the device can run at `rate` (checks its list of supported rates and ranges).
    static func supports(_ id: AudioDeviceID, rate: Double) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return false }
        return ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
    }

    /// Switch a device to `rate` and wait (briefly) until it reports the new rate. Returns success.
    @discardableResult
    static func setSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        if sampleRate(id) == rate { return true }
        guard supports(id, rate: rate) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        guard AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr else { return false }
        let deadline = Date().addingTimeInterval(1.5)
        while sampleRate(id) != rate && Date() < deadline { usleep(10_000) }
        return sampleRate(id) == rate
    }

    static func uid(_ id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// A private aggregate of an output and an input device, clocked by the output, with drift
    /// correction on the input. Only this process sees it; it disappears when the app quits.
    static func makeAggregate(output: AudioDeviceID, input: AudioDeviceID) -> AudioObjectID? {
        guard let outUID = uid(output), let inUID = uid(input) else { return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.paulshuler.SongCreator.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Song Creator (\(name(input) ?? "input") + \(name(output) ?? "output"))",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outUID],
                [kAudioSubDeviceUIDKey: inUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var id = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        channels(id, kAudioDevicePropertyScopeInput)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
