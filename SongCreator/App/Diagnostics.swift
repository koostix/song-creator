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
            add("input level after 1 s: \(String(format: "%.4f", audio.meters.input(0))) (0 means no audio arrived)")
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
        DispatchQueue.main.async { run(out) }
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

        let setups: [(String, String?, String?, Bool, Int)] = [
            ("system default", nil, nil, true, 256),
            ("mic + speakers", "BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", true, 256),
            ("mic + speakers, 32 buffer", "BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", true, 32),
            ("input off", "BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", false, 256),
        ]
        for (label, inUID, outUID, enabled, buffer) in setups {
            lines.append(label)
            Prefs.inputUID = inUID; Prefs.outputUID = outUID; Prefs.inputEnabled = enabled; Prefs.bufferFrames = buffer
            let s = newSession(label)
            lines.append("  engine running=\(s.audio.engine.isRunning) input=\(s.audio.hasInput) rate=\(s.sampleRate) message=\(s.message ?? "none")")
            recordPass(s, label, expectAudio: enabled)
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
            recordPass(r, "record at 48 kHz")
            let url = r.projectURL
            r.close()
            AudioDevices.setSampleRate(spk, 96000)
            let reopened = Session(projectURL: url, song: try! ProjectStore.load(url))
            spin(0.6)
            check(reopened.sampleRate == 48000 && AudioDevices.sampleRate(spk) == 48000 && reopened.message == nil,
                  "reopening a 48 kHz song switches the speakers back from 96 kHz (\(reopened.message ?? "no warning"))")
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
