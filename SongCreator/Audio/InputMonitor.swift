import AVFoundation
import Synchronization

/// Lock-free single-writer ring of the latest hardware input, all channels.
/// Written by an AVAudioSinkNode on the realtime thread and read by per-track
/// AVAudioSourceNodes, so each track can monitor its own input channels through
/// its effects with about one I/O buffer of extra latency.
final class InputRing: @unchecked Sendable {
    let channels: Int
    let capacity = 16384
    private let mask: Int
    private let data: UnsafeMutablePointer<Float>
    /// Total frames ever written.
    let written = Atomic<Int>(0)

    init(channels: Int) {
        self.channels = max(1, channels)
        mask = capacity - 1
        data = .allocate(capacity: capacity * self.channels)
        data.initialize(repeating: 0, count: capacity * self.channels)
    }

    deinit { data.deallocate() }

    /// Realtime: copy one input buffer into the ring.
    func write(_ abl: UnsafePointer<AudioBufferList>, frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let w = written.load(ordering: .relaxed)
        var ch = 0
        for buf in list {
            guard let src = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let inCh = Int(buf.mNumberChannels)
            for k in 0..<inCh where ch < channels {
                let base = data + ch * capacity
                for i in 0..<frames { base[(w + i) & mask] = src[i * inCh + k] }
                ch += 1
            }
        }
        written.store(w + frames, ordering: .releasing)
    }

    /// Realtime: read `frames` of one channel starting at absolute frame `pos`.
    func read(channel: Int, from pos: Int, frames: Int, into dst: UnsafeMutablePointer<Float>) {
        let base = data + min(max(0, channel), channels - 1) * capacity
        for i in 0..<frames { dst[i] = base[(pos + i) & mask] }
    }
}

/// Per-track reader that keeps a steady distance behind the ring's write head.
final class MonitorReader: @unchecked Sendable {
    let ring: InputRing
    let firstChannel: Int
    let enabled = Atomic<Bool>(false)
    private var readPos = -1

    init(ring: InputRing, firstChannel: Int) {
        self.ring = ring
        self.firstChannel = firstChannel
    }

    /// Realtime render for an AVAudioSourceNode.
    func render(_ isSilence: UnsafeMutablePointer<ObjCBool>, _ frames: Int,
                _ out: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(out)
        guard enabled.load(ordering: .relaxed) else {
            for buf in list { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
            isSilence.pointee = true
            readPos = -1
            return noErr
        }
        let w = ring.written.load(ordering: .acquiring)
        let available = w - readPos
        if readPos < 0 || available < frames || available > frames * 4 + 2048 {
            readPos = w - frames
        }
        if readPos < 0 {
            for buf in list { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
            isSilence.pointee = true
            return noErr
        }
        for (c, buf) in list.enumerated() {
            guard let d = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            ring.read(channel: firstChannel + c, from: readPos, frames: frames, into: d)
        }
        readPos += frames
        return noErr
    }
}
