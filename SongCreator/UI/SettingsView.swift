import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var devices = AudioDevices.all()

    var body: some View {
        Form {
            if let session = model.session {
                @Bindable var session = session
                Section("Input") {
                    Toggle("Use audio input", isOn: $session.inputEnabled)
                    Text("Off means the microphone is never opened: no recording input, no monitoring, no feedback. Playback, KEYS and MIDI keep working.")
                        .font(.caption).foregroundStyle(.secondary)
                    devicePicker("Input device", selection: session.inputUID, input: true) {
                        session.setDevices(input: $0, output: session.outputUID)
                    }
                    .disabled(!session.inputEnabled)
                    LabeledContent("Input channels", value: session.inputEnabled ? "\(session.inputChannelCount)" : "off")
                }

                Section("Monitoring") {
                    Toggle("Feedback protection", isOn: $session.feedbackProtection)
                    LabeledContent("Right now") {
                        Text(monitoringState(session))
                            .foregroundStyle(session.monitoringMuted ? Color.orange : .secondary)
                    }
                    Text("When sound comes out of the computer's speakers, the mic can pick it up and howl. Protection mutes input monitoring (the I button on tracks) until you use headphones or an interface. Recording itself isn't affected.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Output") {
                    devicePicker("Output device", selection: session.outputUID, input: false) {
                        session.setDevices(input: session.inputUID, output: $0)
                    }
                    LabeledContent("Sample rate", value: "\(Int(session.sampleRate)) Hz")
                    Picker("Buffer size", selection: Binding(get: { session.bufferFrames },
                                                             set: { session.setBufferFrames($0) })) {
                        ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { f in
                            Text("\(f) samples (\(String(format: "%.1f", Double(f) / session.sampleRate * 1000)) ms)").tag(f)
                        }
                    }
                    if let out = session.audio.outputDeviceID {
                        let actual = AudioDevices.bufferSize(out)
                        if actual > 0 && actual != session.bufferFrames {
                            Text("This device is using \(actual) samples.").font(.caption).foregroundStyle(Color.orange)
                        }
                    }
                    Text("Smaller buffers make monitoring through effects feel tighter but use more CPU. If you hear crackles, raise it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Recording") {
                    LabeledContent("Latency offset") {
                        HStack {
                            Slider(value: $session.latencyOffsetMs, in: -50...50, step: 0.5)
                            Text(String(format: "%+.1f ms", session.latencyOffsetMs)).monospacedDigit().frame(width: 70)
                        }
                    }
                    Text("Reported device latency is already compensated. If new takes land late against the click, raise this. If they land early, lower it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Return to start position on stop", isOn: $session.returnOnStop)
                }

                Section("MIDI inputs") {
                    if session.midiSources.isEmpty {
                        Text("No MIDI sources connected").foregroundStyle(.secondary)
                    } else {
                        ForEach(session.midiSources, id: \.self) { Text($0) }
                    }
                    Text("Notes play armed MIDI tracks. With none armed, they play the selected (or first) MIDI track.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Open a song to change audio settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .onAppear {
            AudioDevices.startWatching()
            devices = AudioDevices.all()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in devices = AudioDevices.all() }
    }

    /// Device menu that keeps showing a saved device even while it's unplugged.
    private func devicePicker(_ title: String, selection: String?, input: Bool,
                              set: @escaping (String?) -> Void) -> some View {
        let list = devices.filter { input ? $0.inputChannels > 0 : $0.outputChannels > 0 }
        let missing = selection.flatMap { uid in list.contains { $0.uid == uid } ? nil : uid }
        return Picker(title, selection: Binding(get: { selection ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
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
