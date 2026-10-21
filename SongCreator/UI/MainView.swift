import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var session: Session
    @Environment(AppModel.self) private var model
    @State private var keyMonitor: Any?
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(session: session)
            Divider().overlay(Color.black)
            ArrangeView(session: session)
            if session.showMixer {
                Divider().overlay(Color.black)
                MixerView(session: session)
                    .frame(height: 430)
                    .transition(.move(edge: .bottom))
            }
            StatusBar(session: session)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { installKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in showExport = true }
        .onReceive(NotificationCenter.default.publisher(for: .importAudio)) { _ in importPanel() }
        .sheet(isPresented: $showExport) { ExportSheet(session: session) }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Each file becomes a new track at the playhead."
        if panel.runModal() == .OK { session.importAudio(panel.urls) }
    }

    /// Single-key shortcuts, like a hardware recorder. Ignored while typing in a text field.
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return event }
            if NSApp.keyWindow?.attachedSheet != nil || showExport { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if flags == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": session.copyRegions(); return nil
                case "v": session.pasteRegions(); return nil
                case "d": session.duplicateRegions(); return nil
                default: return event
                }
            }
            if flags.contains(.command) || flags.contains(.control) { return event }
            let shift = flags.contains(.shift), option = flags.contains(.option)
            let s = session
            let selected = s.selectedTrackID ?? s.song.tracks.first?.id

            switch event.keyCode {
            case 49: s.togglePlay(); return nil                       // space
            case 36, 76: s.goToStart(); return nil                    // return / enter
            case 123: option ? s.jumpMarker(forward: false) : s.nudgeBar(forward: false); return nil
            case 124: option ? s.jumpMarker(forward: true) : s.nudgeBar(forward: true); return nil
            case 51, 117: s.deleteSelection(); return nil             // delete
            case 53: s.selection = nil; s.selectedRegions = []; return nil   // escape
            default: break
            }

            guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            switch ch {
            case "r": s.toggleRecord()
            case "b": s.splitAtPlayhead()
            case "l": shift ? s.loopSelection() : s.toggleLoop()
            case "p": shift ? s.punchSelection() : s.edit { $0.punchEnabled.toggle() }
            case "c": s.song.clickEnabled.toggle()
            case "m":
                if shift { s.addMarker() } else if let id = selected { s.updateTrack(id, undoable: false) { $0.mute.toggle() } }
            case "s": if let id = selected { s.updateTrack(id, undoable: false) { $0.solo.toggle() } }
            case "a": if let id = selected { s.toggleArm(id) }
            case "t": s.addTrack(kind: shift ? .midi : .audio)
            case "x": withAnimation(.easeOut(duration: 0.15)) { s.showMixer.toggle() }
            case "=", "+": s.pixelsPerSecond = min(800, s.pixelsPerSecond * 1.25)
            case "-": s.pixelsPerSecond = max(4, s.pixelsPerSecond / 1.25)
            case "1"..."9": s.jumpToMarker(index: Int(String(ch))! - 1)
            default: return event
            }
            return nil
        }
    }
}

struct StatusBar: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 12) {
            if let msg = session.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).lineLimit(1)
                Button("Dismiss") { session.message = nil }.buttonStyle(.link)
            } else {
                Text(session.isRecording ? "Recording… press R or Space to stop"
                     : "Space play · R record · ⇧M marker · L loop · T new track · X mixer · drag across a take lane to comp")
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            Text("\(Int(session.sampleRate / 1000)) kHz · \(session.inputChannelCount) in · \(session.midiSources.count) MIDI")
                .foregroundStyle(Theme.dim)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.panel)
    }
}

