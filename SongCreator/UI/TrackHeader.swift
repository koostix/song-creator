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

    private var selected: Bool { session.selectedTrackIDs.contains(track.id) }

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
                    FXButton(session: session, track: track)
                        .frame(width: 30, alignment: .leading)
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
                    if track.kind == .midi {
                        quantizeMenu
                    } else {
                        LitButton(label: "I", on: track.monitor,
                                  color: session.monitoringMuted || !session.inputEnabled ? Color.orange : Theme.accent,
                                  help: !session.inputEnabled ? "Input monitoring (the audio input is switched off)"
                                    : session.monitoringMuted ? "Input monitoring is muted by feedback protection while sound plays through the speakers. Use headphones to hear yourself."
                                    : "Input monitoring: while this track is armed, hear its input through its effects and plugins") {
                            session.updateTrack(track.id, undoable: false) { $0.monitor.toggle() }
                        }
                    }
                    LitButton(label: "A", on: track.showAutomation, color: .green, help: "Show volume/pan automation") {
                        session.updateTrack(track.id, undoable: false) { $0.showAutomation.toggle() }
                    }
                    Group {
                        if track.kind == .audio { inputMenu } else { instrumentMenu }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
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
        .onTapGesture {
            session.selectTrack(track.id, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
        }
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
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(track.instrument.flatMap { session.pluginStatus($0) } != nil ? Color.orange
                                 : track.external.map { session.isConnected($0) ? Theme.accent : Color.orange } ?? Theme.text)
        }
        .menuStyle(.borderlessButton)
        .help(track.external.map { ext in session.isConnected(ext)
                  ? "Plays \(ext.deviceName) on MIDI channel \(ext.channel)"
                  : "\(ext.deviceName) isn't connected. Plug it in, or pick another instrument here." }
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
                .foregroundStyle(q != nil ? Color.black : Theme.dim)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        // A menu's label can't carry a background on macOS, so the button shape sits behind the menu.
        .frame(width: 22, height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(q != nil ? Color.mint : Color.white.opacity(0.08)))
        .help(q.map { "Quantize \($0.grid.label), \(Int($0.strength * 100))%\($0.swing > 0.501 ? ", swing \(Int(($0.swing * 100).rounded()))%" : "") — notes play on the grid, the recording stays as played" }
              ?? "Quantize (off): notes play as recorded")
    }

    private var instrumentLabel: String {
        if let ext = track.external {
            // Orange when it isn't connected; the tooltip says so.
            return "⇄ \(ext.deviceName) ch\(ext.channel)"
        }
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

/// The track's plugin chain, one click away: the FX button opens it, a name opens that plugin's editor,
/// the power button turns an effect on or off, and dragging a row moves it in the chain.
struct FXButton: View {
    @Bindable var session: Session
    let track: Track
    @State private var showing = false

    private var slots: [PluginSlot] { (track.instrument.map { [$0] } ?? []) + track.inserts }

    var body: some View {
        let problem = slots.contains { session.pluginStatus($0) != nil }
        Button { showing.toggle() } label: {
            HStack(spacing: 2) {
                Text(track.inserts.isEmpty ? "FX" : "FX \(track.inserts.count)")
                if problem { Circle().fill(Color.orange).frame(width: 5, height: 5) }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(track.inserts.isEmpty ? Theme.dim : Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(track.inserts.isEmpty ? "Add an Audio Unit effect" : "This track's effects")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FXChainPanel(session: session, trackID: track.id)
        }
    }
}

struct FXChainPanel: View {
    @Bindable var session: Session
    let trackID: UUID

    static let rowHeight: CGFloat = 30

    var body: some View {
        if let track = session.song.tracks.first(where: { $0.id == trackID }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(track.name).font(.headline)
                if track.kind == .midi { instrumentRow(track) }
                Text(track.inserts.isEmpty ? "No effects yet" : "Effects · the sound flows top to bottom, drag to reorder")
                    .font(.caption).foregroundStyle(Theme.dim)
                if !track.inserts.isEmpty {
                    List {
                        ForEach(track.inserts) { slot in
                            effectRow(slot, track: track)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                        .onMove { from, to in session.moveInserts(in: trackID, from: from, to: to) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(track.inserts.count <= 8)
                    .frame(height: CGFloat(min(track.inserts.count, 8)) * Self.rowHeight + 4)
                }
                addMenu
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private func effectRow(_ slot: PluginSlot, track: Track) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
                .help("Drag to move it in the chain")
            Button { session.toggleBypass(slot.id, in: trackID) } label: {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 18)
                    .foregroundStyle(slot.bypass ? Theme.dim : Color.black)
                    .background(RoundedRectangle(cornerRadius: 4).fill(slot.bypass ? Color.white.opacity(0.08) : Theme.accent))
            }
            .buttonStyle(.plain)
            .help(slot.bypass ? "Off: click to turn it on" : "On: click to turn it off and hear the track without it")
            .accessibilityLabel(slot.bypass ? "Turn \(slot.name) on" : "Turn \(slot.name) off")
            editorButton(slot, track: track, dimmed: slot.bypass)
            Button { session.removeInsert(slot.id, from: trackID) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(slot.name)")
            .accessibilityLabel("Remove \(slot.name)")
        }
        .frame(height: Self.rowHeight)
    }

    /// The plugin's name; clicking it opens the plugin's own window.
    private func editorButton(_ slot: PluginSlot, track: Track, dimmed: Bool) -> some View {
        let status = session.pluginStatus(slot)
        return Button { session.openEditor(slot, track: track) } label: {
            HStack(spacing: 6) {
                Text(slot.name).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(dimmed ? Theme.dim : Theme.text)
                Spacer(minLength: 4)
                if let status {
                    Text(status == "Loading…" ? "loading" : "failed").font(.caption2).foregroundStyle(Color.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(status.map { $0 == "Loading…" ? "\(slot.name) is still loading" : $0 } ?? "Open \(slot.name)")
    }

    @ViewBuilder private func instrumentRow(_ track: Track) -> some View {
        HStack(spacing: 8) {
            // Lines the name up with the effect names below (handle, gap, power button).
            Image(systemName: "pianokeys").font(.system(size: 10)).foregroundStyle(Theme.dim).frame(width: 42, alignment: .leading)
            if let slot = track.instrument {
                editorButton(slot, track: track, dimmed: false)
            } else if let ext = track.external {
                Text("\(ext.deviceName) ch\(ext.channel)").lineLimit(1).foregroundStyle(Theme.dim)
            } else {
                Text("Built-in: \(GMPrograms.name(track.program))").lineLimit(1).foregroundStyle(Theme.dim)
            }
        }
        .padding(.leading, 8)   // the list's own inset, so this row lines up with the effects
        .help("Change the instrument from the menu next to A on the track")
    }

    private var addMenu: some View {
        Menu {
            ForEach(PluginCatalog.grouped(PluginCatalog.effects), id: \.0) { group in
                Menu(group.0) {
                    ForEach(group.1) { info in
                        Button(info.name) { session.addInsert(info, to: trackID) }
                    }
                }
            }
        } label: {
            Label("Add Effect", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// On/off for one effect, shown in its editor window's title bar.
struct PluginPowerButton: View {
    @Bindable var session: Session
    /// The slot's track, or Song.masterID.
    let ownerID: UUID
    let slotID: UUID

    var body: some View {
        let on = !(session.inserts(of: ownerID).first { $0.id == slotID }?.bypass ?? false)
        Button { session.toggleBypass(slotID, in: ownerID) } label: {
            HStack(spacing: 4) {
                Image(systemName: "power").font(.system(size: 10, weight: .bold))
                Text(on ? "On" : "Off").font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 54, height: 20)
            .foregroundStyle(on ? Color.black : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.accent : Color.gray.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .help(on ? "On: click to turn it off and hear the track without it" : "Off: click to turn it back on")
        .accessibilityLabel(on ? "Turn off" : "Turn on")
    }
}
