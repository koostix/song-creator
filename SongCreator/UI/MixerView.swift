import SwiftUI

struct MixerView: View {
    @Bindable var session: Session

    /// Strips are never shorter than this; a shorter mixer scrolls. Extra height goes to the effect slots.
    static let minStripHeight: CGFloat = Session.defaultMixerHeight - 12
    /// Height of a row of send knobs. Two buses fit in one row; each further two add a row.
    static let sendRowHeight: CGFloat = 42

    static func stripHeight(buses: Int) -> CGFloat {
        minStripHeight + CGFloat(max(0, (buses + 1) / 2 - 1)) * sendRowHeight
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(session.song.tracks) { track in
                        ChannelStripView(session: session, track: track)
                    }
                    Spacer(minLength: 12)
                    ForEach(Array(session.song.buses.enumerated()), id: \.element.id) { i, bus in
                        BusStrip(session: session, bus: bus, color: BusStrip.color(i))
                    }
                    AddBusButton(session: session)
                    MasterStrip(session: session)
                }
                .frame(height: max(MixerView.stripHeight(buses: session.song.buses.count), geo.size.height - 12))
                .padding(6)
            }
        }
        .background(Theme.background)
        .environment(\.continuousEdit, session.continuousEdit)
    }
}

/// The mixer's top edge: drag to resize it, double-click (or the button) to fill the window.
struct MixerBar: View {
    @Bindable var session: Session
    /// Tallest the mixer may get under the tracks.
    let maxHeight: CGFloat
    @State private var startHeight: CGFloat?
    @State private var hover = false

    private var full: Bool { session.mixerFull }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            Capsule().fill(hover || startHeight != nil ? Theme.accent.opacity(0.8) : Theme.dim.opacity(0.5))
                .frame(width: 36, height: 3)
                .opacity(full ? 0 : 1)
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { session.mixerFull.toggle() }
                } label: {
                    Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 22, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(full ? "Put the mixer back under the tracks (⇧X)" : "Mixer fills the window (⇧X)")
                .padding(.trailing, 8)
            }
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { inside in
            guard !full else { return }
            hover = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                guard !full else { return }
                let start = startHeight ?? min(session.mixerHeight, maxHeight)
                startHeight = start
                session.mixerHeight = min(maxHeight, max(Session.minMixerHeight, (start - v.translation.height).rounded()))
            }
            .onEnded { _ in startHeight = nil })
        .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.15)) { session.mixerFull.toggle() } }
        .help(full ? "Double-click to put the mixer back under the tracks"
                   : "Drag to resize the mixer, double-click to fill the window")
    }
}

extension Session {
    /// Live (non-undoable) binding into a track's channel strip, for knobs and faders.
    func stripBinding<T>(_ id: UUID, _ key: WritableKeyPath<ChannelStrip, T>) -> Binding<T> {
        Binding(
            get: { (self.song.tracks.first { $0.id == id }?.strip ?? ChannelStrip())[keyPath: key] },
            set: { v in self.updateTrack(id, undoable: false) { $0.strip[keyPath: key] = v } })
    }
}

struct ChannelStripView: View {
    @Bindable var session: Session
    let track: Track

