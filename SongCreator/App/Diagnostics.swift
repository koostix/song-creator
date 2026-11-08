import AVFoundation
import Foundation

/// `open -a "Song Creator" --args --diagnose <file>`: write what the audio setup looks like
/// from inside the app (its own microphone permission, devices, input, engine) and quit.
enum Diagnostics {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diagnose"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        add("mic permission: \(["notDetermined", "restricted", "denied", "authorized"][min(3, auth.rawValue)])")
        add("prefs: inputEnabled=\(Prefs.inputEnabled) protection=\(Prefs.feedbackProtection) buffer=\(Prefs.bufferFrames) "
            + "inputUID=\(Prefs.inputUID ?? "default") outputUID=\(Prefs.outputUID ?? "default")")
        let inDev = AudioDevices.device(uid: Prefs.inputUID)?.id ?? AudioDevices.defaultDevice(input: true)
        let outDev = AudioDevices.device(uid: Prefs.outputUID)?.id ?? AudioDevices.defaultDevice(input: false)
        for (label, dev) in [("input", inDev), ("output", outDev)] {
            if let d = dev {
                add("\(label) device: \(AudioDevices.name(d) ?? "?") rate=\(AudioDevices.sampleRate(d)) "
                    + "inCh=\(AudioDevices.inputChannels(d)) buffer=\(AudioDevices.bufferSize(d)) speakers=\(AudioDevices.isBuiltInSpeakers(d))")
            } else {
                add("\(label) device: none")
            }
        }

        let audio = AudioEngine()
        var song = Song.newIdea()
        song.clickEnabled = false
        audio.build(song: song, inputDevice: AudioDevices.device(uid: Prefs.inputUID)?.id,
                    outputDevice: AudioDevices.device(uid: Prefs.outputUID)?.id, inputEnabled: Prefs.inputEnabled,
                    bufferFrames: Prefs.bufferFrames)
        add("engine: sampleRate=\(audio.sampleRate) hasInput=\(audio.hasInput) inputChannels=\(audio.inputChannelCount) "
            + "inputRate=\(audio.inputSampleRate) canMonitor=\(audio.canMonitorInput) inputOffset=\(audio.inputChannelOffset)")
        add("input problem: \(audio.inputProblem ?? "none")")
        do {
            try audio.start()
            add("engine start: ok, running=\(audio.engine.isRunning)")
        } catch {
            add("engine start: FAILED \(error)")
        }
        // Capture a moment of input to prove the mic delivers audio.
        if audio.hasInput {
            let recorder = Recorder()
            recorder.installTap(on: audio)
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let levels = (0..<audio.inputChannelCount).map { String(format: "%.4f", audio.meters.input($0 + audio.inputChannelOffset)) }
            add("input levels after 1 s (per input channel): \(levels.joined(separator: " ")) (0 means no audio arrived)")
        }
        audio.engine.stop()
        audio.destroyAggregate()
        try? lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
        exit(0)
    }
}

