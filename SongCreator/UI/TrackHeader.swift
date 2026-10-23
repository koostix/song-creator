import SwiftUI

enum GMPrograms {
    /// A practical subset of General MIDI; -1 is the drum kit.
    static let list: [(Int, String)] = [
        (0, "Grand Piano"), (2, "Electric Grand"), (4, "Electric Piano"), (5, "EP 2"), (6, "Harpsichord"),
        (11, "Vibraphone"), (16, "Drawbar Organ"), (19, "Church Organ"), (24, "Nylon Guitar"),
        (25, "Steel Guitar"), (27, "Clean Guitar"), (29, "Overdrive Guitar"), (32, "Acoustic Bass"),
        (33, "Finger Bass"), (38, "Synth Bass"), (48, "Strings"), (49, "Slow Strings"), (52, "Choir Aahs"),
        (56, "Trumpet"), (61, "Brass Section"), (65, "Alto Sax"), (73, "Flute"), (80, "Square Lead"),
        (81, "Saw Lead"), (88, "New Age Pad"), (89, "Warm Pad"), (91, "Choir Pad"), (95, "Sweep Pad"),
        (-1, "Drum Kit"),
    ]
    static func name(_ p: Int) -> String { list.first { $0.0 == p }?.1 ?? "Program \(p + 1)" }
}

struct TrackHeader: View {
    @Bindable var session: Session
    let track: Track

