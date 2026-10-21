import AVFoundation

/// Renders short buffers of a track's comped audio, and of the metronome, for a
/// span of song time. Runs on the scheduler queue only.
final class ChunkRenderer {
    let sampleRate: Double
    var audioFolder: URL
    private var files: [String: AVAudioFile] = [:]
    private var scratch: AVAudioPCMBuffer?
    private let fadeFrames: Int64

    private lazy var accentClick = ChunkRenderer.makeClick(freq: 1760, sampleRate: sampleRate)
    private lazy var normalClick = ChunkRenderer.makeClick(freq: 1175, sampleRate: sampleRate)

    init(sampleRate: Double, audioFolder: URL) {
        self.sampleRate = sampleRate
        self.audioFolder = audioFolder
        self.fadeFrames = Int64(sampleRate * 0.004)
    }

    func forget(file name: String) {
        files[name] = nil
    }

    private func file(_ name: String) -> AVAudioFile? {
        if let f = files[name] { return f }
        let f = try? AVAudioFile(forReading: audioFolder.appendingPathComponent(name),
                                 commonFormat: .pcmFormatFloat32, interleaved: false)
        files[name] = f
        return f
    }

    /// Fill `out` (starting at `outOffset`) with the track's audio for song frames
    /// [songStart, songStart+count). Returns true if anything was written.
    @discardableResult
    func renderTrack(_ track: Track, songStart: Int64, count: Int64,
                     into out: AVAudioPCMBuffer, outOffset: Int64) -> Bool {
        let sr = sampleRate
        let songEnd = songStart + count
        var wrote = false
        for seg in track.comp {
            let segStart = Int64((seg.start * sr).rounded())
            let segEnd = Int64((seg.end * sr).rounded())
            var a = max(segStart, songStart)
            let b = min(segEnd, songEnd)
            guard b > a, let take = track.take(seg.takeID), let name = take.fileName,
                  let f = file(name), f.processingFormat.sampleRate == sr else { continue }

            // Material for song frame x comes from the take at x - offset.
            let takeStart = Int64(((take.start + seg.offset) * sr).rounded())
            let fileOffset = Int64((take.fileOffset * sr).rounded())
            var filePos = a - takeStart + fileOffset
            if filePos < 0 { a -= filePos; filePos = 0 }
            guard b > a, filePos < f.length else { continue }
            let fadeIn = max(fadeFrames, Int64(seg.fadeIn * sr))
            let fadeOut = max(fadeFrames, Int64(seg.fadeOut * sr))
            let n = AVAudioFrameCount(min(b - a, f.length - filePos))
            guard n > 0 else { continue }

            if scratch == nil || scratch!.frameCapacity < n || scratch!.format != f.processingFormat {
                scratch = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: max(n, 16384))
            }
            guard let tmp = scratch else { continue }
            f.framePosition = filePos
            do { try f.read(into: tmp, frameCount: n) } catch { continue }
            let got = Int64(tmp.frameLength)
            guard got > 0, let src = tmp.floatChannelData, let dst = out.floatChannelData else { continue }

            let srcCh = Int(tmp.format.channelCount)
            let dstCh = Int(out.format.channelCount)
            let base = Int(outOffset + (a - songStart))
            for i in 0..<Int(got) {
                let songPos = a + Int64(i)
                var g: Float = 1
                let fromStart = songPos - segStart, toEnd = segEnd - songPos
                if fromStart < fadeIn { g = sinf(Float(fromStart) / Float(fadeIn) * .pi / 2) }
                if toEnd < fadeOut { g = min(g, sinf(Float(toEnd) / Float(fadeOut) * .pi / 2)) }
                if srcCh == dstCh {
                    for c in 0..<dstCh { dst[c][base + i] += src[c][i] * g }
                } else if srcCh == 1 {
                    for c in 0..<dstCh { dst[c][base + i] += src[0][i] * g }
                } else {
                    var sum: Float = 0
                    for c in 0..<srcCh { sum += src[c][i] }
                    let v = sum / Float(srcCh) * g
                    for c in 0..<dstCh { dst[c][base + i] += v }
                }
            }
            wrote = true
        }
        return wrote
    }

    /// Mix metronome clicks for song frames [songStart, songStart+count) into `out`.
    @discardableResult
    func renderClick(tempo: Double, beatsPerBar: Int, volume: Float, songStart: Int64, count: Int64,
                     into out: AVAudioPCMBuffer, outOffset: Int64) -> Bool {
        let framesPerBeat = 60 / tempo * sampleRate
        let clickLen = Int64(accentClick.count)
        let firstBeat = Int64(floor(Double(songStart - clickLen) / framesPerBeat))
        let lastBeat = Int64(floor(Double(songStart + count - 1) / framesPerBeat))
        guard lastBeat >= firstBeat, let dst = out.floatChannelData else { return false }
        var wrote = false
        for beat in firstBeat...lastBeat {
            let beatFrame = Int64((Double(beat) * framesPerBeat).rounded())
            let bpb = Int64(beatsPerBar)
            let isAccent = ((beat % bpb) + bpb) % bpb == 0
            let click = isAccent ? accentClick : normalClick
            let from = max(beatFrame, songStart), to = min(beatFrame + clickLen, songStart + count)
            guard to > from else { continue }
            for f in from..<to {
                let v = click[Int(f - beatFrame)] * volume
                let idx = Int(outOffset + f - songStart)
                for c in 0..<Int(out.format.channelCount) { dst[c][idx] += v }
            }
            wrote = true
        }
        return wrote
    }

    private static func makeClick(freq: Double, sampleRate: Double) -> [Float] {
        let n = Int(sampleRate * 0.035)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let env = exp(-t * 120)
            return Float(sin(2 * .pi * freq * t) * env * 0.8)
        }
    }
}