/// `open -a "Song Creator" --args --smoketest <file>`: record for real through the app's own
/// session in several device setups, check the takes, and write a report. Restores all settings.
enum SmokeTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--smoketest"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        // From a run-loop timer, not a main-queue block: work that finishes on the main queue
        // (plugin loading, engine callbacks) can't run while a main-queue block is still running.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in run(out) }
    }

    private static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func peak(_ url: URL) -> (frames: Int64, peak: Float) {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil else { return (0, 0) }
        return (f.length, MeterStore.peak(buf))
    }

    static func run(_ out: URL) {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }

        // Restored explicitly before exit(): exit() skips defer blocks.
        let saved = (Prefs.inputUID, Prefs.outputUID, Prefs.inputEnabled, Prefs.bufferFrames, Prefs.feedbackProtection)
        func restorePrefs() {
            Prefs.inputUID = saved.0; Prefs.outputUID = saved.1; Prefs.inputEnabled = saved.2
            Prefs.bufferFrames = saved.3; Prefs.feedbackProtection = saved.4
        }
        let root = out.deletingLastPathComponent().appendingPathComponent("smoke-songs")
        try? FileManager.default.removeItem(at: root)

        /// Record ~1.5 s on a fresh song with the current settings; returns the session for more steps.
        func recordPass(_ session: Session, _ label: String, expectAudio: Bool = true) {
            let before = session.song.tracks.first?.takes.count ?? 0
            session.message = nil
            session.startRecording()
            let started = session.isRecording
            spin(1.6)
            session.stop()
            spin(0.4)
            let track = session.song.tracks.first!
            let newTakes = track.takes.count - before
            if !expectAudio {
                check(!started && newTakes == 0 && session.message != nil,
                      "\(label): record refuses with a message (\(session.message ?? "no message"))")
                return
            }
            check(started, "\(label): recording starts\(started ? "" : " — message: \(session.message ?? "none")")")
            guard newTakes == 1, let take = track.takes.last, let file = take.fileName else {
                check(false, "\(label): one new take (got \(newTakes))")
                return
            }
            let p = peak(session.audioFolder.appendingPathComponent(file))
            check(take.duration > 1.0 && take.duration < 2.5, "\(label): take is \(String(format: "%.2f", take.duration)) s long")
            check(p.frames > 0 && p.peak > 0, "\(label): file has sound (peak \(String(format: "%.4f", p.peak)), \(p.frames) frames)")
            session.play(from: 0)
            spin(0.6)
            let playing = session.isPlaying && session.audio.engine.isRunning && session.playhead.position > 0.1
            session.stop()
            check(playing, "\(label): plays back")
        }

        func newSession(_ name: String) -> Session {
            var song = Song.newIdea()
            song.name = name
            song.countInBars = 0
            song.clickEnabled = false
            let url = try! ProjectStore.create(song, in: root)
            let s = Session(projectURL: url, song: song)
            spin(0.6)
            return s
        }

        // Put the devices back the way we found them.
        let mic = AudioDevices.device(uid: "BuiltInMicrophoneDevice")?.id
        let spk = AudioDevices.device(uid: "BuiltInSpeakerDevice")?.id
        let originalRates = (mic.map(AudioDevices.sampleRate), spk.map(AudioDevices.sampleRate))
        func restoreRates() {
            if let mic, let r = originalRates.0 { AudioDevices.setSampleRate(mic, r) }
            if let spk, let r = originalRates.1 { AudioDevices.setSampleRate(spk, r) }
        }
        lines.append("device rates at start: mic \(originalRates.0 ?? 0), speakers \(originalRates.1 ?? 0)")

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        lines.append("mic permission: \(auth == .authorized ? "authorized" : "NOT authorized (\(auth.rawValue))")")

        // First, exactly the user's own saved settings.
        do {
            lines.append("your current settings: in \(saved.0 ?? "default") / out \(saved.1 ?? "default"), input \(saved.2 ? "on" : "off"), buffer \(saved.3)")
            let s = newSession("current settings")
            lines.append("  engine running=\(s.audio.engine.isRunning) ownIO=\(s.audio.usesOwnIO) input=\(s.audio.hasInput) "
                         + "channels=\(s.inputChannelCount) offset=\(s.audio.inputChannelOffset) rate=\(s.sampleRate) message=\(s.message ?? "none")")
            spin(0.5)
            let levels = (0..<6).map { String(format: "%.4f", s.audio.meters.input($0)) }.joined(separator: " ")
            lines.append("  input levels by engine channel: \(levels)")
            recordPass(s, "your settings", expectAudio: saved.2)
            if saved.2, let armed = s.song.tracks.first(where: \.armed) {
                s.startRecording()
                spin(0.5)
                s.deleteTrack(armed.id)
                let kept = s.song.tracks.contains { $0.id == armed.id }
                s.stop()
                spin(0.3)
                check(kept, "a track can't be deleted while it's recording")
            }
            s.close()
        }

        let setups: [(String, String?, String?, Bool, Int)] = [
            ("system default", nil, nil, true, 256),
            ("mic + speakers", "BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", true, 256),
            ("mic + speakers, 32 buffer", "BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", true, 32),
            ("input off", "BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", false, 256),
        ]
        for (label, inUID, outUID, enabled, buffer) in setups {
            lines.append(label)
            Prefs.inputUID = inUID; Prefs.outputUID = outUID; Prefs.inputEnabled = enabled; Prefs.bufferFrames = buffer
            // A default input that can't run at the default output's rate (a Bluetooth headset mic) is refused on purpose.
            var expect = enabled
            if inUID == nil, let din = AudioDevices.defaultDevice(input: true), let dout = AudioDevices.defaultDevice(input: false),
               din != dout || AudioDevices.transportType(din) == kAudioDeviceTransportTypeBluetooth,
               !AudioDevices.supports(din, rate: AudioDevices.sampleRate(dout)) {
                expect = false
                lines.append("  (default input \(AudioDevices.name(din) ?? "?") can't run at the output's rate: recording should be refused)")
            }
            let s = newSession(label)
            lines.append("  engine running=\(s.audio.engine.isRunning) ownIO=\(s.audio.usesOwnIO) input=\(s.audio.hasInput) rate=\(s.sampleRate) message=\(s.message ?? "none")")
            recordPass(s, label, expectAudio: expect)
            if expect, label == "mic + speakers" {
                // Mixdown with chosen devices: the engine leaves realtime mode for offline rendering.
                var done: URL?
                var finished = false
                s.export(format: .wav16, range: TimeRange(start: 0, end: 2), stems: false) { url in done = url; finished = true }
                let deadline = Date().addingTimeInterval(20)
                while !finished && Date() < deadline { spin(0.2) }
                let p = done.map { peak($0) } ?? (frames: 0, peak: 0)
                check(done != nil && p.peak > 0, "mixdown with chosen devices has sound (peak \(String(format: "%.4f", p.peak)))")
                recordPass(s, "recording again after the mixdown")
            }
            s.close()
        }

        if let mic, let spk {
            lines.append("mismatched device rates")
            AudioDevices.setSampleRate(spk, 96000)
            AudioDevices.setSampleRate(mic, 48000)
            Prefs.inputUID = "BuiltInMicrophoneDevice"; Prefs.outputUID = "BuiltInSpeakerDevice"
            Prefs.inputEnabled = true; Prefs.bufferFrames = 256
            let m = newSession("mismatch")
            check(AudioDevices.sampleRate(mic) == AudioDevices.sampleRate(spk) && m.audio.hasInput,
                  "new song: the mic follows the speakers' rate (\(AudioDevices.sampleRate(mic)) Hz)")
            recordPass(m, "speakers at 96 kHz, mic at 48 kHz")
            m.close()

            lines.append("song recorded at another rate")
            AudioDevices.setSampleRate(spk, 48000)
            AudioDevices.setSampleRate(mic, 48000)
            let r = newSession("rate song")
            recordPass(r, "record a song")
            let url = r.projectURL
            let recordedRate = r.song.sampleRate
            r.close()
            let otherRate: Double = recordedRate == 96000 ? 48000 : 96000
            AudioDevices.setSampleRate(spk, otherRate)
            let reopened = Session(projectURL: url, song: try! ProjectStore.load(url))
            spin(0.6)
            check(reopened.sampleRate == recordedRate && AudioDevices.sampleRate(spk) == recordedRate && reopened.message == nil,
                  "reopening a \(Int(recordedRate)) Hz song switches the speakers back from \(Int(otherRate)) Hz (\(reopened.message ?? "no warning"))")
            reopened.play(from: 0)
            spin(0.6)
            check(reopened.isPlaying && reopened.playhead.position > 0.1, "its takes play")
            reopened.stop()
            reopened.close()
        }

        lines.append("switching inside one session")
        Prefs.inputUID = nil; Prefs.outputUID = nil; Prefs.inputEnabled = true; Prefs.bufferFrames = 256
        let s = newSession("switching")
        s.setDevices(input: "BuiltInMicrophoneDevice", output: "BuiltInSpeakerDevice")
        spin(2.0)   // let the configuration-change echo settle
        recordPass(s, "after choosing mic + speakers")
        s.setDevices(input: nil, output: nil)
        spin(2.0)
        recordPass(s, "after going back to system default")
        s.inputEnabled = false
        spin(1.0)
        recordPass(s, "with input switched off", expectAudio: false)
        s.inputEnabled = true
        spin(2.0)
        recordPass(s, "after switching input back on")
        s.setBufferFrames(128)
        spin(2.0)
        recordPass(s, "after a buffer size change")
        s.close()

        try? FileManager.default.removeItem(at: root)
        restorePrefs()
        restoreRates()
        lines.append("restored: mic \(mic.map(AudioDevices.sampleRate) ?? 0), speakers \(spk.map(AudioDevices.sampleRate) ?? 0), "
                     + "buffer \(Prefs.bufferFrames), devices \(Prefs.inputUID ?? "default") / \(Prefs.outputUID ?? "default")")
        lines.append(failures == 0 ? "SMOKE PASS" : "SMOKE FAIL (\(failures))")
        try? lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}

