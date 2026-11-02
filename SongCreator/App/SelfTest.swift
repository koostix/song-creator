#if DEBUG
import AVFoundation
import CoreMIDI
import SwiftUI

/// `SongCreator --selftest <folder>`: builds songs in code, renders them offline and
/// checks that audio lands where the arrangement says. Prints results and exits.
enum SelfTest {
    /// `SongCreator --snapshot <folder>`: render the main window at a few widths to PNGs for layout checks.
    static func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.async {
            let project = dir.appendingPathComponent("Snapshot Song")
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var song = Song.newIdea()
            song.name = "Idea Oct 21 1.27 AM"
            song.tracks.append(Track(name: "Track 3", colorIndex: 2))
            var keys = Track(name: "Keys 4", kind: .midi, colorIndex: 3, channels: 2)
            keys.inserts = [PluginSlot(name: "AUDelay", manufacturer: "Apple", type: kAudioUnitType_Effect,
                                       subType: kAudioUnitSubType_Delay, manufacturerCode: kAudioUnitManufacturer_Apple)]
            song.tracks.append(keys)
            song.tracks.append(Track(name: "synth", kind: .midi, colorIndex: 4, channels: 2))
            song.loop = TimeRange(start: 0, end: 8)
            let model = AppModel()
            let session = Session(projectURL: project, song: song)
            let savedJam = Prefs.jamMode   // restored before exit(), which skips defer blocks
            session.jamMode = true
            session.musicalTyping = true
            for (w, mixer) in [(1180.0, false), (1600.0, false), (1180.0, true)] {
                session.showMixer = mixer
                let view = MainView(session: session).environment(model)
                    .frame(width: w, height: mixer ? 900 : 640)
                let r = ImageRenderer(content: view)
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("main-\(Int(w))\(mixer ? "-mixer" : "").png"))
                }
            }
            // Scroll views don't render offscreen, so draw track rows and mixer strips directly.
            session.showMixer = false
            let parts: [(String, AnyView, CGSize)] = [
                ("tracks", AnyView(VStack(spacing: 0) {
                    ForEach(session.song.tracks) { t in
                        TrackRow(session: session, track: t)
                        Divider().overlay(Color.black.opacity(0.6))
                    }
                    AddTrackRow(session: session)
                }.background(Theme.lane)), CGSize(width: 900, height: 480)),
                ("strips", AnyView(HStack(alignment: .top, spacing: 2) {
                    ForEach(session.song.tracks) { t in ChannelStripView(session: session, track: t) }
                    ReturnsStrip(session: session)
                    MasterStrip(session: session)
                }.padding(6).background(Theme.background).environment(\.continuousEdit, session.continuousEdit)),
                 CGSize(width: 760, height: 490)),
            ]
            for (name, v, size) in parts {
                let r = ImageRenderer(content: v.environment(model).frame(width: size.width, height: size.height, alignment: .topLeading)
                    .preferredColorScheme(.dark))
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name).png"))
                }
            }
            // The song list, with a small sample library.
            ProjectStore.rootOverride = dir.appendingPathComponent("Library")
            try? FileManager.default.removeItem(at: ProjectStore.root)
            for (name, project, status, fav) in [("Morning Riff", nil, SongStatus.writing, true),
                                                 ("Night Drive", "Album", .mixing, false),
                                                 ("Glass Hearts", "Album", .done, true),
                                                 ("Idea Oct 21 1.27 AM", nil, .idea, false)] as [(String, String?, SongStatus, Bool)] {
                var song = Song.newIdea()
                song.name = name
                try? FileManager.default.createDirectory(at: SongLibrary.folder(for: project), withIntermediateDirectories: true)
                if let url = try? ProjectStore.create(song, in: SongLibrary.folder(for: project)) {
                    var info = SongInfo(); info.status = status; info.favorite = fav; info.notes = "Chorus needs a lift"
                    try? SongLibrary.writeInfo(info, to: url)
                }
            }
            model.library.refresh()
            let browser = ProjectBrowser().environment(model).frame(width: 1180, height: 640).preferredColorScheme(.dark)
            let details = SongDetails(song: model.library.songs.first { $0.name == "Night Drive" }!,
                                      selection: .constant([]), confirmTrash: .constant([]))
                .environment(model).frame(width: 290, height: 640).background(Theme.panel).preferredColorScheme(.dark)
            for (name, v) in [("browser", AnyView(browser)), ("details", AnyView(details))] {
                let r = ImageRenderer(content: v)
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name).png"))
                }
            }
            Prefs.jamMode = savedJam
            ProjectStore.rootOverride = nil
            print("SNAPSHOT DONE")
            exit(0)
        }
    }

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

        print("Silence while recording")
        var armedT = Track(name: "armed", armed: true)
        let oldTake = Take(name: "old", fileName: "o", start: 0, duration: 10)
        armedT.takes = [oldTake]
        armedT.assign(takeID: oldTake.id, over: oldTake.range)
        var otherT = armedT
        otherT.id = UUID()
        otherT.armed = false
        var rs = Song(name: "r")
        rs.tracks = [armedT, otherT]
        let punchHeard = rs.mutingRecording(tracks: [armedT.id], over: TimeRange(start: 4, end: 8))
        try check(punchHeard.tracks[0].comp.map(\.range) == [TimeRange(start: 0, end: 4), TimeRange(start: 8, end: 10)]
                  && punchHeard.tracks[1].comp.count == 1,
                  "punch: the armed track's old take is silent between punch-in and punch-out; other tracks play")
        let overdubHeard = rs.mutingRecording(tracks: [armedT.id], over: TimeRange(start: 3, end: .greatestFiniteMagnitude))
        try check(overdubHeard.tracks[0].comp.map(\.range) == [TimeRange(start: 0, end: 3)], "overdub: silent from where recording starts")
        try check(rs.tracks[0].comp.count == 1, "the song itself is untouched")

        print("Quantize")
        let spb = 0.5   // 120 BPM
        let q16 = Quantize(grid: .sixteenth)
        try check(abs(q16.apply(0.14, secondsPerBeat: spb) - 0.125) < 1e-9 && abs(q16.apply(0.2, secondsPerBeat: spb) - 0.25) < 1e-9,
                  "1/16 at 120 BPM snaps to 125 ms steps")
        try check(abs(Quantize(grid: .quarter, strength: 0.5).apply(0.6, secondsPerBeat: spb) - 0.55) < 1e-9, "50% strength moves halfway")
        try check(abs(Quantize(grid: .eighthTriplet).apply(0.17, secondsPerBeat: spb) - 1.0 / 6) < 1e-9, "triplet grid")
        let swung = Quantize(grid: .eighth, swing: 0.66)
        try check(abs(swung.apply(0.3, secondsPerBeat: spb) - 0.33) < 1e-9 && abs(swung.apply(0.48, secondsPerBeat: spb) - 0.5) < 1e-9,
                  "66% swing pushes the off-beat eighth late, leaves the beat alone")

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
        // A device change rebuilds the engine while the old one is still alive (the configuration-change
        // notification holds it). Shared nodes must move over without AVAudioEngine throwing.
        let oldEngine = audio.engine
        audio.build(song: song, inputDevice: nil, outputDevice: nil)
        audio.build(song: song, inputDevice: nil, outputDevice: nil)
        try check(oldEngine !== audio.engine && audio.masterMixer.engine === audio.engine,
                  "engine rebuilds while the old engine is still alive")
        let sr = audio.sampleRate
        print("  sample rate \(sr)\(audio.inputProblem.map { " — " + $0 } ?? "")")
        try check(!audio.hasInput || audio.inputSampleRate == sr,
                  "input is only opened when it matches the output rate")

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

        // AAC tops out at 48 kHz, so mixdowns from a higher device rate must be converted, at the right speed.
        if let spk = AudioDevices.all().first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
            let spkRate = AudioDevices.sampleRate(spk.id)
            AudioDevices.setSampleRate(spk.id, 96000)
            defer { AudioDevices.setSampleRate(spk.id, spkRate) }
            let hi = AudioEngine()
            hi.build(song: Song.newIdea(), inputDevice: nil, outputDevice: spk.id, inputEnabled: false)
            let hiDir = dir.appendingPathComponent("HiRate")
            try FileManager.default.createDirectory(at: hiDir.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            let hsr = hi.sampleRate
            let hf = try Recorder.makeFile(url: hiDir.appendingPathComponent("Audio/tone.caf"), sampleRate: hsr, channels: 1)
            let hn = AVAudioFrameCount(hsr * 2)
            let hb = AVAudioPCMBuffer(pcmFormat: hf.processingFormat, frameCapacity: hn)!
            hb.frameLength = hn
            for i in 0..<Int(hn) { hb.floatChannelData![0][i] = Float(sin(2 * .pi * 440 * Double(i) / hsr) * 0.5) }
            try hf.write(from: hb)
            var hs = Song(name: "hi")
            var ht = Track(name: "t")
            let htake = Take(name: "t", fileName: "tone.caf", start: 0, duration: 2)
            ht.takes = [htake]
            ht.assign(takeID: htake.id, over: htake.range)
            hs.tracks = [ht]
            hi.sync(hs)
            let ht2 = Transport(audio: hi, audioFolder: hiDir.appendingPathComponent("Audio"), song: hs)
            let aac = hiDir.appendingPathComponent("mix.m4a")
            try ht2.queue.sync {
                try Exporter.render(audio: hi, transport: ht2, song: hs, range: TimeRange(start: 0, end: 2), to: aac, format: .aac) { _ in }
            }
            let af = try AVAudioFile(forReading: aac)
            let secs = Double(af.length) / af.fileFormat.sampleRate
            print(String(format: "  AAC from %.0f Hz: file %.0f Hz, %.3f s", hsr, af.fileFormat.sampleRate, secs))
            try check(abs(secs - 2) < 0.1, "AAC mixdown from a 96 kHz device has the right length")
            let ab = AVAudioPCMBuffer(pcmFormat: af.processingFormat, frameCapacity: AVAudioFrameCount(af.length))!
            try af.read(into: ab)
            let am = Mix(data: Array(UnsafeBufferPointer(start: ab.floatChannelData![0], count: Int(ab.frameLength))), sr: af.processingFormat.sampleRate)
            let aw = am.window(0.5, 1.5)
            try check(aw.rms > 0.1 && abs(aw.freq - 440) < 15, "and the right pitch (\(Int(aw.freq)) Hz)")
            hi.shutdown()
        }

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
        print(String(format: "  comp mix: take1 %.4f@%.0fHz comp %.4f@%.0fHz back %.4f", take1.rms, take1.freq, comped.rms, comped.freq, back.rms))
        try check(mix.window(0.1, 0.9).rms < 0.001, "silence before the first take")
        try check(take1.rms > 0.1 && abs(take1.freq - 440) < 15, "take 1 plays at 1 s (440 Hz)")
        try check(comped.rms > 0.1 && abs(comped.freq - 880) < 25, "comp switches to take 2 at 3–4 s")
        try check(back.rms > 0.1 && abs(back.freq - 440) < 15, "comp returns to take 1 after 4 s")
        try check(mix.window(5.3, 5.9).rms < 0.01, "silence between audio and MIDI")
        try check(mix.window(6.1, 6.8).rms > 0.005, "MIDI note renders through the built-in sampler")
        // Quantize moves a late note onto the beat in the rendered audio.
        var lateKeys = Track(name: "Late", kind: .midi, channels: 2)
        let lateTake = Take(name: "t", start: 0, duration: 2, notes: [MIDINote(pitch: 60, velocity: 110, start: 0.53, duration: 0.5)])
        lateKeys.takes = [lateTake]
        lateKeys.assign(takeID: lateTake.id, over: lateTake.range)
        var qSong = song
        qSong.tempo = 120
        qSong.tracks = [lateKeys]
        let asPlayed = try render(qSong, audio: audio, dir: dir, length: 1.5, name: "q-off.wav").onset(after: 0, threshold: 0.002)
        qSong.tracks[0].quantize = Quantize(grid: .quarter)
        let onGrid = try render(qSong, audio: audio, dir: dir, length: 1.5, name: "q-on.wav").onset(after: 0, threshold: 0.002)
        print(String(format: "  onset as played %.4f s, quantized %.4f s", asPlayed, onGrid))
        try check(abs((asPlayed - onGrid) - 0.03) < 0.003, "quantize moves a note played 30 ms late onto the beat")
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
        // Editor windows need a fully launched app (out-of-process plugin views are remote views), so they're
        // covered by the in-app `--plugintest`, not here.

        // A device change mid-session: plugins reload into the new engine with their settings.
        audio.build(song: song, inputDevice: nil, outputDevice: nil)
        waitForPlugins(audio, [lowpass, dls])
        audio.sync(song)
        mix = try render(song, audio: audio, dir: dir, length: 9, name: "plugins-rebuilt.wav")
        let re440 = mix.window(1.5, 2.5).rms, re880 = mix.window(3.2, 3.8).rms
        print(String(format: "  after rebuild: 440 Hz %.4f, 880 Hz %.4f", re440, re880))
        try check(re440 > 0.005 && re880 < re440 * 0.6 && mix.window(6.1, 6.8).rms > 0.002,
                  "after an engine rebuild, plugins come back with their settings")

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

        print("Musical typing and zoom")
        session.selectedTrackID = session.song.tracks[0].id   // an audio track, as in a new song
        session.musicalTyping = true
        try check(session.song.tracks.contains { $0.kind == .midi } && session.midiTargets.count == 1,
                  "KEYS adds a MIDI track when the song has none")
        // Typed notes must actually sound, even with an audio track selected.
        // Mark the session busy like an export does, so a device change (other apps can switch the mic's rate)
        // doesn't rebuild the engine mid-render.
        session.exportProgress = 0
        defer { session.exportProgress = nil }
        let eng = session.audio.engine
        try session.audio.enableOfflineRendering()
        try eng.start()
        session.selectedTrackID = session.song.tracks[0].id
        _ = session.typingKeyDown("h", keyCode: 4, isRepeat: false)   // A above middle C
        let kb = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 4096)!
        var sum = 0.0, count = 0
        for _ in 0..<8 {
            _ = try eng.renderOffline(4096, to: kb)
            for i in 0..<Int(kb.frameLength) { sum += Double(kb.floatChannelData![0][i] * kb.floatChannelData![0][i]) }
            count += Int(kb.frameLength)
        }
        _ = session.typingKeyUp(keyCode: 4)
        eng.stop()
        eng.disableManualRenderingMode()
        let typedRMS = sqrt(sum / Double(max(1, count)))
        print(String(format: "  typed note rms %.4f", typedRMS))
        try check(typedRMS > 0.002, "a typed note plays through the MIDI track's instrument")
        try check(session.typingKeyDown("a", keyCode: 0, isRepeat: false) && session.typingKeyDown("k", keyCode: 40, isRepeat: false),
                  "A and K are note keys")
        try check(!session.typingKeyDown("r", keyCode: 15, isRepeat: false), "R stays free for record")
        _ = session.typingKeyDown("x", keyCode: 7, isRepeat: false)
        try check(session.typingOctave == 5 && Session.noteName(12 * (session.typingOctave + 1)) == "C5", "X moves up an octave")
        try check(session.typingKeyUp(keyCode: 0) && session.typingKeyUp(keyCode: 40) && !session.typingKeyUp(keyCode: 0),
                  "notes release by key, even after an octave change")
        _ = session.typingKeyDown("s", keyCode: 1, isRepeat: false)
        session.musicalTyping = false
        try check(!session.typingKeyUp(keyCode: 1), "turning typing off releases held notes")
        session.timelineWidth = 1000
        session.edit { s in
            s.tempo = 120
            s.tracks[0].takes = [Take(name: "T", fileName: "t1.caf", start: 0, duration: 60)]
            s.tracks[0].assign(takeID: s.tracks[0].takes[0].id, over: TimeRange(start: 0, end: 60))
        }
        session.scrollX = 30
        session.zoomToFit()
        try check(session.scrollX == 0 && abs(session.pixelsPerSecond * 60 * 1.04 - 1000) < 0.01, "zoom to fit shows the whole song")

        print("Song library")
        let libRoot = dir.appendingPathComponent("Library")
        ProjectStore.rootOverride = libRoot
        defer { ProjectStore.rootOverride = nil }
        let lib = SongLibrary()
        var songA = Song.newIdea(); songA.name = "Morning Riff"; songA.tempo = 92
        var songB = Song.newIdea(); songB.name = "Night Drive"
        _ = try ProjectStore.create(songA)
        try FileManager.default.createDirectory(at: libRoot.appendingPathComponent("Album"), withIntermediateDirectories: true)
        _ = try ProjectStore.create(songB, in: SongLibrary.folder(for: "Album"))
        lib.refresh()
        try check(lib.songs.count == 2 && lib.projects == ["Album"] && lib.count(.ungrouped) == 1 && lib.count(.project("Album")) == 1,
                  "finds songs at the top and inside projects")
        let riff = lib.songs.first { $0.name == "Morning Riff" }!
        try check(riff.tempo == 92 && riff.info.status == .idea, "reads song details and default status")
        lib.update(riff) { $0.status = .mixing; $0.favorite = true; $0.notes = "needs a bridge" }
        lib.refresh()
        let riff2 = lib.songs.first { $0.name == "Morning Riff" }!
        try check(riff2.info.status == .mixing && riff2.info.favorite && lib.count(.favorites) == 1,
                  "status, favorite and notes persist in info.json")
        try check(lib.songs(in: .all, search: "bridge", status: nil).count == 1 &&
                  lib.songs(in: .all, search: "", status: .mixing).count == 1, "search covers notes; status filter works")
        let renamed = lib.rename(riff2, to: "Sunrise")
        try check(renamed?.lastPathComponent == "Sunrise" && (try? ProjectStore.load(renamed!).name) == "Sunrise"
                  && SongLibrary.readInfo(renamed!).notes == "needs a bridge", "rename moves the folder and keeps details")
        let sunrise = lib.songs.first { $0.name == "Sunrise" }!
        let movedTo = lib.move(sunrise, to: "Album")
        try check(movedTo?.deletingLastPathComponent().lastPathComponent == "Album" && lib.count(.project("Album")) == 2,
                  "move into a project")
        let copy = lib.duplicate(lib.songs.first { $0.name == "Sunrise" }!)
        let copySong = copy.flatMap { try? ProjectStore.load($0) }
        try check(copySong?.name == "Sunrise copy" && lib.songs.count == 3
                  && copySong?.id != lib.songs.first { $0.name == "Sunrise" }.flatMap { try? ProjectStore.load($0.url) }?.id,
                  "duplicate makes an independent copy")
        // Several songs at once.
        lib.refresh()
        let pair = lib.songs.filter { $0.project == "Album" }
        let out = lib.move(pair, to: nil)
        try check(out.count == pair.count && lib.count(.project("Album")) == 0 && lib.count(.ungrouped) == lib.songs.count,
                  "move several songs out of a project at once")
        let movedBack = lib.move(lib.songs.filter { out.contains($0.url) }, to: "Album")
        try check(movedBack.count == pair.count && lib.count(.project("Album")) == pair.count, "and back into it")
        lib.update(lib.songs) { $0.status = .done }
        lib.refresh()
        try check(lib.songs.allSatisfy { $0.info.status == .done }, "set status on several songs")
        let tok = SongLibrary.dragToken(lib.songs[0].url)
        try check(SongLibrary.url(fromDragToken: tok)?.standardizedFileURL == lib.songs[0].url.standardizedFileURL
                  && SongLibrary.url(fromDragToken: "/Users/x") == nil, "drag token round-trips; plain text is ignored")

        let ep = lib.createProject("EP")
        let ep2 = lib.createProject("EP")
        try check(ep == "EP" && ep2 == "EP 2", "new projects get unique names")
        let renamedProject = lib.renameProject("EP 2", to: "Live Session")
        try check(renamedProject == "Live Session" && lib.projects.contains("Live Session"), "rename a project")

        print("Multichannel inputs")
        try check(AudioEngine.floatFormat(48000, channels: 4)?.channelCount == 4 && AudioEngine.floatFormat(48000, channels: 18)?.channelCount == 18,
                  "formats for 4- and 18-input interfaces (the plain initializer gives nil above 2)")

        print("Explicit device choices")
        if let mic = AudioDevices.all().first(where: { $0.uid == "BuiltInMicrophoneDevice" }),
           let spk = AudioDevices.all().first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
            // Chosen devices must really be used, even while another device (e.g. Bluetooth) is the system default.
            let micRate = AudioDevices.sampleRate(mic.id)
            defer { AudioDevices.setSampleRate(mic.id, micRate) }
            let chosen = AudioEngine()
            chosen.build(song: Song.newIdea(), inputDevice: mic.id, outputDevice: spk.id, inputEnabled: true)
            var chosenStarted = true
            do { try chosen.start() } catch { chosenStarted = false }
            let r0 = chosen.renderSample(atHost: HostTime.now) ?? 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let r1 = chosen.renderSample(atHost: HostTime.now) ?? 0
            print("  chosen mic + speakers: ownIO=\(chosen.usesOwnIO) rate=\(chosen.sampleRate) speakers=\(AudioDevices.sampleRate(spk.id)) "
                  + "input=\(chosen.hasInput) ch=\(chosen.inputChannelCount) advanced=\(r1 - r0) latency out \(String(format: "%.1f", chosen.outputLatency * 1000)) ms")
            let f0 = chosen.lastRenderedSample
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let f1 = chosen.lastRenderedSample
            print("  rendered in 1 s: \(f1 - f0) frames (rate \(chosen.sampleRate))")
            try check(chosenStarted && chosen.usesOwnIO && chosen.sampleRate == AudioDevices.sampleRate(spk.id) && r1 - r0 > Int64(chosen.sampleRate * 0.2),
                      "mic + speakers chosen: runs on those devices at their rate and keeps rendering")
            if chosen.hasInput {
                try check(chosen.inputChannelCount == 1 && chosen.canMonitorInput, "the mic is captured (1 channel) and can be monitored")
            }
            chosen.shutdown()
            chosen.destroyAggregate()
            let out = AudioEngine()
            out.build(song: Song.newIdea(), inputDevice: mic.id, outputDevice: spk.id, inputEnabled: false)
            var outStarted = true
            do { try out.start() } catch { outStarted = false }
            try check(outStarted && out.sampleRate > 0 && out.usesOwnIO, "speakers chosen with input off: engine starts on them")
            out.shutdown()
            out.build(song: Song.newIdea(), inputDevice: mic.id, outputDevice: spk.id, inputEnabled: true)
            var bothStarted = true
            do { try out.start() } catch { bothStarted = false }
            try check(bothStarted, "mic + speakers chosen in Settings: engine starts (\(out.inputProblem ?? "input open"))")
            out.shutdown()
            out.destroyAggregate()
        }

        print("Input switch and feedback protection")
        let savedInput = Prefs.inputEnabled, savedProtection = Prefs.feedbackProtection
        defer { Prefs.inputEnabled = savedInput; Prefs.feedbackProtection = savedProtection }
        for d in AudioDevices.all() where d.outputChannels > 0 {
            print("  output \(d.name): speakers=\(AudioDevices.isBuiltInSpeakers(d.id))")
        }
        if let speakers = AudioDevices.all().first(where: { $0.name.contains("MacBook") && $0.outputChannels > 0 }) {
            try check(AudioDevices.isBuiltInSpeakers(speakers.id), "the MacBook's built-in speakers are detected")
        }
        try check(AudioDevices.all().filter { $0.name.hasPrefix("BlackHole") }.allSatisfy { !AudioDevices.isBuiltInSpeakers($0.id) },
                  "virtual devices are not treated as speakers")

        session.inputEnabled = false
        try check(!session.audio.hasInput && !session.audio.canMonitorInput && session.audio.inputChannelCount == 0,
                  "input off: the mic is never opened and nothing can monitor")
        session.inputEnabled = true

        let audioTrack = session.song.tracks.first { $0.kind == .audio }!.id
        session.updateTrack(audioTrack, undoable: false) { $0.monitor = true }
        let monitorOn = { session.audio.tracks[audioTrack]?.monitorReader?.enabled.load(ordering: .relaxed) ?? false }
        session.feedbackProtection = true
        print("  on speakers: \(session.onSpeakers), input usable: \(session.audio.canMonitorInput)")
        if session.onSpeakers {
            try check(session.monitoringMuted && !monitorOn(), "on speakers, protection keeps a monitoring track silent")
        }
        session.feedbackProtection = false
        try check(!session.monitoringMuted && monitorOn() == session.audio.canMonitorInput,
                  "with protection off, monitoring follows the I button")
        session.feedbackProtection = true
        session.updateTrack(audioTrack, undoable: false) { $0.monitor = false }

        print("Renaming tracks with Tab")
        while session.song.tracks.count < 3 { session.addTrack(kind: .audio) }
        let ids = session.song.tracks.map(\.id)
        session.startRenaming(ids[0])
        session.renameNext(forward: true)
        try check(session.renamingTrackID == ids[1] && session.selectedTrackID == ids[1], "Tab moves to the next track and selects it")
        session.renameNext(forward: false)
        try check(session.renamingTrackID == ids[0], "⇧Tab moves back")
        session.renameNext(forward: false)
        try check(session.renamingTrackID == nil, "⇧Tab on the first track finishes")
        session.startRenaming(ids[ids.count - 1])
        session.renameNext(forward: true)
        try check(session.renamingTrackID == nil, "Tab on the last track finishes")

        print("New-song default")
        do {
            let saveRoot = ProjectStore.rootOverride
            ProjectStore.rootOverride = dir.appendingPathComponent("TemplateLib")
            defer { ProjectStore.rootOverride = saveRoot }
            ProjectStore.clearTemplate()
            try check(ProjectStore.newSong().tracks.count == 1, "without a default, New Song is the plain one-track start")
            var setup = Song.newIdea()
            setup.tempo = 94
            setup.countInBars = 2
            var keysT = Track(name: "Synth", kind: .midi, channels: 2)
            keysT.external = ExternalMIDI(deviceID: 42, deviceName: "Prophet", channel: 3)
            keysT.takes = [Take(name: "t", start: 0, duration: 2, notes: [MIDINote(pitch: 60, velocity: 100, start: 0, duration: 1)])]
            keysT.assign(takeID: keysT.takes[0].id, over: keysT.takes[0].range)
            keysT.volumeAuto = [AutoPoint(time: 0, value: -6)]
            keysT.strip.reverbSend = 0.4
            keysT.inserts = [PluginSlot(name: "Comp", manufacturer: "X", type: 1, subType: 2, manufacturerCode: 3, state: Data([1, 2, 3]))]
            setup.tracks.append(keysT)
            setup.markers = [Marker(name: "Verse", position: 4)]
            try ProjectStore.saveTemplate(setup)
            let fresh = ProjectStore.newSong()
            let synth = fresh.tracks.first { $0.name == "Synth" }
            try check(fresh.tracks.count == 2 && fresh.tempo == 94 && fresh.countInBars == 2 && fresh.markers.isEmpty,
                      "New Song starts from the saved setup (tracks, tempo, count-in), without markers")
            try check(synth?.takes.isEmpty == true && synth?.comp.isEmpty == true && synth?.volumeAuto.isEmpty == true,
                      "recordings and automation are left out")
            try check(synth?.external?.deviceName == "Prophet" && synth?.external?.channel == 3 && synth?.strip.reverbSend == 0.4
                      && synth?.inserts.first?.state == Data([1, 2, 3]),
                      "instrument (external MIDI), strip and plugin settings carry over")
            let again = ProjectStore.newSong()
            try check(synth?.id != keysT.id && again.tracks.last?.id != synth?.id && synth?.inserts.first?.id != keysT.inserts.first?.id
                      && fresh.id != again.id, "every new song gets fresh IDs")
            ProjectStore.clearTemplate()
            try check(ProjectStore.newSong().tracks.count == 1, "reset goes back to the plain start")
        }

        print("External MIDI device")
        do {
            // A virtual MIDI device in this process records what it receives.
            final class Received: @unchecked Sendable {
                let lock = NSLock()
                var events: [(status: UInt8, d1: UInt8, d2: UInt8, time: UInt64)] = []
                func add(_ e: (UInt8, UInt8, UInt8, UInt64)) { lock.lock(); events.append(e); lock.unlock() }
                func all() -> [(status: UInt8, d1: UInt8, d2: UInt8, time: UInt64)] { lock.lock(); defer { lock.unlock() }; return events }
            }
            let received = Received()
            var client = MIDIClientRef(), virtualDest = MIDIEndpointRef()
            MIDIClientCreateWithBlock("SelfTest MIDI" as CFString, &client, nil)
            MIDIDestinationCreateWithProtocol(client, "SC Test Synth" as CFString, ._1_0, &virtualDest) { list, _ in
                for packet in list.unsafeSequence() {
                    let count = Int(packet.pointee.wordCount)
                    let words: [UInt32] = withUnsafeBytes(of: packet.pointee.words) { Array($0.bindMemory(to: UInt32.self).prefix(count)) }
                    for w in words where w >> 28 == 0x2 {
                        received.add((UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F), packet.pointee.timeStamp))
                    }
                }
            }
            defer { MIDIEndpointDispose(virtualDest); MIDIClientDispose(client) }
            var vid: Int32 = 0
            MIDIObjectGetIntegerProperty(virtualDest, kMIDIPropertyUniqueID, &vid)
            // macOS publishes a new MIDI device asynchronously.
            let listDeadline = Date().addingTimeInterval(3)
            while Date() < listDeadline, !MIDIOutput.destinations().contains(where: { $0.id == vid }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            try check(MIDIOutput.destinations().contains { $0.id == vid }, "MIDI outputs include the device")

            let extDir = dir.appendingPathComponent("ExternalSong")
            try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
            var es = Song(name: "ext")
            es.clickEnabled = false
            es.countInBars = 0
            var synthT = Track(name: "Synth", kind: .midi, channels: 2, armed: true)
            synthT.external = ExternalMIDI(deviceID: vid, deviceName: "SC Test Synth", channel: 5)
            let noteTake = Take(name: "t", start: 0, duration: 2, notes: [MIDINote(pitch: 64, velocity: 90, start: 0.5, duration: 0.25)])
            synthT.takes = [noteTake]
            synthT.assign(takeID: noteTake.id, over: noteTake.range)
            es.tracks = [synthT]
            let es2 = Session(projectURL: extDir, song: es)
            defer { es2.close() }

            es2.handleMIDI(0x90, 60, 100, HostTime.now)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try check(received.all().contains { $0.status == 0x94 && $0.d1 == 60 && $0.d2 == 100 },
                      "a live note goes to the device on channel 5")
            es2.handleMIDI(0x80, 60, 0, HostTime.now)

            let before = received.all().count
            es2.play(from: 0)
            let anchor = es2.transport.timing?.anchorHost ?? 0
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let played = received.all().dropFirst(before)
            let noteOn = played.first { $0.status == 0x94 && $0.d1 == 64 && $0.d2 == 90 }
            let noteOff = played.first { $0.status == 0x84 && $0.d1 == 64 }
            let due = 0.5 + es2.audio.outputLatency
            let sent = noteOn.map { HostTime.seconds($0.time) - HostTime.seconds(anchor) } ?? -1
            print(String(format: "  note-on timestamp %.3f s after start (due %.3f s)", sent, due))
            try check(noteOn != nil && noteOff != nil && abs(sent - due) < 0.005, "recorded notes play back to the device, timestamped on time")
            es2.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try check(received.all().contains { $0.status == 0xB4 && $0.d1 == 123 }, "stop sends all-notes-off to the device")
        }

        print("Timeline zoom per song")
        do {
            let zdir = dir.appendingPathComponent("ZoomSong")
            try FileManager.default.createDirectory(at: zdir, withIntermediateDirectories: true)
            var zs = Song.newIdea()
            zs.tempo = 120
            let first = Session(projectURL: zdir, song: zs)
            first.timelineWidth = 1000
            try check(abs(first.pixelsPerSecond * max(zs.contentEnd, zs.secondsPerBar * 8) * 1.04 - 1000) < 0.01,
                      "a song with no saved view opens zoomed to fit")
            first.pixelsPerSecond = 123
            first.scrollX = 7
            first.close()
            let reopened = Session(projectURL: zdir, song: zs)
            reopened.timelineWidth = 1000
            try check(reopened.pixelsPerSecond == 123 && reopened.scrollX == 7, "reopening restores the last zoom and scroll")
            reopened.close()
            var all = UserDefaults.standard.dictionary(forKey: "timelineView") ?? [:]
            all[zs.id.uuidString] = nil
            UserDefaults.standard.set(all, forKey: "timelineView")
        }

        print("Release checks")
        do {
            // Every saved field must survive a save and load (custom decoders can silently drop one).
            var full = Song(name: "Full")
            full.tempo = 91; full.beatsPerBar = 3; full.sampleRate = 48000; full.loop = TimeRange(start: 1, end: 2)
            full.loopEnabled = true; full.punch = TimeRange(start: 3, end: 4); full.punchEnabled = true
            full.clickEnabled = false; full.clickOnlyWhileRecording = true; full.clickVolume = 0.3; full.countInBars = 2
            full.autoArm = .nextTrack; full.markers = [Marker(name: "M", position: 2)]
            full.master = MasterSettings(volumeDB: -3, limiterOn: false, reverbRoom: .hall, reverbReturnDB: -1,
                                         delayDivision: .eighth, delayFeedback: 12, delayReturnDB: -2)
            var ft = Track(name: "T", kind: .midi, colorIndex: 2, channels: 1, inputChannel: 3, armed: true, mute: true, solo: true,
                           showTakes: true, program: 5, monitor: true, autoRead: false, showAutomation: true, autoParam: .pan)
            ft.strip = ChannelStrip(volumeDB: -1, pan: 0.2, eqOn: false, hpfOn: true, lowGain: 1, midGain: 2, midFreq: 900, highGain: 3,
                                    compOn: true, compThreshold: -9, compMakeup: 5, reverbSend: 0.1, delaySend: 0.2)
            ft.takes = [Take(name: "K", fileName: "f.caf", fileOffset: 0.5, start: 1, duration: 2, notes: [MIDINote(pitch: 60, velocity: 90, start: 0.1, duration: 0.2)])]
            ft.comp = [CompSegment(takeID: ft.takes[0].id, start: 1, end: 2, offset: 0.25, fadeIn: 0.1, fadeOut: 0.2)]
            ft.volumeAuto = [AutoPoint(time: 1, value: -2)]
            ft.panAuto = [AutoPoint(time: 2, value: 0.5)]
            ft.inserts = [PluginSlot(name: "P", manufacturer: "X", type: 1, subType: 2, manufacturerCode: 3, bypass: true, state: Data([9]))]
            ft.instrument = PluginSlot(name: "I", manufacturer: "Y", type: 4, subType: 5, manufacturerCode: 6)
            var ext = ExternalMIDI(deviceID: 7, deviceName: "D", channel: 9); ext.audioReturn = true; ext.latencyMs = 5
            ft.external = ext
            ft.quantize = Quantize(grid: .eighthTriplet, strength: 0.5, swing: 0.6)
            full.tracks = [ft]
            let round = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(full))
            try check(round == full, "every saved field survives a save and load")
            let sparse = try JSONDecoder().decode(Song.self, from: Data(#"{"name":"Old","future":1,"tracks":[{"name":"T","strip":{"pan":0.5},"takes":[{"start":1}]}],"master":{"reverbRoom":"from-the-future"}}"#.utf8))
            try check(sparse.name == "Old" && sparse.tempo == 120 && sparse.tracks[0].strip.pan == 0.5 && sparse.tracks[0].strip.midFreq == 1000
                      && sparse.tracks[0].takes[0].start == 1 && sparse.master.reverbRoom == .plate,
                      "songs with missing or unknown fields still open")
            try check(ProjectStore.sanitize(".hidden") == "hidden" && ProjectStore.sanitize("...") == "Untitled" && ProjectStore.sanitize("a/b") == "a-b",
                      "names can't create hidden folders or paths")

            // Only an armed track monitors; two audio tracks with I on must not both play the input.
            let mdir2 = dir.appendingPathComponent("MonitorSong")
            try FileManager.default.createDirectory(at: mdir2, withIntermediateDirectories: true)
            let savedProtection = Prefs.feedbackProtection
            Prefs.feedbackProtection = false
            defer { Prefs.feedbackProtection = savedProtection }
            let mon = Session(projectURL: mdir2, song: Song.newIdea())
            mon.addTrack(kind: .audio)
            let on = { (id: UUID) in mon.audio.tracks[id]?.monitorReader?.enabled.load(ordering: .relaxed) ?? false }
            let firstID = mon.song.tracks[0].id, secondID = mon.song.tracks[1].id
            try check(mon.song.tracks[1].monitor && !mon.song.tracks[1].armed && !on(secondID), "an unarmed track doesn't play the input")
            if mon.audio.canMonitorInput { try check(on(firstID), "the armed track does") }
            mon.close()
            mon.close()   // closing twice is harmless
        }

        print("Usability")
        do {
            let mdir = dir.appendingPathComponent("MissingSong")
            try FileManager.default.createDirectory(at: mdir.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            var ms = Song.newIdea()
            let gone = Take(name: "gone", fileName: "deleted-in-finder.caf", start: 0, duration: 2)
            ms.tracks[0].takes = [gone]
            ms.tracks[0].assign(takeID: gone.id, over: gone.range)
            let missingSession = Session(projectURL: mdir, song: ms)
            try check(missingSession.message?.contains("missing") == true, "opening a song with a missing recording says so")
            missingSession.followSuspended = true
            missingSession.play(from: 0)
            try check(!missingSession.followSuspended, "following the playhead resumes on the next play")
            missingSession.stop()
            try check(!missingSession.isConnected(ExternalMIDI(deviceID: -12345, deviceName: "Gone", channel: 1)),
                      "an unplugged external MIDI device shows as not connected")
            missingSession.close()
        }

        print("Auto-arm monitoring")
        for mode in [AutoArmMode.newTrack, .nextTrack] {
            var s = Song.newIdea()
            s.autoArm = mode
            s.tracks[0].monitor = true
            s.tracks.append(Track(name: "Track 2"))
            session.applyAutoArm(&s, recorded: [s.tracks[0].id])
            let armed = s.tracks.filter(\.armed)
            try check(!s.tracks[0].monitor && !s.tracks[0].armed && armed.count == 1 && armed[0].monitor
                      && armed[0].id != s.tracks[0].id,
                      "\(mode.label): recorded track stops monitoring, the armed one starts")
        }
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