    private var selected: Bool { session.selectedTrackID == track.id }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.color(track.colorIndex)).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: track.kind == .midi ? "pianokeys" : (track.channels == 2 ? "waveform.path" : "waveform"))
                        .font(.system(size: 10)).foregroundStyle(Theme.color(track.colorIndex))
                    RenameField(text: track.name, isEditing: Binding(
                        get: { session.renamingTrackID == track.id },
                        set: { on in
                            if on { session.startRenaming(track.id) }
                            else if session.renamingTrackID == track.id { session.renamingTrackID = nil }
                        })) { name in
                        session.updateTrack(track.id) { $0.name = name }
                    }
                    FXMenu(session: session, track: track)
                    MeterBar(level: { [audio = session.audio, id = track.id, armed = track.armed, kind = track.kind,
                                       ch = track.inputChannel, stereo = track.channels == 2] in
                        // Armed audio tracks show their input; otherwise the track output.
                        if armed && kind == .audio {
                            let c = ch + audio.inputChannelOffset
                            return stereo ? max(audio.meters.input(c), audio.meters.input(c + 1)) : audio.meters.input(c)
                        }
                        return audio.meters.level(id)
                    }, vertical: false)
                    .frame(width: 44, height: 5)
                }
                HStack(spacing: 4) {
                    LitButton(label: "R", on: track.armed, color: Theme.record, help: "Record arm (A)") { session.toggleArm(track.id) }
                    LitButton(label: "M", on: track.mute, color: Color.orange, help: "Mute (M)") {
                        session.updateTrack(track.id, undoable: false) { $0.mute.toggle() }
                    }
                    LitButton(label: "S", on: track.solo, color: Color.yellow, help: "Solo (S)") {
                        session.updateTrack(track.id, undoable: false) { $0.solo.toggle() }
                    }
                    if track.kind == .audio {
                        LitButton(label: "I", on: track.monitor,
                                  color: session.monitoringMuted || !session.inputEnabled ? Color.orange : Theme.accent,
                                  help: !session.inputEnabled ? "Input monitoring (the audio input is switched off)"
                                    : session.monitoringMuted ? "Input monitoring is muted by feedback protection while sound plays through the speakers. Use headphones to hear yourself."
                                    : "Input monitoring: hear this track's input through its effects and plugins") {
                            session.updateTrack(track.id, undoable: false) { $0.monitor.toggle() }
                        }
                    }
                    LitButton(label: "A", on: track.showAutomation, color: .green, help: "Show volume/pan automation") {
                        session.updateTrack(track.id, undoable: false) { $0.showAutomation.toggle() }
                    }
                    if track.kind == .audio { inputMenu } else { quantizeMenu; instrumentMenu }
                    Spacer(minLength: 0)
                    if !track.takes.isEmpty {
                        Button {
                            session.updateTrack(track.id, undoable: false) { $0.showTakes.toggle() }
                        } label: {
                            HStack(spacing: 2) {
                                Text("\(track.takes.count)")
                                Image(systemName: track.showTakes ? "chevron.down" : "chevron.right")
                            }
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(track.showTakes ? Theme.accent : Theme.dim)
                        }
                        .buttonStyle(.plain)
                        .help("Show takes for comping")
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(height: Layout.laneHeight, alignment: .top)
        .background(selected ? Color.white.opacity(0.06) : Theme.panel.opacity(0.6))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTrackID = track.id }
        .contextMenu {
            Button("Move Up") { session.moveTrack(track.id, by: -1) }
            Button("Move Down") { session.moveTrack(track.id, by: 1) }
            Menu("Color") {
                ForEach(0..<TrackPalette.count, id: \.self) { i in
                    Button("Color \(i + 1)") { session.updateTrack(track.id) { $0.colorIndex = i } }
                }
            }
            Divider()
            Button("Delete Track", role: .destructive) { session.deleteTrack(track.id) }
        }
    }

    private var inputMenu: some View {
        let n = max(1, session.inputChannelCount)
        let label = track.channels == 2 ? "In \(track.inputChannel + 1)-\(track.inputChannel + 2)" : "In \(track.inputChannel + 1)"
        return Menu {
            Section("Mono") {
                ForEach(0..<n, id: \.self) { c in
                    Button("Input \(c + 1)") { session.updateTrack(track.id) { $0.channels = 1; $0.inputChannel = c } }
                }
            }
            if n >= 2 {
                Section("Stereo") {
                    ForEach(Array(stride(from: 0, to: n - 1, by: 2)), id: \.self) { c in
                        Button("Inputs \(c + 1)-\(c + 2)") { session.updateTrack(track.id) { $0.channels = 2; $0.inputChannel = c } }
                    }
                }
            }
        } label: {
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hardware input for this track")
    }

    private var instrumentMenu: some View {
        Menu {
            Section("Built-in sounds") {
                ForEach(GMPrograms.list, id: \.0) { p in
                    Button(p.1) {
                        if track.external != nil { session.setExternal(nil, on: track.id) }
                        session.updateTrack(track.id) { $0.program = p.0; $0.instrument = nil }
                    }
                }
            }
            Section("Audio Unit instruments") {
                ForEach(PluginCatalog.grouped(PluginCatalog.instruments), id: \.0) { group in
                    Menu(group.0) {
                        ForEach(group.1) { info in
                            Button(info.name) {
                                if track.external != nil { session.setExternal(nil, on: track.id) }
                                session.setInstrument(info, on: track.id)
                            }
                        }
                    }
                }
            }
            Section("External MIDI device") {
                if session.midiDestinations.isEmpty {
                    Text("No MIDI outputs connected")
                }
                ForEach(session.midiDestinations) { dest in
                    Menu(dest.name) {
                        ForEach(1...16, id: \.self) { ch in
                            Button("Channel \(ch)") {
                                var ext = ExternalMIDI(deviceID: dest.id, deviceName: dest.name, channel: ch)
                                if let old = track.external { ext.audioReturn = old.audioReturn; ext.latencyMs = old.latencyMs }
                                session.setExternal(ext, on: track.id)
                            }
                        }
                    }
                }
            }
            if let ext = track.external {
                Divider()
                audioReturnMenu(ext)
                Menu("Delay compensation (\(Int(ext.latencyMs)) ms)") {
                    ForEach([0, 3, 5, 10, 20, 30, 50], id: \.self) { ms in
                        Button("\(ms) ms") { session.updateTrack(track.id) { $0.external?.latencyMs = Double(ms) } }
                    }
                }
                Button("Stop using \(ext.deviceName)") { session.setExternal(nil, on: track.id) }
            }
            if let slot = track.instrument {
                Divider()
                Button("Open \(slot.name)…") { session.openEditor(slot, track: track) }
            }
        } label: {
            Text(instrumentLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(track.instrument.flatMap { session.pluginStatus($0) } != nil ? Color.orange
                                 : track.external != nil ? Theme.accent : Theme.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(track.external.map { "Plays \($0.deviceName) on MIDI channel \($0.channel)" }
              ?? track.instrument.flatMap { session.pluginStatus($0) } ?? "Instrument for this track")
    }

    /// Non-destructive quantize: notes play on the grid, the recording stays as played.
    private var quantizeMenu: some View {
        let q = track.quantize
        return Menu {
            Button(q == nil ? "✓ Off (as played)" : "Off (as played)") { session.updateTrack(track.id) { $0.quantize = nil } }
            Section("Grid") {
                ForEach(Quantize.Grid.allCases) { g in
                    Button((q?.grid == g ? "✓ " : "") + g.label) {
                        session.updateTrack(track.id) { t in
                            var nq = t.quantize ?? Quantize()
                            nq.grid = g
                            t.quantize = nq
                        }
                    }
                }
            }
            Menu("Strength (\(Int((q?.strength ?? 1) * 100))%)") {
                ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { v in
                    Button("\(Int(v * 100))%") {
                        session.updateTrack(track.id) { t in var nq = t.quantize ?? Quantize(); nq.strength = v; t.quantize = nq }
                    }
                }
            }
            Menu("Swing (\(q.map { $0.swing <= 0.501 ? "straight" : "\(Int(($0.swing * 100).rounded()))%" } ?? "straight"))") {
                ForEach([0.5, 0.54, 0.58, 0.62, 0.66], id: \.self) { v in
                    Button(v == 0.5 ? "Straight" : "\(Int((v * 100).rounded()))%") {
                        session.updateTrack(track.id) { t in var nq = t.quantize ?? Quantize(); nq.swing = v; t.quantize = nq }
                    }
                }
            }
        } label: {
            Text("Q")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 22, height: 18)
                .foregroundStyle(q != nil ? Color.black : Theme.dim)
                .background(RoundedRectangle(cornerRadius: 4).fill(q != nil ? Color.mint : Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(q.map { "Quantize \($0.grid.label), \(Int($0.strength * 100))%\($0.swing > 0.501 ? ", swing \(Int(($0.swing * 100).rounded()))%" : "") — notes play on the grid, the recording stays as played" }
              ?? "Quantize (off): notes play as recorded")
    }

    private var instrumentLabel: String {
        if let ext = track.external { return "⇄ \(ext.deviceName) ch\(ext.channel)" }
        return track.instrument?.name ?? GMPrograms.name(track.program)
    }

    /// Which interface input the outboard gear comes back on, heard through this track's strip.
    private func audioReturnMenu(_ ext: ExternalMIDI) -> some View {
        let n = max(1, session.inputChannelCount)
        let current = !ext.audioReturn ? "off"
            : track.channels == 2 ? "In \(track.inputChannel + 1)-\(track.inputChannel + 2)" : "In \(track.inputChannel + 1)"
        return Menu("Audio return (\(current))") {
            Button("Off") { session.updateTrack(track.id) { $0.external?.audioReturn = false } }
            Section("Mono") {
                ForEach(0..<n, id: \.self) { c in
                    Button("Input \(c + 1)") {
                        session.updateTrack(track.id) { $0.external?.audioReturn = true; $0.channels = 1; $0.inputChannel = c }
                    }
                }
            }
            if n >= 2 {
                Section("Stereo") {
                    ForEach(Array(stride(from: 0, to: n - 1, by: 2)), id: \.self) { c in
                        Button("Inputs \(c + 1)-\(c + 2)") {
                            session.updateTrack(track.id) { $0.external?.audioReturn = true; $0.channels = 2; $0.inputChannel = c }
                        }
                    }
                }
            }
        }
    }
}

/// Every plugin on a track (instrument and effects) in one place: click one to open its window.
struct FXMenu: View {
    @Bindable var session: Session
    let track: Track

    private var slots: [PluginSlot] { (track.instrument.map { [$0] } ?? []) + track.inserts }

    var body: some View {
        let problem = slots.contains { session.pluginStatus($0) != nil }
        Menu {
            if track.kind == .midi {
                Section("Instrument") {
                    if let ext = track.external {
                        Menu("External: \(ext.deviceName) ch\(ext.channel)") {
                            instrumentChoices
                            Divider()
                            Button("Stop using \(ext.deviceName)") { session.setExternal(nil, on: track.id) }
                        }
                    } else if let slot = track.instrument {
                        Menu(label(slot)) {
                            Button("Open Editor") { session.openEditor(slot, track: track) }
                            instrumentChoices
                            Divider()
                            Button("Remove (use built-in sounds)") { session.setInstrument(nil, on: track.id) }
                        }
                    } else {
                        Menu("Built-in: \(GMPrograms.name(track.program))") { instrumentChoices }
                    }
                }
            }
            Section("Effects") {
                if track.inserts.isEmpty {
                    Text("No effects yet")
                }
                ForEach(track.inserts) { slot in
                    Menu(label(slot)) {
                        Button("Open Editor") { session.openEditor(slot, track: track) }
                        Button(slot.bypass ? "Enable" : "Bypass") { session.toggleBypass(slot.id, in: track.id) }
                        Button("Move Up") { session.moveInsert(slot.id, in: track.id, by: -1) }
                            .disabled(track.inserts.first?.id == slot.id)
                        Button("Move Down") { session.moveInsert(slot.id, in: track.id, by: 1) }
                            .disabled(track.inserts.last?.id == slot.id)
                        Divider()
                        Button("Remove") { session.removeInsert(slot.id, from: track.id) }
                    }
                }
            }
            Menu("Add Effect") {
                ForEach(PluginCatalog.grouped(PluginCatalog.effects), id: \.0) { group in
                    Menu(group.0) {
                        ForEach(group.1) { info in
                            Button(info.name) { session.addInsert(info, to: track.id) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(slots.isEmpty ? "FX" : "FX \(slots.count)")
                if problem { Circle().fill(Color.orange).frame(width: 5, height: 5) }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(slots.isEmpty ? Theme.dim : Theme.accent)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(slots.isEmpty ? "Add an Audio Unit effect" : "Open this track's plugins")
    }

    /// Swap the instrument: Audio Units by manufacturer, or a built-in sound.
    @ViewBuilder private var instrumentChoices: some View {
        Menu("Change Instrument") {
            Menu("Built-in sounds") {
                ForEach(GMPrograms.list, id: \.0) { p in
                    Button(p.1) { session.updateTrack(track.id) { $0.program = p.0; $0.instrument = nil } }
                }
            }
            ForEach(PluginCatalog.grouped(PluginCatalog.instruments), id: \.0) { group in
                Menu(group.0) {
                    ForEach(group.1) { info in
                        Button(info.name) { session.setInstrument(info, on: track.id) }
                    }
                }
            }
        }
    }

    private func label(_ slot: PluginSlot) -> String {
        var s = slot.name
        if slot.bypass { s += " (bypassed)" }
        if let status = session.pluginStatus(slot) { s += " — " + (status == "Loading…" ? "loading" : "failed") }
        return s
    }
}
