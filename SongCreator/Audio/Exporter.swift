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
        // Small blocks when automating so changes land within ~10 ms.
        let block: Int64 = song.hasAutomation ? 512 : Int64(buffer.frameCapacity)
        // The file may run at a lower rate than the engine (AAC tops out at 48 kHz): convert, or it plays slow.
        let converter = out.processingFormat.sampleRate == buffer.format.sampleRate
            ? nil : AVAudioConverter(from: buffer.format, to: out.processingFormat)
        var done: Int64 = 0
        var stalls = 0
        while done < total {
            transport.fill(throughPlayerFrame: done + 16384)
            if block == 512 { audio.applyAutomation(song, at: range.start + Double(done) / sr) }
            let n = AVAudioFrameCount(min(block, total - done))
            switch try engine.renderOffline(n, to: buffer) {
            case .success:
                if let converter {
                    try convert(buffer, with: converter, to: out)
                } else {
                    try out.write(from: buffer)
                }
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
        if let converter { try convert(nil, with: converter, to: out) }   // flush what the converter still holds
        for n in audio.tracks.values { n.player?.stop() }
        audio.allNotesOff()
    }

    /// Feed one rendered block (nil = end of stream) through a rate converter and write what comes out.
    private static func convert(_ input: AVAudioPCMBuffer?, with converter: AVAudioConverter, to file: AVAudioFile) throws {
        var pending = input
        while true {
            let capacity = AVAudioFrameCount(max(8192, Double(input?.frameLength ?? 0) * file.processingFormat.sampleRate / converter.inputFormat.sampleRate + 64))
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw CocoaError(.fileWriteUnknown) }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let block = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return block
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if output.frameLength > 0 { try file.write(from: output) }
            if status != .haveData { return }
        }
    }
}
