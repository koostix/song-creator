import SwiftUI

/// Audio settings. They're saved preferences, so they work from the song list too; with a song open,
/// changes also apply to it straight away.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var devices = AudioDevices.all()

    @AppStorage("inputUID") private var inputUID: String?
    @AppStorage("outputUID") private var outputUID: String?
    @AppStorage("inputEnabled") private var inputEnabled = true
    @AppStorage("feedbackProtection") private var protection = true
    @AppStorage("bufferFrames") private var bufferFrames = 256
    @AppStorage("latencyOffsetMs") private var latencyMs = 0.0
    @AppStorage("returnOnStop") private var returnOnStop = true
    @AppStorage("pluginsOutOfProcess") private var pluginsOutOfProcess = true

    private var session: Session? { model.session }

    var body: some View {
        Form {
            Section("Input") {
                Toggle("Use audio input", isOn: $inputEnabled)
                Text("Off means the microphone is never opened: no recording input, no monitoring, no feedback. Playback, KEYS and MIDI keep working.")
                    .font(.caption).foregroundStyle(.secondary)
                devicePicker("Input device", selection: $inputUID, input: true)
                    .disabled(!inputEnabled)
                if let s = session {
                    LabeledContent("Input channels", value: inputEnabled ? "\(s.inputChannelCount)" : "off")
                }
            }

            Section("Monitoring") {
                Toggle("Feedback protection", isOn: $protection)
                if let s = session {
                    LabeledContent("Right now") {
                        Text(monitoringState(s)).foregroundStyle(s.monitoringMuted ? Color.orange : .secondary)
                    }
                }
                Text("When sound comes out of the computer's speakers, the mic can pick it up and howl. Protection mutes input monitoring (the I button on tracks) until you use headphones or an interface. Recording itself isn't affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Output") {
                devicePicker("Output device", selection: $outputUID, input: false)
                Picker("Buffer size", selection: $bufferFrames) {
                    ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { f in
                        Text("\(f) samples").tag(f)
                    }
                }
                if let s = session {
                    LabeledContent("Sample rate", value: "\(Int(s.sampleRate)) Hz")
                    if let out = s.audio.outputDeviceID {
                        let actual = AudioDevices.bufferSize(out)
                        if actual > 0 && actual != bufferFrames {
                            Text("This device is using \(actual) samples.").font(.caption).foregroundStyle(Color.orange)
                        }
                    }
                }
                Text("Smaller buffers make monitoring through effects feel tighter but use more CPU. If you hear crackles, raise it. A song with recordings sets your devices to its sample rate.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recording") {
                LabeledContent("Latency offset") {
                    HStack {
                        Slider(value: $latencyMs, in: -50...50, step: 0.5)
                        Text(String(format: "%+.1f ms", latencyMs)).monospacedDigit().frame(width: 70)
                    }
                }
                Text("Reported device latency is already compensated. If new takes land late against the click, raise this. If they land early, lower it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Return to start position on stop", isOn: $returnOnStop)
            }

            Section("Plugins") {
                Toggle("Run plugins in a separate process (safer)", isOn: $pluginsOutOfProcess)
                Text("A plugin that crashes then closes only itself, not Song Creator. Turning this off saves a little CPU. Applies to plugins loaded after you change it; reopen the song to reload all of them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MIDI inputs") {
                if let s = session {
                    if s.midiSources.isEmpty {
                        Text("No MIDI sources connected").foregroundStyle(.secondary)
                    } else {
                        ForEach(s.midiSources, id: \.self) { Text($0) }
                    }
                }
                Text("Notes play armed MIDI tracks. With none armed, they play the selected (or first) MIDI track.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if session == nil {
                Text("These settings are saved and apply when you open a song.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .onAppear {
            AudioDevices.startWatching()
            devices = AudioDevices.all()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in devices = AudioDevices.all() }
        // Apply to the open song. Each setter also saves the same preference, so this never loops.
        .onChange(of: inputUID) { _, v in if let s = session, s.inputUID != v { s.setDevices(input: v, output: s.outputUID) } }
        .onChange(of: outputUID) { _, v in if let s = session, s.outputUID != v { s.setDevices(input: s.inputUID, output: v) } }
        .onChange(of: inputEnabled) { _, v in if let s = session, s.inputEnabled != v { s.inputEnabled = v } }
        .onChange(of: protection) { _, v in if let s = session, s.feedbackProtection != v { s.feedbackProtection = v } }
        .onChange(of: bufferFrames) { _, v in if let s = session, s.bufferFrames != v { s.setBufferFrames(v) } }
        .onChange(of: latencyMs) { _, v in if let s = session, s.latencyOffsetMs != v { s.latencyOffsetMs = v } }
        .onChange(of: returnOnStop) { _, v in if let s = session, s.returnOnStop != v { s.returnOnStop = v } }
    }

    /// Device menu that keeps showing a saved device even while it's unplugged.
    private func devicePicker(_ title: String, selection: Binding<String?>, input: Bool) -> some View {
        let list = devices.filter { input ? $0.inputChannels > 0 : $0.outputChannels > 0 }
        let missing = selection.wrappedValue.flatMap { uid in list.contains { $0.uid == uid } ? nil : uid }
        return Picker(title, selection: Binding(get: { selection.wrappedValue ?? "" },
                                                set: { selection.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text("System default").tag("")
            ForEach(list) { d in
                Text(input ? "\(d.name) (\(d.inputChannels) in)" : "\(d.name) (\(d.outputChannels) out)").tag(d.uid)
            }
            if let missing {
                Text("Saved device (not connected) — using system default").tag(missing)
            }
        }
    }

    private func monitoringState(_ session: Session) -> String {
        let name = session.audio.outputDeviceID.flatMap(AudioDevices.name) ?? "the output"
        if !session.inputEnabled { return "Input is off" }
        if session.monitoringMuted { return "Muted: playing through \(name)" }
        if session.onSpeakers { return "Allowed on speakers (protection off)" }
        return "Allowed: playing through \(name)"
    }
}
