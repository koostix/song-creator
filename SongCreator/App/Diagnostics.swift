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
