import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var devices = AudioDevices.all()

    var body: some View {
        Form {
            if let session = model.session {
                @Bindable var session = session
                Section("Audio devices") {
                    Picker("Input", selection: Binding(get: { session.inputUID ?? "" },
                                                       set: { session.setDevices(input: $0.isEmpty ? nil : $0, output: session.outputUID) })) {
                        Text("System default").tag("")
                        ForEach(devices.filter { $0.inputChannels > 0 }) { d in
                            Text("\(d.name) (\(d.inputChannels) in)").tag(d.uid)
                        }
                    }
                    Picker("Output", selection: Binding(get: { session.outputUID ?? "" },
                                                        set: { session.setDevices(input: session.inputUID, output: $0.isEmpty ? nil : $0) })) {
                        Text("System default").tag("")
                        ForEach(devices.filter { $0.outputChannels > 0 }) { d in
                            Text("\(d.name) (\(d.outputChannels) out)").tag(d.uid)
                        }
                    }
                    LabeledContent("Sample rate", value: "\(Int(session.sampleRate)) Hz")
                    LabeledContent("Input channels", value: "\(session.inputChannelCount)")
                    Picker("Buffer size", selection: Binding(get: { session.bufferFrames },
                                                             set: { session.setBufferFrames($0) })) {
                        ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { f in
                            Text("\(f) samples (\(String(format: "%.1f", Double(f) / session.sampleRate * 1000)) ms)").tag(f)
                        }
                    }
                    Text("Smaller buffers make monitoring through effects (the I button on a track) feel tighter, but use more CPU. If you hear crackles, raise it. Your interface's direct monitoring has no delay at all.")
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
                    Text("All sources go to every armed MIDI track.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Open a song to change audio settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear { devices = AudioDevices.all() }
    }
}
