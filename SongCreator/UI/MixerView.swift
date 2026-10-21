import SwiftUI

struct MixerView: View {
    @Bindable var session: Session

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 2) {
                ForEach(session.song.tracks) { track in
                    ChannelStripView(session: session, track: track)
                }
                Spacer(minLength: 12)
                ReturnsStrip(session: session)
                MasterStrip(session: session)
            }
            .padding(6)
        }
        .background(Theme.background)
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
        VStack(spacing: 6) {
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

            HStack(spacing: 0) {
                Knob(value: session.stripBinding(id, \.reverbSend), range: 0...1, label: "Verb",
                     format: { String(format: "%.0f%%", $0 * 100) }, color: .purple)
                Knob(value: session.stripBinding(id, \.delaySend), range: 0...1, label: "Delay",
                     format: { String(format: "%.0f%%", $0 * 100) }, color: .cyan)
            }

            Knob(value: session.stripBinding(id, \.pan), range: -1...1, label: "Pan",
                 format: { $0 == 0 ? "C" : ($0 < 0 ? String(format: "L%.0f", -$0 * 100) : String(format: "R%.0f", $0 * 100)) })

            HStack(spacing: 3) {
                Fader(db: session.stripBinding(id, \.volumeDB), height: 120)
                MeterBar(level: { [audio = session.audio] in audio.meters.level(id) }).frame(width: 5, height: 112)
            }
            Text(s.volumeDB.dbString).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
            HStack(spacing: 3) {
                LitButton(label: "M", on: track.mute, color: .orange) { session.updateTrack(id, undoable: false) { $0.mute.toggle() } }
                LitButton(label: "S", on: track.solo, color: .yellow) { session.updateTrack(id, undoable: false) { $0.solo.toggle() } }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 92)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { session.selectedTrackID = id }
    }
}

struct ReturnsStrip: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 8) {
            Text("FX RETURNS").font(.system(size: 10, weight: .bold)).frame(maxWidth: .infinity)
                .padding(.vertical, 3).background(Color.white.opacity(0.08))
            Text("Reverb").font(.caption.bold()).foregroundStyle(.purple)
            Picker("", selection: $session.song.master.reverbRoom) {
                ForEach(ReverbRoom.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 100)
            Knob(value: $session.song.master.reverbReturnDB, range: -30...6, label: "Return",
                 format: { String(format: "%+.1f dB", $0) }, color: .purple)
            Divider()
            Text("Delay").font(.caption.bold()).foregroundStyle(.cyan)
            Picker("", selection: $session.song.master.delayDivision) {
                ForEach(DelayDivision.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 100)
            HStack(spacing: 0) {
                Knob(value: $session.song.master.delayFeedback, range: 0...90, defaultValue: 30, label: "Fdbk",
                     format: { String(format: "%.0f%%", $0) }, color: .cyan)
                Knob(value: $session.song.master.delayReturnDB, range: -30...6, label: "Return",
                     format: { String(format: "%+.1f dB", $0) }, color: .cyan)
            }
            Text("Synced to tempo").font(.system(size: 9)).foregroundStyle(Theme.dim)
            Spacer()
        }
        .padding(.bottom, 6)
        .frame(width: 120)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct MasterStrip: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 8) {
            Text("MASTER").font(.system(size: 10, weight: .bold)).frame(maxWidth: .infinity)
                .padding(.vertical, 3).background(Theme.accent.opacity(0.35))
            LitButton(label: "LIMIT", on: session.song.master.limiterOn, color: .green, width: 52,
                      help: "Peak limiter on the mix bus") { session.song.master.limiterOn.toggle() }
            Spacer()
            HStack(spacing: 3) {
                Fader(db: $session.song.master.volumeDB, height: 170)
                MeterBar(level: { [audio = session.audio] in audio.meters.level(MeterStore.masterID) })
                    .frame(width: 6, height: 162)
            }
            Text(session.song.master.volumeDB.dbString).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .padding(.bottom, 6)
        .frame(width: 90)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The track's Audio Unit effects, after the built-in EQ and compressor.
struct InsertSlots: View {
    @Bindable var session: Session
    let track: Track

    var body: some View {
        VStack(spacing: 2) {
            ForEach(track.inserts) { slot in
                let status = session.pluginStatus(slot)
                HStack(spacing: 2) {
                    Circle().fill(slot.bypass ? Theme.dim.opacity(0.4) : (status == nil ? Color.green : Color.orange))
                        .frame(width: 5, height: 5)
                    Text(slot.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                        .foregroundStyle(slot.bypass ? Theme.dim : Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
                .onTapGesture { session.openEditor(slot, track: track) }
                .help(status ?? "\(slot.manufacturer) \(slot.name) — click to open")
                .contextMenu {
                    Button("Open Editor") { session.openEditor(slot, track: track) }
                    Button(slot.bypass ? "Enable" : "Bypass") { session.toggleBypass(slot.id, in: track.id) }
                    Button("Move Up") { session.moveInsert(slot.id, in: track.id, by: -1) }
                    Button("Move Down") { session.moveInsert(slot.id, in: track.id, by: 1) }
                    Divider()
                    Button("Remove") { session.removeInsert(slot.id, from: track.id) }
                }
            }
            Menu {
                ForEach(PluginCatalog.grouped(PluginCatalog.effects), id: \.0) { group in
                    Menu(group.0) {
                        ForEach(group.1) { info in
                            Button(info.name) { session.addInsert(info, to: track.id) }
                        }
                    }
                }
            } label: {
                Text("+ Insert").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 4)
    }
}