    var body: some View {
        let id = track.id
        let s = track.strip
        VStack(spacing: 4) {
            Text(track.name).font(.system(size: 10, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Theme.color(track.colorIndex).opacity(0.35))

            InsertSlots(session: session, track: track)

            HStack(spacing: 3) {
                LitButton(label: "EQ", on: s.eqOn, width: 24) { session.updateTrack(id) { $0.strip.eqOn.toggle() } }
                LitButton(label: "HP", on: s.hpfOn, width: 24, help: "High-pass at 90 Hz") { session.updateTrack(id) { $0.strip.hpfOn.toggle() } }
            }
            HStack(spacing: 0) {
                Knob(value: session.stripBinding(id, \.lowGain), range: -12...12, label: "Low",
                     format: { String(format: "%+.1f dB", $0) }, color: .orange)
                Knob(value: session.stripBinding(id, \.highGain), range: -12...12, label: "High",
                     format: { String(format: "%+.1f dB", $0) }, color: .orange)
            }
            .opacity(s.eqOn ? 1 : 0.4)
            HStack(spacing: 0) {
                Knob(value: session.stripBinding(id, \.midGain), range: -12...12, label: "Mid",
                     format: { String(format: "%+.1f dB", $0) }, color: .orange)
                Knob(value: session.stripBinding(id, \.midFreq), range: 200...6000, defaultValue: 1000, label: "Freq",
                     format: { $0 >= 1000 ? String(format: "%.1fk", $0 / 1000) : String(format: "%.0f", $0) },
                     color: .orange, logarithmic: true)
            }
            .opacity(s.eqOn ? 1 : 0.4)

            LitButton(label: "COMP", on: s.compOn, color: .green, width: 50) { session.updateTrack(id) { $0.strip.compOn.toggle() } }
            HStack(spacing: 0) {
                Knob(value: session.stripBinding(id, \.compThreshold), range: -40...0, defaultValue: -18, label: "Thresh",
                     format: { String(format: "%.0f dB", $0) }, color: .green)
                Knob(value: session.stripBinding(id, \.compMakeup), range: 0...20, defaultValue: 4, label: "Gain",
                     format: { String(format: "+%.1f", $0) }, color: .green)
            }
            .opacity(s.compOn ? 1 : 0.4)

            SendKnobs(session: session, trackID: id)

            Knob(value: session.stripBinding(id, \.pan), range: -1...1, label: "Pan",
                 format: { $0 == 0 ? "C" : ($0 < 0 ? String(format: "L%.0f", -$0 * 100) : String(format: "R%.0f", $0 * 100)) })

            HStack(spacing: 3) {
                Fader(db: session.stripBinding(id, \.volumeDB), height: 104)
                MeterBar(level: { [audio = session.audio] in audio.meters.level(id) }).frame(width: 5, height: 96)
            }
            Text(s.volumeDB.dbString).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
            HStack(spacing: 3) {
                LitButton(label: "M", on: track.mute, color: .orange) { session.updateTrack(id, undoable: false) { $0.mute.toggle() } }
                LitButton(label: "S", on: track.solo, color: .yellow) { session.updateTrack(id, undoable: false) { $0.solo.toggle() } }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 92)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { session.selectedTrackID = id }
    }
}

/// A track's send to each bus, two to a row, in the buses' colors.
struct SendKnobs: View {
    @Bindable var session: Session
    let trackID: UUID

    var body: some View {
        let buses = session.song.buses
        VStack(spacing: 4) {
            ForEach(Array(stride(from: 0, to: buses.count, by: 2)), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row..<min(row + 2, buses.count), id: \.self) { i in
                        Knob(value: session.sendBinding(track: trackID, bus: buses[i].id), range: 0...1,
                             label: buses[i].name, format: { String(format: "%.0f%%", $0 * 100) }, color: BusStrip.color(i))
                    }
                }
            }
        }
    }
}

/// An effect bus: its plugins, then the return fader into the mix.
struct BusStrip: View {
    @Bindable var session: Session
    let bus: Bus
    let color: Color
    @State private var renaming = false
    @State private var newName = ""