struct TransportBar: View {
    @Bindable var session: Session
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Button { model.closeSong() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Back to songs")
            TextField("Song name", text: $session.song.name)
                .textFieldStyle(.plain).font(.headline).frame(width: 170)

            HStack(spacing: 6) {
                TransportButton(icon: "backward.end.fill", help: "Go to start (Return)") { session.goToStart() }
                TransportButton(icon: session.isPlaying ? "stop.fill" : "play.fill",
                                active: session.isPlaying && !session.isRecording, help: "Play / Stop (Space)") { session.togglePlay() }
                TransportButton(icon: "record.circle.fill", active: session.isRecording, activeColor: Theme.record,
                                tint: Theme.record, help: "Record (R)") { session.toggleRecord() }
            }

            PositionDisplay(session: session, playhead: session.playhead)

            HStack(spacing: 4) {
                LitButton(label: "LOOP", on: session.song.loopEnabled, color: Theme.loop, width: 40,
                          help: "Cycle (L). Drag in the ruler to set the range.") { session.toggleLoop() }
                LitButton(label: "PUNCH", on: session.song.punchEnabled, color: Theme.punch, width: 46,
                          help: "Auto punch (P). Select a range and press ⇧P to set it.") { session.edit { $0.punchEnabled.toggle() } }
                LitButton(label: "CLICK", on: session.song.clickEnabled, color: Theme.accent, width: 42,
                          help: "Metronome (C)") { session.song.clickEnabled.toggle() }
                Menu {
                    Picker("Count-in", selection: $session.song.countInBars) {
                        Text("No count-in").tag(0)
                        Text("1 bar").tag(1)
                        Text("2 bars").tag(2)
                    }
                    Toggle("Click only while recording", isOn: $session.song.clickOnlyWhileRecording)
                    Divider()
                    Text("Click volume")
                    Slider(value: $session.song.clickVolume, in: 0...1)
                } label: {
                    Text(session.song.countInBars == 0 ? "No count" : "Count \(session.song.countInBars)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

            TempoControl(session: session)
            TunerButton(session: session)

            Spacer(minLength: 0)

            Picker("After take", selection: $session.song.autoArm) {
                ForEach(AutoArmMode.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 210)
            .help("What happens after each recording pass")

            HStack(spacing: 2) {
                Button { session.pixelsPerSecond = max(4, session.pixelsPerSecond / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { session.pixelsPerSecond = min(800, session.pixelsPerSecond * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.dim)

            LitButton(label: "MIX", on: session.showMixer, width: 34, help: "Mixer (X)") {
                withAnimation(.easeOut(duration: 0.15)) { session.showMixer.toggle() }
            }
            Button {
                NotificationCenter.default.post(name: .showExport, object: nil)
            } label: {
                Label("Mixdown", systemImage: "square.and.arrow.up")
            }
            .help("Export mixdown (⌘E)")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Theme.panel)
    }
}

struct TransportButton: View {
    let icon: String
    var active = false
    var activeColor: Color = Theme.accent
    var tint: Color = Theme.text
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.black : tint)
                .frame(width: 36, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? activeColor : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PositionDisplay: View {
    let session: Session
    let playhead: PlayheadModel

    var body: some View {
        let t = playhead.position
        VStack(alignment: .trailing, spacing: 0) {
            Text(t < 0 ? "count-in" : session.song.barsBeats(t))
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(session.isRecording ? Theme.record : Theme.text)
            Text(PositionDisplay.clock(max(0, t)))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .frame(width: 110, alignment: .trailing)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
    }

    static func clock(_ t: Double) -> String {
        String(format: "%d:%02d.%03d", Int(t) / 60, Int(t) % 60, Int((t - floor(t)) * 1000))
    }
}

struct TempoControl: View {
    @Bindable var session: Session
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 0) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 54)
                    .focused($focused)
                    .onSubmit(commit)
                Text("BPM").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
            }
            Stepper("", value: Binding(get: { session.song.tempo },
                                       set: { v in session.edit { $0.tempo = min(300, max(30, v.rounded())) } }),
                     in: 30...300).labelsHidden()
            Button("TAP") { session.tapTempo() }
                .font(.system(size: 10, weight: .bold)).buttonStyle(.bordered).controlSize(.small)
            Picker("", selection: Binding(get: { session.song.beatsPerBar },
                                          set: { v in session.edit { $0.beatsPerBar = v } })) {
                ForEach(2...7, id: \.self) { Text("\($0)/4").tag($0) }
            }
            .labelsHidden().frame(width: 58)
        }
        .onAppear { text = format(session.song.tempo) }
        .onChange(of: session.song.tempo) { _, v in if !focused { text = format(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func commit() {
        if let v = Double(text), v >= 30, v <= 300 { session.edit { $0.tempo = v } }
        text = format(session.song.tempo)
        focused = false
    }
}

struct ExportSheet: View {
    @Bindable var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .wav24
    @State private var rangeChoice = 0
    @State private var stems = false
    @State private var result: URL?

    private var range: TimeRange {
        switch rangeChoice {
        case 1: return session.song.loop
        case 2: return session.selection ?? session.songRange
        default: return session.songRange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mixdown").font(.title2.bold())
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Range", selection: $rangeChoice) {
                    Text("Whole song").tag(0)
                    Text("Loop range").tag(1)
                    Text("Selection").tag(2).disabled(session.selection == nil)
                }
                LabeledContent("Length", value: PositionDisplay.clock(range.length))
                Toggle("Also export stems (each track on its own, with its effects)", isOn: $stems)
            }
            .formStyle(.grouped)
            .disabled(session.exportProgress != nil)

            if let p = session.exportProgress {
                ProgressView(value: p) { Text("Rendering…") }
            } else if let result {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                }
            }
            Text("Files are saved in the song's Mixdowns folder. The master limiter (on the mixer) keeps peaks below 0 dBFS.")
                .font(.caption).foregroundStyle(Theme.dim)

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    result = nil
                    session.export(format: format, range: range, stems: stems) { url in result = url }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.exportProgress != nil || !range.isValid)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct TunerButton: View {
    let session: Session
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "tuningfork").font(.system(size: 14))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(open ? Theme.accent.opacity(0.4) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Tuner (input of the selected or armed track)")
        .popover(isPresented: $open, arrowEdge: .bottom) { TunerView(session: session) }
    }
}
