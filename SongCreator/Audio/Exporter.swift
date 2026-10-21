import AVFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav24, wav16, aac
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wav24: return "WAV 24-bit"
        case .wav16: return "WAV 16-bit (CD)"
        case .aac: return "AAC 256k (.m4a)"
        }
    }
    var ext: String { self == .aac ? "m4a" : "wav" }

    func settings(sampleRate: Double) -> [String: Any] {
        switch self {
        case .wav24, .wav16:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: self == .wav24 ? 24 : 16, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(sampleRate, 48000),
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        }
    }
}

/// Offline (faster than realtime) mixdown through the same graph used for playback.
enum Exporter {
    /// Must be called on `transport.queue` with the transport stopped and the input tap removed.
    static func render(audio: AudioEngine, transport: Transport, song: Song, range: TimeRange,
                       to url: URL, format: ExportFormat, progress: (Double) -> Void) throws {
        let engine = audio.engine
        let sr = audio.sampleRate
        try audio.enableOfflineRendering()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }
        audio.sync(song)
        try engine.start()
        audio.allNotesOff()

        transport.prepare(PlayRequest(song: song, position: range.start, includeClick: false))
        transport.setMIDIBase(engine.manualRenderingSampleTime)
        for n in audio.tracks.values { n.player?.play() }

        let out = try AVAudioFile(forWriting: url, settings: format.settings(sampleRate: sr),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let total = Int64(range.length * sr)
        // Small blocks when automating so volume/pan changes land within ~10 ms.
        let block: Int64 = song.tracks.contains(where: \.hasAutomation) ? 512 : Int64(buffer.frameCapacity)
        var done: Int64 = 0
        var stalls = 0
        while done < total {
            transport.fill(throughPlayerFrame: done + 16384)
            if block == 512 { audio.applyAutomation(song, at: range.start + Double(done) / sr) }
            let n = AVAudioFrameCount(min(block, total - done))
            switch try engine.renderOffline(n, to: buffer) {
            case .success:
                try out.write(from: buffer)
                done += Int64(buffer.frameLength)
                stalls = 0
            case .cannotDoInCurrentContext:
                // Transient; try again, but never spin forever.
                stalls += 1
                if stalls > 200 { throw CocoaError(.fileWriteUnknown) }
                continue
            default:
                throw CocoaError(.fileWriteUnknown)
            }
            progress(Double(done) / Double(total))
        }
        for n in audio.tracks.values { n.player?.stop() }
        audio.allNotesOff()
    }
}
