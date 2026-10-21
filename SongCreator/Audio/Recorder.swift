import AVFoundation
import Accelerate

/// Captures the hardware input. One tap feeds input meters all the time and,
/// while recording, writes each armed audio track's channels to its own file.
final class Recorder {
    struct Target {
        let trackID: UUID
        let fileName: String
        let channels: Int
        let inputChannel: Int
        let file: AVAudioFile
    }

    struct Result {
        let firstHost: UInt64
        let frames: Int64
        let sampleRate: Double
        let targets: [Target]
    }

    static let peakFrames = 256

    private let lock = NSLock()
    private var targets: [Target] = []
    private var firstHost: UInt64?
    private var frames: Int64 = 0
    private var sampleRate: Double = 48000
    private var livePeaks: [UUID: [Float]] = [:]
    private weak var meters: MeterStore?
    private var tunerChannel = -1
    private var tunerSamples: [Float] = []
    private(set) var inputRate: Double = 48000

    func installTap(on audio: AudioEngine) {
        guard audio.hasInput else { return }
        let input = audio.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        meters = audio.meters
        inputRate = format.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in
            self?.process(buf, when)
        }
    }

    /// Feed one input channel to the tuner (nil turns it off).
    func setTunerChannel(_ ch: Int?) {
        lock.lock()
        tunerChannel = ch ?? -1
        tunerSamples = []
        lock.unlock()
    }

    func latestTunerSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return tunerSamples
    }

    func begin(targets: [Target], sampleRate: Double) {
        lock.lock()
        self.targets = targets
        self.sampleRate = sampleRate
        firstHost = nil
        frames = 0
        livePeaks = Dictionary(uniqueKeysWithValues: targets.map { ($0.trackID, []) })
        lock.unlock()
    }

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return !targets.isEmpty }

    func finish() -> Result? {
        lock.lock(); defer { lock.unlock() }
        guard !targets.isEmpty else { return nil }
        let r = firstHost.map { Result(firstHost: $0, frames: frames, sampleRate: sampleRate, targets: targets) }
        targets = []
        livePeaks = [:]
        return r
    }

    /// Peaks recorded so far for a track, plus the host time of the first frame.
    func live(_ track: UUID) -> (peaks: [Float], firstHost: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = livePeaks[track], let h = firstHost else { return nil }
        return (p, h)
    }

    private func process(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard let src = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        let inCh = Int(buf.format.channelCount)

        var levels = [Float](repeating: 0, count: inCh)
        for c in 0..<inCh { vDSP_maxmgv(src[c], 1, &levels[c], vDSP_Length(n)) }
        meters?.setInputs(levels)

        lock.lock()
        defer { lock.unlock() }
        if tunerChannel >= 0, tunerChannel < inCh {
            tunerSamples.append(contentsOf: UnsafeBufferPointer(start: src[tunerChannel], count: n))
            if tunerSamples.count > 8192 { tunerSamples.removeFirst(tunerSamples.count - 8192) }
        }
        guard !targets.isEmpty else { return }
        if firstHost == nil {
            firstHost = when.isHostTimeValid ? when.hostTime : HostTime.now
        }
        for t in targets {
            guard let out = AVAudioPCMBuffer(pcmFormat: t.file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                  let dst = out.floatChannelData else { continue }
            out.frameLength = AVAudioFrameCount(n)
            for c in 0..<t.channels {
                let from = min(t.inputChannel + c, inCh - 1)
                memcpy(dst[c], src[from], n * MemoryLayout<Float>.size)
            }
            try? t.file.write(from: out)

            var peaks = livePeaks[t.trackID] ?? []
            var i = 0
            while i < n {
                let len = min(Recorder.peakFrames, n - i)
                var p: Float = 0
                vDSP_maxmgv(dst[0] + i, 1, &p, vDSP_Length(len))
                peaks.append(p)
                i += len
            }
            livePeaks[t.trackID] = peaks
        }
        frames += Int64(n)
    }

    static func makeFile(url: URL, sampleRate: Double, channels: Int) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}
