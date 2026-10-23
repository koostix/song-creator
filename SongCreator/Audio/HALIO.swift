import AVFoundation
import AudioToolbox
import Synchronization

/// The app's own connection to the audio hardware, used when specific devices are chosen in Settings.
///
/// AVAudioEngine's built-in I/O follows the system default devices and overrides a device set on it,
/// so for chosen devices the engine runs in realtime manual-rendering mode and this HAL unit drives it:
/// each hardware cycle captures the input, then asks the engine to render the output.
final class HALIO: @unchecked Sendable {
    let device: AudioDeviceID
    let sampleRate: Double
    /// Input channels captured each cycle (0 = output only).
    let inputChannels: Int
    let maxFrames: UInt32 = 4096

    private var unit: AudioUnit?
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let inputData: [UnsafeMutablePointer<Float>]

    /// The engine's manual rendering block; set before `start()` and not changed while running.
    var render: AVAudioEngineManualRenderingBlock?
    /// Callbacks do nothing unless active; `stop()` clears it and waits for any callback in flight.
    private let active = Atomic<Bool>(false)
    private let inFlight = Atomic<Int>(0)
    /// Called on the realtime thread with each cycle's input and the engine sample it lines up with
    /// (feeds input monitoring and recording).
    var onInput: ((UnsafePointer<AudioBufferList>, Int, Int64) -> Void)?

    /// Host time and engine sample time of the most recent cycle, for converting between the two.
    let lastHost = Atomic<UInt64>(0)
    let lastSample = Atomic<Int64>(0)
    private var engineSample: Int64 = 0

    init?(device: AudioDeviceID, sampleRate: Double, inputChannels: Int) {
        self.device = device
        self.sampleRate = sampleRate
        self.inputChannels = inputChannels
        let n = max(1, inputChannels)
        inputList = AudioBufferList.allocate(maximumBuffers: n)
        inputData = (0..<n).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
            p.initialize(repeating: 0, count: 4096)
            return p
        }
        for i in 0..<n {
            inputList[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4096 * 4, mData: UnsafeMutableRawPointer(inputData[i]))
        }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let u else { return nil }
        unit = u

        var on: UInt32 = 1
        var inputOn: UInt32 = inputChannels > 0 ? 1 : 0
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4)
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inputOn, 4)
        var dev = device
        guard AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return nil }
        var maxF = maxFrames
        AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, 4)

        // We hand the unit stereo float output and take deinterleaved float input, at the device rate.
        var outFormat = HALIO.floatFormat(sampleRate, channels: 2)
        guard AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else { return nil }
        if inputChannels > 0 {
            var inFormat = HALIO.floatFormat(sampleRate, channels: inputChannels)
            guard AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else { return nil }
        }

        var callback = AURenderCallbackStruct(inputProc: HALIO.renderProc,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(u) == noErr else { return nil }
    }

    deinit {
        stop()
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputData.forEach { $0.deallocate() }
        free(inputList.unsafeMutablePointer)
    }

    static func floatFormat(_ rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// The input captured this cycle, for the engine's input node.
    var inputBufferList: UnsafePointer<AudioBufferList> { UnsafePointer(inputList.unsafePointer) }

    /// Start the hardware; returns the Core Audio status (noErr on success).
    func start() -> OSStatus {
        guard let unit else { return -1 }
        active.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(unit)
        if status != noErr { active.store(false, ordering: .releasing) }
        return status
    }

    /// Stop the hardware. When this returns, no callback is running and none will touch the engine again,
    /// so the engine can be switched to offline rendering or replaced safely.
    func stop() {
        active.store(false, ordering: .releasing)
        if let unit { AudioOutputUnitStop(unit) }
        let deadline = Date().addingTimeInterval(1)
        while inFlight.load(ordering: .acquiring) > 0 && Date() < deadline { usleep(500) }
    }

    /// Host time of engine render sample `s`, using the latest cycle's timestamps.
    func hostTime(atSample s: Int64) -> UInt64? {
        let h = lastHost.load(ordering: .acquiring)
        guard h != 0 else { return nil }
        let delta = Double(s - lastSample.load(ordering: .acquiring)) / sampleRate
        return delta >= 0 ? h + HostTime.ticks(delta) : h &- HostTime.ticks(-delta)
    }

    /// Engine render sample at host time `h`.
    func sample(atHost h: UInt64) -> Int64? {
        let lh = lastHost.load(ordering: .acquiring)
        guard lh != 0 else { return nil }
        let dt = h >= lh ? HostTime.seconds(h - lh) : -HostTime.seconds(lh - h)
        return lastSample.load(ordering: .acquiring) + Int64((dt * sampleRate).rounded())
    }

    private static let renderProc: AURenderCallback = { refCon, flags, timeStamp, _, frames, ioData in
        let io = Unmanaged<HALIO>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData, let unit = io.unit else { return noErr }
        io.inFlight.add(1, ordering: .acquiringAndReleasing)
        defer { io.inFlight.subtract(1, ordering: .acquiringAndReleasing) }
        guard io.active.load(ordering: .acquiring) else {
            for buf in UnsafeMutableAudioBufferListPointer(ioData) { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
            return noErr
        }
        let n = Int(frames)
        if io.inputChannels > 0 {
            for i in 0..<io.inputList.count { io.inputList[i].mDataByteSize = UInt32(n * 4) }
            if AudioUnitRender(unit, flags, timeStamp, 1, frames, io.inputList.unsafeMutablePointer) == noErr {
                io.onInput?(io.inputBufferList, n, io.engineSample)
            } else {
                for p in io.inputData { memset(p, 0, n * 4) }
            }
        }
        io.lastHost.store(timeStamp.pointee.mHostTime, ordering: .releasing)
        io.lastSample.store(io.engineSample, ordering: .releasing)
        var err: OSStatus = noErr
        let status = io.render?(frames, ioData, &err) ?? .error
        if status != .success {
            for buf in UnsafeMutableAudioBufferListPointer(ioData) { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
        }
        io.engineSample += Int64(n)
        return noErr
    }
}
