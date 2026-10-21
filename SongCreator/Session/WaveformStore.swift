import AVFoundation
import Accelerate
import Observation

/// Overview peaks (one value per `Recorder.peakFrames` frames) for each audio file.
@Observable
final class WaveformStore {
    private(set) var peaks: [String: [Float]] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let queue = DispatchQueue(label: "songcreator.waveforms", qos: .utility)

    func load(_ name: String, folder: URL, force: Bool = false) {
        guard force || (peaks[name] == nil && !loading.contains(name)) else { return }
        loading.insert(name)
        let url = folder.appendingPathComponent(name)
        queue.async { [weak self] in
            let result = WaveformStore.compute(url)
            DispatchQueue.main.async {
                self?.loading.remove(name)
                if let result { self?.peaks[name] = result }
            }
        }
    }

    private static func compute(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let step = Recorder.peakFrames
        let chunk = AVAudioFrameCount(step * 256)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / step + 1)
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let d = buf.floatChannelData else { break }
            var i = 0
            while i < n {
                let len = min(step, n - i)
                var m: Float = 0
                for c in 0..<Int(buf.format.channelCount) {
                    var p: Float = 0
                    vDSP_maxmgv(d[c] + i, 1, &p, vDSP_Length(len))
                    m = max(m, p)
                }
                out.append(m)
                i += len
            }
        }
        return out
    }
}
