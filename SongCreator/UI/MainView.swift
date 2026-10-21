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
                    .frame(height: 490)
                    .transition(.move(edge: .bottom))
            }
            StatusBar(session: session)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { installKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in showExport = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.releaseTypingNotes()   // no stuck notes when switching apps mid-chord
        }
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Releases always reach musical typing, even if focus moved while a key was held.
            if event.type == .keyUp {
                return session.typingKeyUp(keyCode: event.keyCode) ? nil : event
            }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return event }
            if NSApp.keyWindow?.attachedSheet != nil || showExport { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if session.musicalTyping, flags.isEmpty,
               let ch = event.charactersIgnoringModifiers?.lowercased().first,
               session.typingKeyDown(ch, keyCode: event.keyCode, isRepeat: event.isARepeat) {
                return nil
            }
            if flags == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k": TypingToggle.toggle(session); return nil
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
            case "j": s.jamMode.toggle()
            case "l": shift ? s.loopSelection() : s.toggleLoop()
            case "p": shift ? s.punchSelection() : s.edit { $0.punchEnabled.toggle() }
            case "c": s.song.clickEnabled.toggle()
            case "m":
                if shift { s.addMarker() } else if let id = selected { s.updateTrack(id, undoable: false) { $0.mute.toggle() } }
            case "s": if let id = selected { s.updateTrack(id, undoable: false) { $0.solo.toggle() } }
            case "a": if let id = selected { s.toggleArm(id) }
            case "t": s.addTrack(kind: shift ? .midi : .audio)
            case "x": withAnimation(.easeOut(duration: 0.15)) { s.showMixer.toggle() }
            case "z": s.zoomToFit()
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

    static func keysHint(_ s: Session) -> String {
        let targets = s.midiTargets.map(\.name)
        let to = targets.isEmpty ? "no MIDI track" : targets.joined(separator: ", ")
        return "KEYS → \(to) · \(Session.noteName(12 * (s.typingOctave + 1))) · velocity \(s.typingVelocity) · A–' play · Z/X octave · C/V velocity · ⌘K off"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let msg = session.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).lineLimit(1).truncationMode(.middle)
                if session.micDenied {
                    Button("Open Microphone Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .buttonStyle(.link)
                }
                Button("Dismiss") { session.message = nil }.buttonStyle(.link)
            } else {
                Text(session.isRecording ? "Recording… press R or Space to stop"
                     : session.musicalTyping ? StatusBar.keysHint(session)
                     : session.jamReady ? "JAM is on: press R to record one long take over the repeating loop. It's pasted out to match when you stop."
                     : "Space play · R record · ⇧M marker · L loop · T new track · X mixer · drag across a take lane to comp")
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if session.monitoringMuted && session.song.tracks.contains(where: { $0.monitor && $0.kind == .audio }) {
                Label("Monitoring muted: speakers", systemImage: "speaker.slash.fill")
                    .foregroundStyle(Color.orange)
                    .help("Feedback protection: your input isn't played back while sound comes out of the computer's speakers. Plug in headphones to hear yourself, or turn protection off in Settings.")
            }
            Button {
                session.inputEnabled.toggle()
            } label: {
                Label(session.inputEnabled ? "Input on" : "Input off",
                      systemImage: session.inputEnabled ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(session.inputEnabled ? Theme.text : Color.orange)
            }
            .buttonStyle(.plain)
            .help(session.inputEnabled
                  ? "Audio input is on (\(session.inputChannelCount) channels). Click to switch it off: no mic, no monitoring, no feedback. Playback, KEYS and MIDI keep working."
                  : "Audio input is off. Click to switch it on to record audio.")
            Text("\(Int(session.sampleRate / 1000)) kHz · \(session.midiSources.count) MIDI")
                .foregroundStyle(Theme.dim)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.panel)
    }
}