    static let colors: [Color] = [.purple, .cyan, .pink, .mint, .indigo, .teal, .yellow, .orange]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }

    var body: some View {
        VStack(spacing: 4) {
            Text(bus.name).font(.system(size: 10, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(color.opacity(0.35))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { startRename() }
                .help("\(bus.name) bus — tracks send to it with their \(bus.name) knob. Double-click to rename.")
                .contextMenu {
                    Button("Rename…") { startRename() }
                    Divider()
                    Button("Remove Bus") { session.removeBus(bus.id) }
                }
            InsertSlots(session: session, bus: bus)
            HStack(spacing: 3) {
                Fader(db: session.busReturnBinding(bus.id), height: 104)
                MeterBar(level: { [audio = session.audio, id = bus.id] in audio.meters.level(id) }).frame(width: 5, height: 96)
            }
            .help("Return: how much of the bus goes into the mix")
            Text(bus.returnDB.dbString).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
            LitButton(label: "M", on: bus.mute, color: .orange, help: "Mute the bus") {
                session.updateBus(bus.id, undoable: false) { $0.mute.toggle() }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 92)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .alert("Rename Bus", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { session.renameBus(bus.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startRename() {
        newName = bus.name
        renaming = true
    }
}

/// Adds an effect bus; every track gets a send knob for it.
struct AddBusButton: View {
    @Bindable var session: Session

    var body: some View {
        Button { session.addBus() } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Bus").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.dim)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add an effect bus: put plugins on it, and every track gets a send knob for it")
    }
}

struct MasterStrip: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 8) {
            Text("MASTER").font(.system(size: 10, weight: .bold)).frame(maxWidth: .infinity)
                .padding(.vertical, 3).background(Theme.accent.opacity(0.35))
            // The mix flows top to bottom: the master's plugins, then the fader, then the limiter.
            InsertSlots(masterOf: session)
                .padding(.top, -4)
            LitButton(label: "LIMIT", on: session.song.master.limiterOn, color: .green, width: 52,
                      help: "Peak limiter on the mix bus, after the master's plugins and fader") { session.song.master.limiterOn.toggle() }
            HStack(spacing: 3) {
                Fader(db: $session.song.master.volumeDB, height: 150)
                MeterBar(level: { [audio = session.audio] in audio.meters.level(MeterStore.masterID) })
                    .frame(width: 6, height: 142)
            }
            Text(session.song.master.volumeDB.dbString).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .padding(.bottom, 6)
        .frame(width: 110)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The track's Audio Unit effects, after the built-in EQ and compressor.
/// One plugin in a strip: click the name to open its editor, ⏻ bypasses, × removes.
struct PluginRow: View {
    let name: String
    let status: String?
    var bypassed = false
    var onBypass: (() -> Void)?
    let onOpen: () -> Void
    let onRemove: () -> Void
    var removeHelp = "Remove this plugin"
    /// Extra detail for the hover help, like a delay's tempo sync.
    var note: String?

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(bypassed ? Theme.dim.opacity(0.4) : (status == nil ? Color.green : Color.orange))
                .frame(width: 5, height: 5)
            Text(name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                .foregroundStyle(bypassed ? Theme.dim : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .help(status ?? "\(name)\(note.map { " (\($0))" } ?? "") — click to open its editor")
            if let onBypass {
                Button(action: onBypass) {
                    Image(systemName: "power").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(bypassed ? Theme.dim : Color.green)
                }
                .buttonStyle(.plain)
                .help(bypassed ? "Bypassed — click to enable" : "Click to bypass")
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help(removeHelp)
        }
        .padding(.horizontal, 4).frame(height: 16)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
    }
}

/// The track's plugins: a MIDI track's instrument first, then its effects after the built-in EQ and compressor.
/// Takes the strip's spare height, so a taller mixer shows more of a long effect chain.
struct InsertSlots: View {
    @Bindable var session: Session
    /// The track or bus, or Song.masterID.
    let ownerID: UUID
    let inserts: [PluginSlot]
    /// A track's strip (MIDI tracks show their instrument first); nil on the master.
    let track: Track?

    init(session: Session, track: Track) {
        self.session = session
        ownerID = track.id
        inserts = track.inserts
        self.track = track
    }

    /// A bus's plugins, before its return fader.
    init(session: Session, bus: Bus) {
        self.session = session
        ownerID = bus.id
        inserts = bus.inserts
        track = nil
    }

    /// The master's plugins, before its fader and limiter.
    init(masterOf session: Session) {
        self.session = session
        ownerID = Song.masterID
        inserts = session.song.master.inserts
        track = nil
    }

    private var hasInstrument: Bool { track?.kind == .midi }

    static let rowHeight: CGFloat = 18
    /// Three rows and the "+ Insert" line: the size at the default mixer height.
    static let minHeight: CGFloat = 3 * rowHeight + 14

    /// How many plugin rows fit in `height`, and how many of the effects to show in them.
    static func layout(height: CGFloat, instrument: Bool, inserts: Int) -> (effects: Int, more: Int) {
        let rows = max(1, Int((height - 14) / rowHeight))
        let slots = rows - (instrument ? 1 : 0)
        if inserts <= slots { return (inserts, 0) }
        let shown = max(0, slots - 1)          // the last row says how many more there are
        return (shown, inserts - shown)
    }

    var body: some View {
        GeometryReader { geo in
            let fit = InsertSlots.layout(height: geo.size.height, instrument: hasInstrument, inserts: inserts.count)
            VStack(spacing: 2) {
                if let track, hasInstrument { instrumentRow(track) }
                ForEach(inserts.prefix(fit.effects)) { slot in effectRow(slot) }
                if fit.more > 0 { moreRow(fit.more) }
                addMenu
            }
            .padding(.horizontal, 4)
            .frame(width: geo.size.width, alignment: .top)
        }
        .frame(minHeight: InsertSlots.minHeight, maxHeight: .infinity)
    }

    @ViewBuilder private func instrumentRow(_ track: Track) -> some View {
        if let ext = track.external {
            PluginRow(name: "⇄ \(ext.deviceName) ch\(ext.channel)",
                      status: session.isConnected(ext) ? nil : "\(ext.deviceName) isn't connected",
                      onOpen: {},
                      onRemove: { session.setExternal(nil, on: track.id) },
                      removeHelp: "Stop using the external MIDI device")
                .help("Plays outboard gear over MIDI\(ext.audioReturn ? ", heard back through this strip" : "")")
        } else if let inst = track.instrument {
            PluginRow(name: inst.name, status: session.pluginStatus(inst),
                      onOpen: { session.openEditor(inst, track: track) },
                      onRemove: { session.setInstrument(nil, on: track.id) },
                      removeHelp: "Remove — go back to the built-in sounds")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "pianokeys").font(.system(size: 8))
                Text(GMPrograms.name(track.program)).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 4).frame(height: 16)
            .help("Built-in sound — change it in the track header")
        }
    }

    private func effectRow(_ slot: PluginSlot) -> some View {
        PluginRow(name: slot.name, status: session.pluginStatus(slot), bypassed: slot.bypass,
                  onBypass: { session.toggleBypass(slot.id, in: ownerID) },
                  onOpen: { session.openEditor(slot, owner: ownerID) },
                  onRemove: { session.removeInsert(slot.id, from: ownerID) },
                  note: slot.tempoSync.map { "synced to \($0.label) notes; right-click to change" })
            .contextMenu {
                Button("Open Editor") { session.openEditor(slot, owner: ownerID) }
                Button(slot.bypass ? "Enable" : "Bypass") { session.toggleBypass(slot.id, in: ownerID) }
                Button("Move Up") { session.moveInsert(slot.id, in: ownerID, by: -1) }
                Button("Move Down") { session.moveInsert(slot.id, in: ownerID, by: 1) }
                if slot.isAppleDelay {
                    Picker("Sync to Tempo", selection: Binding(
                        get: { slot.tempoSync },
                        set: { session.setTempoSync(slot.id, in: ownerID, $0) })) {
                        Text("Off").tag(DelayDivision?.none)
                        ForEach(DelayDivision.allCases) { Text($0.label).tag(DelayDivision?.some($0)) }
                    }
                }
                Divider()
                Button("Remove") { session.removeInsert(slot.id, from: ownerID) }
            }
    }

    /// Stands in for the effects that don't fit: click to give the mixer the whole window.
    @ViewBuilder private func moreRow(_ count: Int) -> some View {
        let label = Text("+\(count) more").font(.system(size: 9, weight: .semibold))
        if session.mixerFull {
            label.foregroundStyle(Theme.dim).frame(height: 16)
                .help(track == nil ? "Make the mixer taller to see every plugin" : "The track's FX button lists every plugin")
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { session.mixerFull = true }
            } label: {
                HStack(spacing: 3) {
                    label
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show every effect: the mixer fills the window (⇧X)")
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(PluginCatalog.grouped(PluginCatalog.effects), id: \.0) { group in
                Menu(group.0) {
                    ForEach(group.1) { info in
                        Button(info.name) { session.addInsert(info, to: ownerID) }
                    }
                }
            }
        } label: {
            Text("+ Insert").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
