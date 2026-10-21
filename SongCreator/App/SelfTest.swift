#if DEBUG
import AVFoundation

/// `SongCreator --selftest <folder>`: builds songs in code, renders them offline and
/// checks that audio lands where the arrangement says. Prints results and exits.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        do {
            try run(dir)
            print("SELFTEST PASS")
            exit(0)
        } catch {
            print("SELFTEST FAIL: \(error)")
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ cond: Bool, _ msg: String) throws {
        print((cond ? "  ok   " : "  FAIL ") + msg)
        if !cond { throw Failure(description: msg) }
    }

    /// Rendered mix with helpers to measure it.
    struct Mix {
        let data: [Float]
        let sr: Double
        func window(_ t0: Double, _ t1: Double) -> (rms: Double, freq: Double) {
            let a = Int(t0 * sr), b = min(data.count, Int(t1 * sr))
            var sum = 0.0, zc = 0
            for i in a..<b {
                sum += Double(data[i] * data[i])
                if i > a, (data[i - 1] < 0) != (data[i] < 0) { zc += 1 }
            }
            return (sqrt(sum / Double(max(1, b - a))), Double(zc) / 2 / (t1 - t0))
        }
        func onset(after t: Double, threshold: Float = 0.01) -> Double {
            var i = Int(t * sr)
            while i < data.count, abs(data[i]) < threshold { i += 1 }
            return Double(i) / sr
        }
    }

    static func render(_ song: Song, audio: AudioEngine, dir: URL, length: Double, name: String) throws -> Mix {
        audio.sync(song)
        let transport = Transport(audio: audio, audioFolder: dir.appendingPathComponent("Audio"), song: song)
        let out = dir.appendingPathComponent(name)
        try transport.queue.sync {
            try Exporter.render(audio: audio, transport: transport, song: song,
                                range: TimeRange(start: 0, end: length), to: out, format: .wav24) { _ in }
        }
        let f = try AVAudioFile(forReading: out)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Mix(data: Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))),
                   sr: f.processingFormat.sampleRate)
    }

    /// Let async plugin loading (which completes on the main queue) finish.
    static func waitForPlugins(_ audio: AudioEngine, _ slots: [PluginSlot]) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, slots.contains(where: { audio.unit($0.id) == nil && audio.pluginErrors[$0.id] == nil }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func run(_ dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        let audioDir = dir.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        print("Timeline")
        let map = TimelineMap(sampleRate: 1000, startTime: 1, loop: TimeRange(start: 2, end: 4))
        try check(map.songFrame(atPlayerFrame: 0) == 1000, "map start")
        try check(map.songFrame(atPlayerFrame: 3000) == 2000, "map wraps to loop start")
        let pieces = map.pieces(playerStart: 0, count: 6000)
        try check(pieces.map(\.songStart) == [1000, 2000, 2000] && pieces.map(\.length) == [3000, 2000, 1000], "map pieces split at loop end")

        print("Comping and region edits")
        var t = Track(name: "c")
        let a = Take(name: "A", fileName: "x", start: 0, duration: 10)
        let b = Take(name: "B", fileName: "y", start: 0, duration: 10)
        t.takes = [a, b]
        t.assign(takeID: a.id, over: a.range)
        t.assign(takeID: b.id, over: TimeRange(start: 3, end: 5))
        try check(t.comp.count == 3 && t.activeTake(at: 4) == b.id && t.activeTake(at: 6) == a.id, "swipe comp splits regions")
        t.assign(takeID: a.id, over: TimeRange(start: 0, end: 10))
        try check(t.comp.count == 1, "re-comp replaces with one region")
        let whole = t.comp[0].id
        t.splitSegment(whole, at: 4)
        try check(t.comp.count == 2 && t.comp[0].end == 4 && t.comp[1].start == 4, "split at 4 s")
        t.normalizeComp()
        try check(t.comp.count == 2, "split stays split after normalising")
        let right = t.comp[1].id
        t.moveSegment(right, by: 2)
        try check(t.segment(right)?.start == 6 && t.segment(right)?.offset == 2 && t.segment(at: 5) == nil, "move leaves a gap and shifts material")
        t.moveSegment(right, by: -4)
        try check(t.segment(right)?.start == 2 && t.comp.first?.end == 2, "moving over a region cuts it")
        t.trimSegment(right, start: -5)
        try check(t.segment(right)?.start == 0, "trim reveals hidden material, stopping at the song start")
        t.trimSegment(right, end: 30)
        try check(abs((t.segment(right)?.end ?? 0) - 8) < 1e-9, "trim stops at the end of the take's material")
        t.setFades(right, fadeIn: 50, fadeOut: 1)
        try check(t.segment(right)!.fadeIn + t.segment(right)!.fadeOut <= t.segment(right)!.length + 1e-9, "fades fit inside the region")

        print("Loop tiling (JAM)")
        var bed = Track(name: "bed")
        let bt = Take(name: "B", fileName: "z", start: 0, duration: 20)
        bed.takes = [bt]
        bed.assign(takeID: bt.id, over: TimeRange(start: 1, end: 3))   // only 2–3 is inside the loop
        bed.place(CompSegment(takeID: bt.id, start: 7, end: 7.5))     // existing material gets overwritten
        bed.tileLoop(TimeRange(start: 2, end: 4), until: 10)
        let starts = bed.comp.map(\.start), offsets = bed.comp.map(\.offset)
        try check(starts == [1, 4, 6, 8] && offsets == [0, 2, 4, 6] && bed.comp.allSatisfy { $0.length <= 2 },
                  "loop content repeats every 2 s with shifted material (\(starts))")
        try check(bed.segment(at: 7.2) == nil, "copies overwrite what was there")
        let loop4 = TimeRange(start: 0, end: 8)
        try check(Session.jamEnd(loop: loop4, stoppedAt: 30, beat: 0.5) == 32, "stop mid-pass rounds up to a whole pass")
        try check(Session.jamEnd(loop: loop4, stoppedAt: 32.3, beat: 0.5) == 32, "stop just into a new pass doesn't add one")
        try check(Session.jamEnd(loop: loop4, stoppedAt: 3, beat: 0.5) == 8, "always at least one pass")

        print("Automation curve")
        let pts = [AutoPoint(time: 1, value: -10), AutoPoint(time: 3, value: 0)]
        try check(Track.evaluate(pts, at: 0) == -10 && Track.evaluate(pts, at: 2) == -5 && Track.evaluate(pts, at: 9) == 0, "linear interpolation")

        print("Old song files")
        let legacy = #"{"id":"6E0B6C2E-0000-4000-8000-000000000001","name":"Old","takes":[],"comp":[{"takeID":"6E0B6C2E-0000-4000-8000-000000000002","start":1,"end":2}]}"#
        let old = try JSONDecoder().decode(Track.self, from: Data(legacy.utf8))
        try check(old.comp.count == 1 && old.comp[0].offset == 0 && old.inserts.isEmpty && old.autoRead, "pre-region-editing songs still load")

        print("Pitch detector")
        for f0 in [82.41, 196.0, 440.0, 987.8] {
            let sr = 48000.0
            let x = (0..<8192).map { Float(sin(2 * .pi * f0 * Double($0) / sr) * 0.3 + 0.1 * sin(4 * .pi * f0 * Double($0) / sr)) }
            let f = PitchDetector.detect(x, sampleRate: sr) ?? 0
            try check(abs(1200 * log2(max(1, f) / f0)) < 3, String(format: "%.1f Hz detected as %.2f Hz", f0, f))
        }

        print("Input monitor ring")
        let ring = InputRing(channels: 4)
        let reader = MonitorReader(ring: ring, firstChannel: 2)
        reader.enabled.store(true, ordering: .relaxed)
        var silence = ObjCBool(false)
        for cycle in 0..<5 {
            // Write 256 frames of 4 interleaved... deinterleaved channels where channel c = c + cycle.
            let bufs = (0..<4).map { c in [Float](repeating: Float(c * 10 + cycle), count: 256) }
            try bufs.withUnsafeBufferPointersHelper { ptrs in
                let abl = AudioBufferList.allocate(maximumBuffers: 4)
                defer { free(abl.unsafeMutablePointer) }
                for c in 0..<4 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 1024, mData: UnsafeMutableRawPointer(mutating: ptrs[c])) }
                ring.write(abl.unsafePointer, frames: 256)
            }
            let outAbl = AudioBufferList.allocate(maximumBuffers: 1)
            let out = [Float](repeating: -1, count: 256)
            try out.withUnsafeBufferPointer { op in
                outAbl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 1024, mData: UnsafeMutableRawPointer(mutating: op.baseAddress!))
                _ = reader.render(&silence, 256, outAbl.unsafeMutablePointer)
                if cycle == 4 { try check(op[0] == Float(20 + 4) && op[255] == Float(20 + 4), "reader follows channel 3 with one-buffer latency") }
            }
            free(outAbl.unsafeMutablePointer)
        }

        print("Offline renders")
        let audio = AudioEngine()
        var song = Song(name: "Test")
        song.clickEnabled = false
        song.master.limiterOn = false
        audio.build(song: song, inputDevice: nil, outputDevice: nil)
        let sr = audio.sampleRate
        print("  sample rate \(sr)")

        func tone(_ name: String, _ freq: Double) throws {
            let f = try Recorder.makeFile(url: audioDir.appendingPathComponent(name), sampleRate: sr, channels: 1)
            let n = AVAudioFrameCount(sr * 4)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
            buf.frameLength = n
            for i in 0..<Int(n) { buf.floatChannelData![0][i] = Float(sin(2 * .pi * freq * Double(i) / sr) * 0.5) }
            try f.write(from: buf)
        }
        try tone("t1.caf", 440)
        try tone("t2.caf", 880)

        // 1. Comp across takes plus a MIDI note.
        var track = Track(name: "Vox")
        let t1 = Take(name: "Take 1", fileName: "t1.caf", start: 1, duration: 4)
        let t2 = Take(name: "Take 2", fileName: "t2.caf", start: 1, duration: 4)
        track.takes = [t1, t2]
        track.assign(takeID: t1.id, over: t1.range)
        track.assign(takeID: t2.id, over: TimeRange(start: 3, end: 4))
        var keys = Track(name: "Keys", kind: .midi, channels: 2)
        let mt = Take(name: "Take 1", start: 6, duration: 2, notes: [MIDINote(pitch: 60, velocity: 110, start: 0, duration: 1)])
        keys.takes = [mt]
        keys.assign(takeID: mt.id, over: mt.range)
        song.tracks = [track, keys]
        var mix = try render(song, audio: audio, dir: dir, length: 9, name: "comp.wav")
        let take1 = mix.window(1.5, 2.5), comped = mix.window(3.2, 3.8), back = mix.window(4.2, 4.8)
        try check(mix.window(0.1, 0.9).rms < 0.001, "silence before the first take")
        try check(take1.rms > 0.1 && abs(take1.freq - 440) < 15, "take 1 plays at 1 s (440 Hz)")
        try check(comped.rms > 0.1 && abs(comped.freq - 880) < 25, "comp switches to take 2 at 3–4 s")
        try check(back.rms > 0.1 && abs(back.freq - 440) < 15, "comp returns to take 1 after 4 s")
        try check(mix.window(5.3, 5.9).rms < 0.01, "silence between audio and MIDI")
        try check(mix.window(6.1, 6.8).rms > 0.005, "MIDI note renders through the built-in sampler")
        try check(abs(mix.onset(after: 0) - 1) * 1000 < 5, "take starts sample-accurately at 1 s")

        // 1b. A split in continuous audio is seamless (crossfade, no dip at the edit).
        var seamless = Track(name: "Seam")
        seamless.takes = [t1]
        seamless.assign(takeID: t1.id, over: t1.range)
        seamless.splitSegment(seamless.comp[0].id, at: 3)
        song.tracks = [seamless]
        mix = try render(song, audio: audio, dir: dir, length: 5, name: "seam.wav")
        let atEdit = mix.window(2.998, 3.004).rms, around = mix.window(2.9, 2.99).rms
        print(String(format: "  split edge rms %.4f vs %.4f", atEdit, around))
        try check(atEdit > around * 0.9, "no dip at a split point")

        // 1c. JAM paste-out: a 2 s loop of take 1 repeated to 9 s plays the whole way.
        var jammed = Track(name: "Bed")
        jammed.takes = [t1]
        jammed.assign(takeID: t1.id, over: TimeRange(start: 1, end: 3))
        song.tracks = [jammed]
        song = song.tilingLoop(TimeRange(start: 1, end: 3), until: 9, excluding: [])
        mix = try render(song, audio: audio, dir: dir, length: 10, name: "jam.wav")
        let rep = mix.window(7.2, 8.8), boundary = mix.window(4.995, 5.005)
        print(String(format: "  jam: repeat %.3f@%.0fHz, boundary %.3f, after %.4f", rep.rms, rep.freq, boundary.rms, mix.window(9.2, 9.8).rms))
        try check(rep.rms > 0.1 && abs(rep.freq - 440) < 15 && boundary.rms > rep.rms * 0.9, "pasted-out loop plays seamlessly to the end")
        try check(mix.window(9.2, 9.8).rms < 0.001, "and stops where the take ended")

        // 2. Region moved by +2 s with a 1 s fade-in, and volume automation.
        var moved = track
        moved.trimSegment(moved.comp[0].id, end: 3)   // first region: 1–3 s from take 1
        moved.removeSegments(Set(moved.comp.dropFirst().map(\.id)))
        moved.moveSegment(moved.comp[0].id, by: 2)      // now 3–5 s
        moved.setFades(moved.comp[0].id, fadeIn: 1)
        song.tracks = [moved]
        mix = try render(song, audio: audio, dir: dir, length: 7, name: "moved.wav")
        try check(abs(mix.onset(after: 0, threshold: 0.001) - 3) < 0.01, "moved region starts at 3 s")
        try check(mix.window(3.0, 3.15).rms < mix.window(4.2, 4.8).rms * 0.5, "fade-in ramps up")
        try check(mix.window(5.2, 6.0).rms < 0.001, "moved region ends at 5 s")

        var automated = moved
        automated.setFades(automated.comp[0].id, fadeIn: 0)
        automated.volumeAuto = [AutoPoint(time: 0, value: -60), AutoPoint(time: 3.9, value: -60), AutoPoint(time: 4.0, value: 0)]
        song.tracks = [automated]
        mix = try render(song, audio: audio, dir: dir, length: 6, name: "auto.wav")
        let muted = mix.window(3.2, 3.8).rms, loud = mix.window(4.2, 4.8).rms
        print(String(format: "  automation: before %.4f after %.4f", muted, loud))
        try check(muted < 0.001 && loud > 0.1, "volume automation silences then opens up at 4 s")

        // 3. Apple Audio Units: a low-pass insert and the DLS synth as an instrument.
        var fx = track
        let lowpass = PluginSlot(name: "AULowpass", manufacturer: "Apple", type: kAudioUnitType_Effect,
                                 subType: kAudioUnitSubType_LowPassFilter, manufacturerCode: kAudioUnitManufacturer_Apple)
        fx.inserts = [lowpass]
        var synth = keys
        let dls = PluginSlot(name: "DLSMusicDevice", manufacturer: "Apple", type: kAudioUnitType_MusicDevice,
                             subType: kAudioUnitSubType_DLSSynth, manufacturerCode: kAudioUnitManufacturer_Apple)
        synth.instrument = dls
        song.tracks = [fx, synth]
        audio.sync(song)
        waitForPlugins(audio, [lowpass, dls])
        try check(audio.unit(lowpass.id) != nil && audio.unit(dls.id) != nil,
                  "plugins load (\(audio.pluginErrors.values.joined(separator: ", ")))")
        audio.sync(song)
        try check(audio.tracks[fx.id]?.inserts == [lowpass.id], "insert is wired into the track chain")
        try check(audio.tracks[synth.id]?.instrumentSlot == dls.id, "AU instrument replaces the built-in sampler")
        // Low-pass at 200 Hz should cut the 880 Hz section far more than the 440 Hz one.
        AudioUnitSetParameter(audio.unit(lowpass.id)!.audioUnit, kLowPassParam_CutoffFrequency, kAudioUnitScope_Global, 0, 200, 0)
        mix = try render(song, audio: audio, dir: dir, length: 9, name: "plugins.wav")
        let lp440 = mix.window(1.5, 2.5).rms, lp880 = mix.window(3.2, 3.8).rms
        print(String(format: "  low-passed: 440 Hz %.4f, 880 Hz %.4f", lp440, lp880))
        try check(lp440 > 0.005 && lp880 < lp440 * 0.6, "insert plugin processes the audio")
        try check(mix.window(6.1, 6.8).rms > 0.002, "MIDI plays through the AU instrument")
        try check(audio.pluginState(lowpass.id) != nil, "plugin state can be saved")

        print("Undo")
        let projectDir = dir.appendingPathComponent("UndoSong")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let session = Session(projectURL: projectDir, song: Song.newIdea())
        defer { session.close() }
        try check(!session.canUndo, "nothing to undo in a new song")
        session.beginGesture()
        for end in stride(from: 9.0, through: 16.0, by: 1) {   // a loop-edge drag: many previews
            session.previewGesture { $0.loop = TimeRange(start: 4, end: end); $0.loopEnabled = true }
        }
        session.endGesture()
        try check(session.canUndo && session.song.loop.end == 16, "a whole drag is one undo step")
        session.undo()
        try check(session.song.loop == TimeRange(start: 0, end: 8) && !session.song.loopEnabled && !session.canUndo,
                  "undo restores the loop from before the drag")
        session.redo()
        try check(session.song.loop.end == 16 && session.song.loopEnabled, "redo brings it back")
        session.continuousEdit(true)
        session.updateTrack(session.song.tracks[0].id, undoable: false) { $0.strip.volumeDB = -6 }
        session.updateTrack(session.song.tracks[0].id, undoable: false) { $0.strip.volumeDB = -9 }
        session.continuousEdit(false)
        session.undo()
        try check(session.song.tracks[0].strip.volumeDB == 0, "a fader move undoes in one step")
    }
}

private extension Array where Element == [Float] {
    func withUnsafeBufferPointersHelper(_ body: ([UnsafePointer<Float>]) throws -> Void) rethrows {
        var ptrs: [UnsafePointer<Float>] = []
        func recurse(_ i: Int) throws {
            if i == count { try body(ptrs); return }
            try self[i].withUnsafeBufferPointer { p in
                ptrs.append(p.baseAddress!)
                try recurse(i + 1)
                ptrs.removeLast()
            }
        }
        try recurse(0)
    }
}
#endif