/// Left to right in the order you work: song · transport · how you record · timing · then keys, view and output.
struct TransportBar: View {
    @Bindable var session: Session
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            // Song
            HStack(spacing: 8) {
                Button { model.closeSong() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Back to songs (⌘O)")
                RenameField(text: session.song.name, font: .system(size: 13, weight: .bold)) { name in
                    session.edit { $0.name = name }
                }
                .frame(minWidth: 70, maxWidth: 170)
                HStack(spacing: 6) {
                    Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!session.canUndo).help("Undo (⌘Z)")
                    Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!session.canRedo).help("Redo (⇧⌘Z)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
            }
            .layoutPriority(-1)

            BarDivider()

            // Transport
            HStack(spacing: 5) {
                TransportButton(icon: "backward.end.fill", help: "Go to start (Return)") { session.goToStart() }
                TransportButton(icon: session.isPlaying ? "stop.fill" : "play.fill",
                                active: session.isPlaying && !session.isRecording, help: "Play / Stop (Space)") { session.togglePlay() }
                TransportButton(icon: "record.circle.fill", active: session.isRecording, activeColor: Theme.record,
                                tint: Theme.record, help: "Record (R)") { session.toggleRecord() }
                PositionDisplay(session: session, playhead: session.playhead)
            }

            BarDivider()

            // How you record
            HStack(spacing: 4) {
                LitButton(label: "LOOP", on: session.song.loopEnabled, color: Theme.loop, width: 40,
                          help: "Cycle (L). Drag in the ruler to set the range.") { session.toggleLoop() }
                LitButton(label: "JAM", on: session.jamMode, color: .green, width: 36,
                          help: "Jam over the loop (J). With LOOP on, recording plays straight through while the loop repeats on the other tracks. Your take is one long recording, and when you stop, the loop is pasted out to match.") {
                    session.jamMode.toggle()
                }
                LitButton(label: "PUNCH", on: session.song.punchEnabled, color: Theme.punch, width: 46,
                          help: "Auto punch (P). Select a range and press ⇧P to set it.") { session.edit { $0.punchEnabled.toggle() } }
                LitButton(label: "CLICK", on: session.song.clickEnabled, color: Theme.accent, width: 42,
                          help: "Metronome (C)") { session.song.clickEnabled.toggle() }
                RecordOptionsMenu(session: session)
            }

            BarDivider()

            // Timing
            HStack(spacing: 6) {
                TempoControl(session: session)
                TunerButton(session: session)
            }

            Spacer(minLength: 4)

            // Play, view, output
            TypingToggle(session: session)
            BarDivider()
            HStack(spacing: 8) {
                Button { session.pixelsPerSecond = max(4, session.pixelsPerSecond / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (-)")
                Button { session.pixelsPerSecond = min(800, session.pixelsPerSecond * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (=)")
                Button { session.zoomToFit() } label: { Image(systemName: "arrow.left.and.right.square") }
                    .help("Zoom to fit the whole song (Z)")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.dim)
            BarDivider()
            LitButton(label: "MIX", on: session.showMixer, width: 34, help: "Mixer (X)") {
                withAnimation(.easeOut(duration: 0.15)) { session.showMixer.toggle() }
            }
            Button {
                NotificationCenter.default.post(name: .showExport, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Mixdown")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Export a mixdown (⌘E)")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Theme.panel)
    }
}

struct BarDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 26) }
}

/// Count-in, what happens after a take, and click settings: set once, rarely touched.
struct RecordOptionsMenu: View {
    @Bindable var session: Session

    var body: some View {
        Menu {
            Picker("Count-in", selection: $session.song.countInBars) {
                Text("No count-in").tag(0)
                Text("1 bar").tag(1)
                Text("2 bars").tag(2)
            }
            Picker("After a take", selection: $session.song.autoArm) {
                ForEach(AutoArmMode.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Toggle("Click only while recording", isOn: $session.song.clickOnlyWhileRecording)
            Menu("Click volume") {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { v in
                    Button("\(Int(v * 100))%\(abs(session.song.clickVolume - v) < 0.01 ? " ✓" : "")") { session.song.clickVolume = v }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                Text(session.song.countInBars == 0 ? "–" : "\(session.song.countInBars)")
                if session.song.autoArm != .off { Image(systemName: "arrow.turn.down.right") }
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.text)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Recording options: count-in (\(session.song.countInBars == 0 ? "off" : "\(session.song.countInBars) bar")), after a take (\(session.song.autoArm.label.lowercased())), click")
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
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 46)
                    .focused($focused)
                    .onSubmit(commit)
                Text("BPM").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim).fixedSize()
            }
            VStack(spacing: 1) {
                Button { nudge(1) } label: { Image(systemName: "chevron.up") }
                Button { nudge(-1) } label: { Image(systemName: "chevron.down") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.dim)
            .help("Tempo ±1 (⌥ for ±0.1)")
            Button { session.tapTempo() } label: {
                Text("TAP").font(.system(size: 10, weight: .bold))
                    .frame(width: 32, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Tap 3 or more times to set the tempo")
            Menu {
                ForEach(2...7, id: \.self) { n in
                    Button("\(n)/4") { session.edit { $0.beatsPerBar = n } }
                }
            } label: {
                Text("\(session.song.beatsPerBar)/4").font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Time signature")
        }
        .onAppear { text = format(session.song.tempo) }
        .onChange(of: session.song.tempo) { _, v in if !focused { text = format(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func nudge(_ dir: Double) {
        let step = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
        session.edit { $0.tempo = min(300, max(30, (($0.tempo + dir * step) * 10).rounded() / 10)) }
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

/// Computer keyboard as a MIDI keyboard, with octave and velocity readout while it's on.
struct TypingToggle: View {
    @Bindable var session: Session

    /// Turning KEYS on also takes keyboard focus away from text fields, so letters reach the notes.
    static func toggle(_ session: Session) {
        session.musicalTyping.toggle()
        if session.musicalTyping { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    var body: some View {
        HStack(spacing: 4) {
            LitButton(label: "KEYS", on: session.musicalTyping, color: .purple, width: 40,
                      help: "Play MIDI from your computer keyboard (⌘K). A–' play notes (W, E, T, Y, U, O, P are black keys), Z/X change octave, C/V change velocity. Notes go to armed MIDI tracks, or the selected (or first) MIDI track if none are armed.") {
                TypingToggle.toggle(session)
            }
            if session.musicalTyping {
                Button { session.typingOctave = max(0, session.typingOctave - 1) } label: { Image(systemName: "chevron.left") }
                    .help("Octave down (Z)")
                Text(Session.noteName(12 * (session.typingOctave + 1)))
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).frame(width: 26)
                Button { session.typingOctave = min(8, session.typingOctave + 1) } label: { Image(systemName: "chevron.right") }
                    .help("Octave up (X)")

            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .bold))
    }
}