/// `open -a "Song Creator" --args --plugintest <file>`: load a sample of your installed Audio Units
/// (instruments and effects from other makers), open each editor, then bypass and remove one through
/// a song, and write a report.
enum PluginTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--plugintest"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        // From a run-loop timer, not a main-queue block: work that finishes on the main queue
        // (plugin loading, engine callbacks) can't run while a main-queue block is still running.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in run(out) }
    }

    private static func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func run(_ out: URL) {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }
        let thirdParty = { (list: [PluginInfo]) in list.filter { $0.manufacturerCode != kAudioUnitManufacturer_Apple } }
        let instruments = thirdParty(PluginCatalog.instruments)
        let effects = thirdParty(PluginCatalog.effects)
        lines.append("installed: \(instruments.count) instruments, \(effects.count) effects from other makers")
        let tal = instruments.filter { $0.name.localizedCaseInsensitiveContains("U-No") }
        let sample = Array((tal + instruments).prefix(3)) + Array(effects.prefix(5))

        let audio = AudioEngine()
        var song = Song.newIdea()
        audio.build(song: song, inputDevice: nil, outputDevice: nil, inputEnabled: false)
        for info in sample {
            let slot = info.makeSlot()
            var track = Track(name: info.name, kind: info.type == kAudioUnitType_MusicDevice ? .midi : .audio, channels: 2)
            if track.kind == .midi { track.instrument = slot } else { track.inserts = [slot] }
            song.tracks = [track]
            audio.sync(song)
            spin(15) { audio.unit(slot.id) != nil || audio.pluginErrors[slot.id] != nil }
            guard let unit = audio.unit(slot.id) else {
                check(false, "\(info.manufacturer) \(info.name): loads (\(audio.pluginErrors[slot.id] ?? "timed out"))")
                continue
            }
            PluginWindows.open(unit, slot: slot.id, title: info.name)
            spin(10) { PluginWindows.isOpen(slot.id) }
            check(PluginWindows.isOpen(slot.id), "\(info.manufacturer) \(info.name): editor opens (\(PluginWindows.lastKind))")
            PluginWindows.close(slot.id)
        }

        // Bypass and remove through a real song, the way the buttons do it.
        if let fx = effects.first {
            let root = out.deletingLastPathComponent().appendingPathComponent("plugin-test-song")
            try? FileManager.default.removeItem(at: root)
            var s = Song.newIdea()
            s.name = "Plugin test"
            let url = try! ProjectStore.create(s, in: root)
            let saved = Prefs.inputEnabled
            Prefs.inputEnabled = false
            let session = Session(projectURL: url, song: s)
            Prefs.inputEnabled = saved
            let tid = session.song.tracks[0].id
            session.addInsert(fx, to: tid)
            let slot = session.song.tracks[0].inserts[0]
            spin(15) { session.audio.unit(slot.id) != nil || session.audio.pluginErrors[slot.id] != nil }
            session.toggleBypass(slot.id, in: tid)
            check(session.audio.unit(slot.id)?.auAudioUnit.shouldBypassEffect == true, "\(fx.name): ⏻ bypasses it")
            session.toggleBypass(slot.id, in: tid)
            check(session.audio.unit(slot.id)?.auAudioUnit.shouldBypassEffect == false, "\(fx.name): ⏻ again enables it")
            session.openEditor(session.song.tracks[0].inserts[0], track: session.song.tracks[0])
            spin(10) { PluginWindows.isOpen(slot.id) }
            check(PluginWindows.isOpen(slot.id) && PluginWindows.hasAccessory(slot.id), "\(fx.name): the editor opens with its on/off button")
            session.removeInsert(slot.id, from: tid)
            spin(0.5)
            check(session.song.tracks[0].inserts.isEmpty && session.audio.unit(slot.id) == nil && !PluginWindows.isOpen(slot.id),
                  "\(fx.name): × removes it, unloads it and closes its window")
            session.undo()
            spin(15) { session.audio.unit(slot.id) != nil }
            check(session.song.tracks[0].inserts.count == 1 && session.audio.unit(slot.id) != nil, "undo brings it back")

            // The same plugin on the master, before the master fader and limiter.
            session.addInsert(fx, to: Song.masterID)
            let mslot = session.song.master.inserts[0]
            spin(15) { session.audio.unit(mslot.id) != nil || session.audio.pluginErrors[mslot.id] != nil }
            check(session.audio.masterInserts == [mslot.id], "\(fx.name): loads on the master")
            session.toggleBypass(mslot.id, in: Song.masterID)
            check(session.audio.unit(mslot.id)?.auAudioUnit.shouldBypassEffect == true, "\(fx.name): ⏻ bypasses it on the master")
            session.toggleBypass(mslot.id, in: Song.masterID)
            session.openEditor(mslot, owner: Song.masterID)
            spin(10) { PluginWindows.isOpen(mslot.id) }
            check(PluginWindows.isOpen(mslot.id) && PluginWindows.hasAccessory(mslot.id), "\(fx.name): the master's editor has its on/off button")
            session.removeInsert(mslot.id, from: Song.masterID)
            spin(0.5)
            check(session.song.master.inserts.isEmpty && session.audio.masterInserts.isEmpty && !PluginWindows.isOpen(mslot.id),
                  "\(fx.name): × removes it from the master")

            // Effects added, moved and removed while the song plays. The engine resets a player whose path to
            // the output is cut, so the track used to fall silent until playback was restarted. The master is
            // turned right down: nothing is heard, and the level is read before the effects.
            while !session.song.tracks[0].inserts.isEmpty { session.removeInsert(session.song.tracks[0].inserts[0].id, from: tid) }
            let channels = session.song.tracks[0].channels
            let toneName = "plugintest-tone.caf"
            if let f = try? Recorder.makeFile(url: session.audioFolder.appendingPathComponent(toneName),
                                              sampleRate: session.audio.sampleRate, channels: channels) {
                let n = AVAudioFrameCount(session.audio.sampleRate * 30)
                let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
                buf.frameLength = n
                for c in 0..<channels {
                    for i in 0..<Int(n) { buf.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * 220 * Double(i) / session.audio.sampleRate)) }
                }
                try? f.write(from: buf)
            }
            session.edit { s in
                s.master.volumeDB = -60
                let take = Take(name: "tone", fileName: toneName, start: 0, duration: 30)
                s.tracks[0].takes = [take]
                s.tracks[0].assign(takeID: take.id, over: take.range)
            }
            let lock = NSLock()
            var peak: Float = 0
            let tapped = session.audio.tracks[tid]?.eq
            tapped?.installTap(onBus: 0, bufferSize: 2048, format: nil) { buf, _ in
                let p = MeterStore.peak(buf)
                lock.lock(); peak = max(peak, p); lock.unlock()
            }
            func playing(_ what: String) {
                lock.lock(); peak = 0; lock.unlock()
                spin(0.6)
                lock.lock(); let p = peak; lock.unlock()
                check(p > 0.05, String(format: "the track keeps playing after %@ (level %.2f)", what, p))
            }
            func added(_ owner: UUID) {
                let slots = session.inserts(of: owner)
                spin(15) { slots.allSatisfy { session.audio.unit($0.id) != nil || session.audio.pluginErrors[$0.id] != nil } }
            }
            let fx2 = effects.dropFirst().first ?? fx
            session.play(from: 0)
            spin(1)
            playing("starting")
            session.addInsert(fx, to: tid); added(tid)
            playing("adding \(fx.name)")
            session.addInsert(fx2, to: tid); added(tid)
            playing("adding \(fx2.name) after it")
            session.moveInsert(session.song.tracks[0].inserts[0].id, in: tid, by: 1)
            playing("swapping them")
            session.removeInsert(session.song.tracks[0].inserts[0].id, from: tid)
            playing("removing one")
            session.addInsert(fx, to: Song.masterID); added(Song.masterID)
            playing("adding \(fx.name) on the master")
            session.removeInsert(session.song.master.inserts[0].id, from: Song.masterID)
            playing("removing it from the master")
            // An effect bus added while playing: the track's send reaches it, and its plugin.
            session.addBus()
            let bid = session.song.buses.last!.id
            session.updateTrack(tid, undoable: false) { $0.strip.sends[bid] = 0.8 }
            spin(0.6)
            check(session.audio.meters.level(bid) > 0.05,
                  String(format: "a bus added during playback gets the track's send (level %.2f)", session.audio.meters.level(bid)))
            session.addInsert(fx, to: bid); added(bid)
            playing("adding \(fx.name) on the bus")
            check(session.audio.buses[bid]?.inserts.count == 1 && session.audio.meters.level(bid) > 0.05,
                  "\(fx.name) on the bus is wired in and passes the send")
            session.removeBus(bid)
            playing("removing the bus")
            check(session.audio.buses[bid] == nil, "the removed bus is gone from the engine")

            // Automation drawn during playback: a parameter of the plugin follows its curve, and mute switches
            // the track off on time.
            session.addInsert(fx, to: tid); added(tid)
            let aslot = session.song.tracks[0].inserts.last!.id
            if let params = session.automatableParameters(aslot),
               let p = params.first(where: { !AudioEngine.steps($0) && $0.maxValue > $0.minValue }) {
                let now = session.transport.currentPosition() ?? 0
                let lo = Double(p.minValue), hi = Double(p.maxValue), start = p.value
                let curve = [AutoPoint(time: 0, value: lo), AutoPoint(time: now + 0.5, value: lo), AutoPoint(time: now + 4.5, value: hi)]
                session.updateAutomation(tid) { $0.set(.plugin(aslot, p.address), curve) }
                var samples: [(Double, Double)] = []
                for _ in 0..<4 {
                    spin(1)
                    let t = session.transport.currentPosition() ?? 0
                    samples.append((Double(p.value), Automation.evaluate(curve, at: t)!))
                }
                let off = samples.map { abs($0.0 - $0.1) / (hi - lo) }.max() ?? 1
                let rising = zip(samples, samples.dropFirst()).allSatisfy { $1.0 > $0.0 }
                check(rising && off < 0.1,
                      String(format: "%@ follows its automation during playback (%@ rising, off by %.0f%% at most)",
                             p.displayName, samples.map { String(format: "%.2f", $0.0) }.joined(separator: " → "), off * 100))
                session.updateAutomation(tid) { $0.set(.plugin(aslot, p.address), []) }
                p.value = start   // where it was, or the tone may now be filtered away
            } else {
                lines.append("  (\(fx.name) has no smooth parameter to automate)")
            }
            playing("automating \(fx.name)")
            let muteAt = (session.transport.currentPosition() ?? 0) + 0.5
            session.updateAutomation(tid) { $0.set(.mute, [AutoPoint(time: 0, value: 0), AutoPoint(time: muteAt, value: 1)]) }
            spin(0.3)
            let beforeMute = session.audio.meters.level(tid)
            spin(1.5)
            let afterMute = session.audio.meters.level(tid)   // the meter falls away over a few hundred ms
            check(beforeMute > 0.05 && afterMute < 0.01,
                  String(format: "mute automation turns the track off on time (%.3f → %.4f)", beforeMute, afterMute))
            session.stop()
            tapped?.removeTap(onBus: 0)
            session.close()
            try? FileManager.default.removeItem(at: root)
        }

        audio.engine.stop()
        lines.append(failures == 0 ? "PLUGIN TEST PASS" : "PLUGIN TEST FAIL (\(failures))")
        try? lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
