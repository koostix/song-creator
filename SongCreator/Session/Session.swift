import AVFoundation
import CoreAudio
import Observation
import SwiftUI

/// Kept separate so only the views that draw the playhead redraw at 30 fps.
@Observable
final class PlayheadModel {
    var position: Double = 0
}

enum Prefs {
    static let defaults = UserDefaults.standard
    static var latencyOffsetMs: Double {
        get { defaults.object(forKey: "latencyOffsetMs") as? Double ?? 0 }
        set { defaults.set(newValue, forKey: "latencyOffsetMs") }
    }
    static var returnOnStop: Bool {
        get { defaults.object(forKey: "returnOnStop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "returnOnStop") }
    }
    static var inputUID: String? {
        get { defaults.string(forKey: "inputUID") }
        set { defaults.set(newValue, forKey: "inputUID") }
    }
    static var bufferFrames: Int {
        get { defaults.object(forKey: "bufferFrames") as? Int ?? 256 }
        set { defaults.set(newValue, forKey: "bufferFrames") }
    }
    /// The project selected in the song list; New Song goes there.
    static var libraryProject: String? {
        get { defaults.string(forKey: "libraryProject") }
        set { defaults.set(newValue, forKey: "libraryProject") }
    }
    static var inputEnabled: Bool {
        get { defaults.object(forKey: "inputEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "inputEnabled") }
    }
    static var feedbackProtection: Bool {
        get { defaults.object(forKey: "feedbackProtection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "feedbackProtection") }
    }
    /// Run Audio Units in a separate process so a crashing plugin can't take the app down.
    static var pluginsOutOfProcess: Bool {
        get { defaults.object(forKey: "pluginsOutOfProcess") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pluginsOutOfProcess") }
    }
    /// Each song's last timeline zoom and scroll, by song ID.
    static func timelineView(_ song: UUID) -> (pps: Double, scroll: Double)? {
        guard let v = (defaults.dictionary(forKey: "timelineView") as? [String: [Double]])?[song.uuidString], v.count == 2 else { return nil }
        return (v[0], v[1])
    }
    static func setTimelineView(_ song: UUID, pps: Double, scroll: Double) {
        var all = defaults.dictionary(forKey: "timelineView") as? [String: [Double]] ?? [:]
        all[song.uuidString] = [pps, scroll]
        defaults.set(all, forKey: "timelineView")
    }
    static var jamMode: Bool {
        get { defaults.bool(forKey: "jamMode") }
        set { defaults.set(newValue, forKey: "jamMode") }
    }
    static var tunerA4: Double {
        get { defaults.object(forKey: "tunerA4") as? Double ?? 440 }
        set { defaults.set(newValue, forKey: "tunerA4") }
    }
    static var outputUID: String? {
        get { defaults.string(forKey: "outputUID") }
        set { defaults.set(newValue, forKey: "outputUID") }
    }
}

@Observable
final class Session {
    var song: Song {
        didSet { songDidChange(from: oldValue) }
    }
    let projectURL: URL
    let audioFolder: URL

    // Transport
    private(set) var isPlaying = false
    private(set) var isRecording = false
    let playhead = PlayheadModel()
    /// Where the last play started; Stop returns here when `returnOnStop` is on.
    private(set) var playStart: Double = 0

    // Editing / view state
    var selection: TimeRange?
    /// The focused track: shortcuts and the tuner use it, new tracks go after it.
    var selectedTrackID: UUID? {
        didSet {
            // Focusing a track outside the selection makes it the only selected one.
            if let id = selectedTrackID { if !selectedTrackIDs.contains(id) { selectedTrackIDs = [id] } }
            else { selectedTrackIDs = [] }
            updateSelectedMIDI()
        }
    }
    /// Every selected track (⇧-click adds more). Always includes the focused one.
    private(set) var selectedTrackIDs: Set<UUID> = []
    /// Width of the track header column, remembered for every song.
    var headerWidth: CGFloat = Session.savedHeaderWidth {
        didSet { UserDefaults.standard.set(Double(headerWidth), forKey: "trackHeaderWidth") }
    }
    static let headerWidthRange: ClosedRange<CGFloat> = 220...420
    private static var savedHeaderWidth: CGFloat {
        let w = UserDefaults.standard.double(forKey: "trackHeaderWidth")
        return w == 0 ? Layout.headerWidth : min(max(w, headerWidthRange.lowerBound), headerWidthRange.upperBound)
    }
    var selectedRegions: Set<UUID> = []
    /// The track whose name is being edited; Tab moves this to the next track.
    var renamingTrackID: UUID?

    func startRenaming(_ id: UUID) {
        renamingTrackID = id
        selectedTrackID = id
    }

    /// Tab / ⇧Tab while renaming: the current name is saved (by its field) and the next track opens for
    /// renaming. Past either end, renaming finishes.
    func renameNext(forward: Bool) {
        guard let id = renamingTrackID, let i = song.trackIndex(id) else { renamingTrackID = nil; return }
        let j = i + (forward ? 1 : -1)
        if song.tracks.indices.contains(j) {
            startRenaming(song.tracks[j].id)
        } else {
            renamingTrackID = nil
        }
    }
    @ObservationIgnored var clipboard: RegionClipboard?
    @ObservationIgnored private var gestureBase: Song?
    var showMixer = false
    /// The mixer fills the window, hiding the tracks (⇧X), so long effect chains have room.
    var mixerFull = false
    /// Height of the mixer under the tracks, remembered for every song. Taller shows more effect slots.
    var mixerHeight: CGFloat = Session.savedMixerHeight {
        didSet { UserDefaults.standard.set(Double(mixerHeight), forKey: "mixerHeight") }
    }
    static let defaultMixerHeight: CGFloat = 508
    static let minMixerHeight: CGFloat = 260
    private static var savedMixerHeight: CGFloat {
        let h = CGFloat(UserDefaults.standard.double(forKey: "mixerHeight"))
        return h == 0 ? defaultMixerHeight : max(h, minMixerHeight)
    }
    /// Scrolling by hand during playback pauses following until the next play.
    var followSuspended = false
    var pixelsPerSecond: Double = 40
    var scrollX: Double = 0
    var timelineWidth: Double = 800 {
        didSet {
            // A song opened without a saved view zooms to fit once the timeline's real width is known.
            if needsFit, timelineWidth > 300 {
                needsFit = false
                zoomToFit()
            }
        }
    }
    @ObservationIgnored private var needsFit = false
    var followPlayhead = true
    var returnOnStop = Prefs.returnOnStop { didSet { Prefs.returnOnStop = returnOnStop } }
    var latencyOffsetMs = Prefs.latencyOffsetMs { didSet { Prefs.latencyOffsetMs = latencyOffsetMs } }
    var message: String?
    var exportProgress: Double?

    // Devices
    private(set) var inputChannelCount = 0
    private(set) var sampleRate: Double = 48000
    private(set) var midiSources: [String] = []
    /// MIDI outputs for external instruments (refreshed when MIDI devices come and go).
    private(set) var midiDestinations: [MIDIDestination] = MIDIOutput.destinations()

    /// Whether a track's external MIDI device is plugged in right now.
    func isConnected(_ ext: ExternalMIDI) -> Bool { midiDestinations.contains { $0.id == ext.deviceID } }

    /// Make a MIDI track play outboard gear (nil goes back to its instrument).
    func setExternal(_ ext: ExternalMIDI?, on track: UUID) {
        if let old = song.tracks.first(where: { $0.id == track })?.external {
            MIDIOutput.shared.silence(device: old.deviceID, channel: old.channel)
        }
        updateTrack(track) { t in
            t.external = ext
            if ext != nil { t.instrument = nil }
        }
    }
    private(set) var micDenied = false
    /// Master switch for the audio input. Off means the mic is never opened.
    var inputEnabled = Prefs.inputEnabled {
        didSet { Prefs.inputEnabled = inputEnabled; rebuildEngine() }
    }
    /// Mute input monitoring while the sound comes out of the computer's speakers.
    var feedbackProtection = Prefs.feedbackProtection {
        didSet { Prefs.feedbackProtection = feedbackProtection; updateMonitorSafety() }
    }
    /// Output currently goes to the built-in speakers (not headphones or an interface).
    private(set) var onSpeakers = false
    /// Monitoring is being held off by feedback protection.
    var monitoringMuted: Bool { feedbackProtection && onSpeakers }
    @ObservationIgnored private var speakerListener: (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    @ObservationIgnored private var deviceMessage: String?
    @ObservationIgnored private var bluetoothHintShown = false
    @ObservationIgnored private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var deviceListObserver: NSObjectProtocol?
    var inputUID: String? = Prefs.inputUID
    var outputUID: String? = Prefs.outputUID

    let waveforms = WaveformStore()
    /// Bumped when plugins finish loading or fail, so plugin UI refreshes.
    private(set) var pluginRevision = 0
    var bufferFrames = Prefs.bufferFrames
    @ObservationIgnored private var lastPluginCapture = Date.distantPast
    @ObservationIgnored private var pluginStates: [UUID: Data] = [:]

    @ObservationIgnored let audio = AudioEngine()
    @ObservationIgnored let recorder = Recorder()
    @ObservationIgnored let midi = MIDIInput.shared
    @ObservationIgnored private(set) var transport: Transport!
    // Observed so the Undo/Redo menu items and buttons enable themselves.
    private var undoStack: [Song] = []
    private var redoStack: [Song] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var uiTimer: Timer?
    @ObservationIgnored private var tapTimes: [Date] = []
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var lastRebuild = Date.distantPast

    // Recording state
    @ObservationIgnored private var recStartSong: Double = 0
    @ObservationIgnored private var recStartPlayer: Double = 0
    @ObservationIgnored private var recMIDITracks: [UUID] = []
    @ObservationIgnored private let midiLock = NSLock()
    @ObservationIgnored private var midiEvents: [(UInt8, UInt8, UInt8, UInt64)] = []
    @ObservationIgnored private var midiRecording = false
    @ObservationIgnored private var armedMIDI: [UUID] = []
    /// Where notes go when no MIDI track is armed: the selected MIDI track, else the first one.
    /// Read from the MIDI thread under midiLock.
    @ObservationIgnored private var fallbackMIDI: UUID?
    /// MIDI tracks playing outboard gear (read from the MIDI thread under midiLock).
    @ObservationIgnored private var externalMIDI: [UUID: ExternalMIDI] = [:]

    private func updateSelectedMIDI() {
        let midiTracks = song.tracks.filter { $0.kind == .midi }
        let id = (midiTracks.first { $0.id == selectedTrackID } ?? midiTracks.first)?.id
        let externals = Dictionary(uniqueKeysWithValues: midiTracks.compactMap { t in t.external.map { (t.id, $0) } })
        midiLock.lock(); fallbackMIDI = id; externalMIDI = externals; midiLock.unlock()
    }

    /// Tracks that live MIDI (hardware or KEYS) plays right now.
    var midiTargets: [Track] {
        let armed = song.tracks.filter { $0.kind == .midi && $0.armed }
        if !armed.isEmpty { return armed }
        let midiTracks = song.tracks.filter { $0.kind == .midi }
        return (midiTracks.first { $0.id == selectedTrackID } ?? midiTracks.first).map { [$0] } ?? []
    }

    /// JAM: recording over a loop plays it out straight (one long take) and pastes the loop out on stop.
    var jamMode = Prefs.jamMode { didSet { Prefs.jamMode = jamMode } }
    /// The loop being jammed over during a JAM recording pass.
    @ObservationIgnored private var jamLoop: TimeRange?
    @ObservationIgnored private var jamExcluded: Set<UUID> = []
    /// Ten minutes of repeats is plenty for any pass; the real tile-out happens on stop.
    private static let jamHorizon: Double = 600

    /// What the transport plays: the song, or during a JAM pass the song with the loop repeated ahead.
    private var playbackSong: Song {
        var s = song
        if let loop = jamLoop {
            s = s.tilingLoop(loop, until: loop.start + Session.jamHorizon, excluding: jamExcluded)
        }
        if let mute = recordMute { s = s.mutingRecording(tracks: mute.tracks, over: mute.range) }
        return s
    }

    /// While recording, the armed tracks' existing takes are silent over this range (the punch range, or
    /// from where recording starts), so you only hear what you're playing now.
    @ObservationIgnored private var recordMute: (tracks: Set<UUID>, range: TimeRange)?

    private func startRecordMute(from start: Double) {
        let range = song.punchEnabled ? song.punch : TimeRange(start: start, end: .greatestFiniteMagnitude)
        recordMute = (Set(song.tracks.filter(\.armed).map(\.id)), range)
    }

    /// Where a JAM pass's paste-out ends: the stop position rounded up to a whole loop pass,
    /// or down when it's less than a beat into a new pass. Always at least one pass.
    static func jamEnd(loop: TimeRange, stoppedAt t: Double, beat: Double) -> Double {
        let passes = (t - loop.start) / loop.length
        let into = (passes - floor(passes)) * loop.length
        let whole = into < beat ? floor(passes) : ceil(passes)
        return loop.start + max(1, whole) * loop.length
    }

    var hasAudioRecordings: Bool { song.tracks.contains { $0.takes.contains { $0.fileName != nil } } }

    /// True when pressing record now would start a JAM pass.
    var jamReady: Bool { jamMode && song.loopEnabled && song.loop.isValid }

    init(projectURL: URL, song: Song) {
        self.projectURL = projectURL
        self.audioFolder = ProjectStore.audioFolder(projectURL)
        self.song = song
        transport = Transport(audio: audio, audioFolder: audioFolder, song: song)
        audio.onPluginsChanged = { [weak self] in
            guard let self else { return }
            self.audio.sync(self.song)
            self.pluginRevision += 1
        }
        armedMIDI = song.tracks.filter { $0.kind == .midi && $0.armed }.map(\.id)
        updateSelectedMIDI()   // which MIDI tracks play outboard gear, before any note arrives
        if let view = Prefs.timelineView(song.id) {
            pixelsPerSecond = min(800, max(4, view.pps))
            scrollX = max(0, view.scroll)
        } else {
            needsFit = true
        }
        rebuildEngine()
        startMIDI()
        loadWaveforms()
        reportMissingAudio()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.audio.engine, self.exportProgress == nil else { return }
            // With the app's own hardware connection the engine isn't attached to hardware; its configuration
            // notices mean nothing, and rebuilding would pull the engine out from under playback or recording.
            // Device changes are watched directly instead (see watchDevices).
            if self.audio.usesOwnIO { return }
            // Our own rebuild (device or buffer-size change) makes the new engine report a change too.
            // Rebuilding again would loop, so just restart it.
            if Date().timeIntervalSince(self.lastRebuild) < 1.5 {
                try? self.audio.start()
                return
            }
            self.message = "Audio device changed — reconnected."
            self.rebuildEngine()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tickUI() }
        deviceListObserver = NotificationCenter.default.addObserver(forName: .audioDevicesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.audio.usesOwnIO else { return }
            self.deviceChanged()
        }
    }

    func close() {
        stop()
        saveTimelineView()
        uiTimer?.invalidate()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let l = speakerListener { AudioDevices.removeListener(l) }
        for l in deviceListeners { AudioDevices.removeListener(l) }
        if let deviceListObserver { NotificationCenter.default.removeObserver(deviceListObserver) }
        saveNow()
        PluginWindows.closeAll()
        midi.detach(owner: self)
        recorder.stop()
        audio.shutdown()
        audio.destroyAggregate()
    }

    // MARK: - Engine

    func rebuildEngine() {
        lastRebuild = Date()
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        // A device warning from the last build may no longer apply.
        if message != nil, message == deviceMessage { message = nil }
        deviceMessage = nil
        let inDev = AudioDevices.device(uid: inputUID)?.id, outDev = AudioDevices.device(uid: outputUID)?.id
        let resolvedIn = inDev ?? AudioDevices.defaultDevice(input: true)
        let resolvedOut = outDev ?? AudioDevices.defaultDevice(input: false)
        for dev in [resolvedIn, resolvedOut] {
            if let dev { AudioDevices.setBufferSize(dev, frames: bufferFrames) }
        }
        alignSampleRates(input: inputEnabled ? resolvedIn : nil, output: resolvedOut)
        audio.build(song: song, inputDevice: inDev, outputDevice: outDev, inputEnabled: inputEnabled, bufferFrames: bufferFrames)
        sampleRate = audio.sampleRate
        inputChannelCount = audio.inputChannelCount
        transport.engineRebuilt(audioFolder: audioFolder)
        transport.update(song: song)
        recorder.installTap(on: audio)
        do {
            try audio.start()
        } catch {
            message = "Audio couldn't start with these devices (\(error.localizedDescription)). Pick System default in Settings (⌘,) and try again."
            deviceMessage = message
        }
        micDenied = audio.micDenied
        var warning: String?
        if inputEnabled, let problem = audio.inputProblem, song.tracks.contains(where: { $0.kind == .audio }) {
            warning = problem   // with the input switched off on purpose, the status bar says so instead
        } else if audio.hasInput, audio.inputSampleRate != audio.sampleRate {
            warning = "Input runs at \(Int(audio.inputSampleRate)) Hz but output at \(Int(audio.sampleRate)) Hz. Set both to the same rate in Audio MIDI Setup."
        } else if song.sampleRate > 0, song.sampleRate != audio.sampleRate,
                  song.tracks.contains(where: { $0.takes.contains { $0.fileName != nil } }) {
            warning = "This song was recorded at \(Int(song.sampleRate)) Hz; your device is at \(Int(audio.sampleRate)) Hz. Switch the device to \(Int(song.sampleRate)) Hz to hear the audio."
        }
        if let warning {
            message = warning
            deviceMessage = warning
        }
        watchSpeakers()
        watchDevices()
        updateMonitorSafety()
        // Recording is expected on headphones. Bluetooth ones work, but add delay you'd hear while
        // monitoring, and their own mic drops to call quality, so point that out once.
        if !bluetoothHintShown, message == nil, let out = audio.outputDeviceID,
           AudioDevices.transportType(out) == kAudioDeviceTransportTypeBluetooth {
            bluetoothHintShown = true
            message = "\(AudioDevices.name(out) ?? "Bluetooth headphones") add a short delay. For recording, wired headphones and the MacBook mic work best."
        }
    }

    /// The song's rate drives the hardware, like any DAW: a song with recordings switches the output
    /// to its rate (otherwise its takes can't play), and the input follows the output so recording works.
    /// A device that can't run at that rate (e.g. a 16 kHz Bluetooth mic) is left alone; build() then
    /// explains why recording is off.
    private func alignSampleRates(input: AudioDeviceID?, output: AudioDeviceID?) {
        guard let output else { return }
        if song.sampleRate > 0, hasAudioRecordings, AudioDevices.sampleRate(output) != song.sampleRate {
            AudioDevices.setSampleRate(output, song.sampleRate)
        }
        let target = AudioDevices.sampleRate(output)
        if let input, input != output, target > 0, AudioDevices.sampleRate(input) != target {
            AudioDevices.setSampleRate(input, target)
        }
    }

    /// Re-check whether sound goes to the laptop speakers (and so whether monitoring must be muted).
    func updateMonitorSafety() {
        onSpeakers = audio.outputDeviceID.map(AudioDevices.playsIntoRoom) ?? false
        audio.monitorMuted = monitoringMuted
        audio.applyParameters(song)
    }

    /// With the app's own hardware connection: rebuild when a chosen device goes away or changes rate.
    private func watchDevices() {
        for l in deviceListeners { AudioDevices.removeListener(l) }
        deviceListeners = []
        guard audio.usesOwnIO else { return }
        let ids = [AudioDevices.device(uid: inputUID)?.id, AudioDevices.device(uid: outputUID)?.id].compactMap { $0 }
        for id in Set(ids) {
            deviceListeners.append(AudioDevices.addListener(id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                self?.deviceChanged()
            })
        }
        AudioDevices.startWatching()
    }

    private func deviceChanged() {
        guard audio.usesOwnIO, !isRecording, exportProgress == nil else { return }
        // Our own rate alignments echo here; only a device that's gone or no longer at the engine's rate matters.
        let ids = [AudioDevices.device(uid: inputUID)?.id, AudioDevices.device(uid: outputUID)?.id]
        let missing = [inputUID, outputUID].compactMap { $0 }.contains { AudioDevices.device(uid: $0) == nil }
        let rateMoved = ids.compactMap { $0 }.contains { AudioDevices.sampleRate($0) != audio.sampleRate }
        guard missing || rateMoved else { return }
        message = "Audio device changed — reconnected."
        rebuildEngine()
    }

    /// Plugging headphones into the jack can switch the built-in output's source without a device change.
    private func watchSpeakers() {
        if let old = speakerListener { AudioDevices.removeListener(old) }
        speakerListener = nil
        guard let out = audio.outputDeviceID else { return }
        speakerListener = AudioDevices.addListener(out, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
            self?.updateMonitorSafety()
        }
    }

    func setDevices(input: String?, output: String?) {
        inputUID = input
        outputUID = output
        Prefs.inputUID = input
        Prefs.outputUID = output
        rebuildEngine()
    }

    private func startMIDI() {
        midi.attach(owner: self, onEvent: { [weak self] status, d1, d2, ts in
            self?.handleMIDI(status, d1, d2, ts)
        }, sourcesChanged: { [weak self] in
            DispatchQueue.main.async {
                self?.midiSources = self?.midi.sourceNames ?? []
                self?.midiDestinations = MIDIOutput.destinations()
            }
        })
        if !midi.isConnected {
            message = "MIDI isn't available right now. Quit and reopen Song Creator to use MIDI devices."
        }
    }

    /// Incoming notes from hardware or the computer keyboard: play armed MIDI tracks (or, if none are
    /// armed, the selected MIDI track) and capture them while recording. Safe from any thread.
    func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, _ ts: UInt64) {
        let kind = status & 0xF0
        guard kind == 0x80 || kind == 0x90 || kind == 0xB0 || kind == 0xE0 else { return }
        midiLock.lock()
        let targets = armedMIDI.isEmpty ? (fallbackMIDI.map { [$0] } ?? []) : armedMIDI
        let externals = externalMIDI
        if midiRecording { midiEvents.append((status, d1, d2, ts)) }
        midiLock.unlock()
        for t in targets {
            if let ext = externals[t] {
                // Outboard gear: straight out to the device, now.
                MIDIOutput.shared.send(status, d1, d2, to: ext.deviceID, channel: ext.channel)
            } else {
                audio.sendMIDI(track: t, status: status, data1: d1, data2: d2)
            }
        }
    }

    // MARK: - Musical typing (computer keyboard as MIDI)

    /// The Logic/GarageBand layout: A row = white keys, W row = black keys, starting at C.
    static let typingKeys: [Character: UInt8] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6, "g": 7, "y": 8, "h": 9,
        "u": 10, "j": 11, "k": 12, "o": 13, "l": 14, "p": 15, ";": 16, "'": 17,
    ]

    var musicalTyping = false {
        didSet {
            if !musicalTyping { releaseTypingNotes(); return }
            // Typed notes need an instrument to play: add a piano track if the song has none.
            if !oldValue, !song.tracks.contains(where: { $0.kind == .midi }) {
                addTrack(kind: .midi)
                message = "Added a MIDI track for KEYS. Pick its sound in the track header."
            }
        }
    }
    /// Octave of the A key; 4 means A plays middle C (MIDI 60).
    var typingOctave = 4
    var typingVelocity = 100
    @ObservationIgnored private var typingHeld: [UInt16: UInt8] = [:]

    /// Handle a key press while musical typing is on. Returns true if the key was used.
    func typingKeyDown(_ ch: Character, keyCode: UInt16, isRepeat: Bool) -> Bool {
        switch ch {
        case "z": if !isRepeat { typingOctave = max(0, typingOctave - 1) }; return true
        case "x": if !isRepeat { typingOctave = min(8, typingOctave + 1) }; return true
        case "c": typingVelocity = max(1, typingVelocity - 10); return true
        case "v": typingVelocity = min(127, typingVelocity + 10); return true
        default: break
        }
        guard let offset = Session.typingKeys[ch] else { return false }
        if isRepeat || typingHeld[keyCode] != nil { return true }
        let note = Int(offset) + 12 * (typingOctave + 1)
        guard note <= 127 else { return true }
        typingHeld[keyCode] = UInt8(note)
        handleMIDI(0x90, UInt8(note), UInt8(typingVelocity), HostTime.now)
        return true
    }

    func typingKeyUp(keyCode: UInt16) -> Bool {
        guard let note = typingHeld.removeValue(forKey: keyCode) else { return false }
        handleMIDI(0x80, note, 0, HostTime.now)
        return true
    }

    func releaseTypingNotes() {
        for note in typingHeld.values { handleMIDI(0x80, note, 0, HostTime.now) }
        typingHeld = [:]
    }

    static func noteName(_ midi: Int) -> String {
        TunerView.names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }

    // MARK: - Zoom

    /// Fit the whole song (at least 8 bars, and the loop if it's on) in the window.
    /// Remember the zoom and scroll for this song (on close and with every autosave).
    func saveTimelineView() {
        Prefs.setTimelineView(song.id, pps: pixelsPerSecond, scroll: scrollX)
    }

    func zoomToFit() {
        var end = max(song.contentEnd, song.secondsPerBar * 8)
        if song.loopEnabled { end = max(end, song.loop.end) }
        pixelsPerSecond = min(800, max(4, timelineWidth / (end * 1.04)))
        scrollX = 0
    }

    /// Recordings whose audio file is gone (moved or deleted in Finder) play as silence; say so.
    private func reportMissingAudio() {
        let files = Set(song.tracks.flatMap { $0.takes.compactMap(\.fileName) })
        let missing = files.filter { !FileManager.default.fileExists(atPath: audioFolder.appendingPathComponent($0).path) }
        guard !missing.isEmpty else { return }
        message = "\(missing.count) recording\(missing.count == 1 ? " is" : "s are") missing from this song's Audio folder, so "
            + "\(missing.count == 1 ? "it plays" : "they play") as silence. Put the file\(missing.count == 1 ? "" : "s") back to hear \(missing.count == 1 ? "it" : "them")."
    }

    private func loadWaveforms() {
        for t in song.tracks { for take in t.takes { if let f = take.fileName { waveforms.load(f, folder: audioFolder) } } }
    }

    // MARK: - Song changes, undo, save

    private func songDidChange(from old: Song) {
        // Rewiring tracks waits for the transport's current chunk, so it can't schedule onto a removed player.
        func wiring(_ s: Song) -> [String] {
            s.tracks.map { "\($0.id)\($0.kind)\($0.channels)\($0.inputChannel)\($0.instrument?.id.uuidString ?? "")\($0.external?.audioReturn == true)" }
        }
        if wiring(old) != wiring(song) {
            let current = song
            transport.queue.sync { audio.sync(current) }
        } else {
            audio.sync(song)
        }
        transport.update(song: playbackSong)
        midiLock.lock()
        armedMIDI = song.tracks.filter { $0.kind == .midi && $0.armed }.map(\.id)
        midiLock.unlock()
        updateSelectedMIDI()
        scheduleSave()
    }

    /// Make an undoable change. Restarts playback so arrangement edits are heard at once.
    func edit(_ change: (inout Song) -> Void) {
        let before = song
        var s = song
        change(&s)
        s.pruneAutomation()
        guard s != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        song = s
        if arrangementDiffers(before, s) { restartIfPlaying() }
    }

    var canUndo: Bool { !undoStack.isEmpty && !isRecording }
    var canRedo: Bool { !redoStack.isEmpty && !isRecording }

    func undo() {
        guard canUndo, let prev = undoStack.popLast() else { return }
        redoStack.append(song)
        song = prev
        restartIfPlaying()
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(song)
        song = next
        restartIfPlaying()
    }

    private func arrangementDiffers(_ a: Song, _ b: Song) -> Bool {
        a.tracks.map(\.comp) != b.tracks.map(\.comp) || a.tracks.map(\.takes) != b.tracks.map(\.takes)
            || a.loop != b.loop || a.loopEnabled != b.loopEnabled || a.tempo != b.tempo
            || a.hasAutomation != b.hasAutomation
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveNow(capturePlugins: Date().timeIntervalSince(self.lastPluginCapture) > 20)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Save the song. Plugin state is read from the live plugins (slow for big ones, so autosave does it sparingly).
    func saveNow(capturePlugins: Bool = true) {
        saveTimelineView()
        saveWork?.cancel()
        if capturePlugins {
            let slots = song.tracks.flatMap { $0.inserts + ($0.instrument.map { [$0] } ?? []) } + song.master.inserts
                + song.buses.flatMap(\.inserts)
            for slot in slots {
                if let data = audio.pluginState(slot.id) { pluginStates[slot.id] = data }
            }
            lastPluginCapture = Date()
        }
        do { try ProjectStore.save(withPluginStates(song), to: projectURL) } catch { message = "Save failed: \(error.localizedDescription)" }
    }

    /// `s` with each plugin's last captured settings, for saving.
    private func withPluginStates(_ s: Song) -> Song {
        var copy = s
        func apply(_ slots: inout [PluginSlot]) {
            for j in slots.indices { if let d = pluginStates[slots[j].id] { slots[j].state = d } }
        }
        for i in copy.tracks.indices {
            apply(&copy.tracks[i].inserts)
            if let id = copy.tracks[i].instrument?.id, let d = pluginStates[id] { copy.tracks[i].instrument?.state = d }
        }
        apply(&copy.master.inserts)
        for i in copy.buses.indices { apply(&copy.buses[i].inserts) }
        return copy
    }

    // MARK: - New-song default

    /// Save this song's setup (with plugins' current settings) as the start for new songs.
    func saveAsNewSongDefault() {
        saveNow()   // captures plugin states
        let copy = withPluginStates(song)
        do {
            try ProjectStore.saveTemplate(copy)
            message = "Saved as the default for new songs: \(copy.tracks.count) track\(copy.tracks.count == 1 ? "" : "s"), with their instruments, plugins and settings."
        } catch {
            message = "Couldn't save the default: \(error.localizedDescription)"
        }
    }

    // MARK: - Plugins

    // Effect chains belong to a track, a bus, or the master when the ID is Song.masterID.

    func inserts(of owner: UUID) -> [PluginSlot] {
        if owner == Song.masterID { return song.master.inserts }
        if let i = song.busIndex(owner) { return song.buses[i].inserts }
        return song.tracks.first { $0.id == owner }?.inserts ?? []
    }

    func chainName(_ owner: UUID) -> String {
        if owner == Song.masterID { return "Master" }
        if let i = song.busIndex(owner) { return song.buses[i].name }
        return song.tracks.first { $0.id == owner }?.name ?? ""
    }

    private func updateInserts(_ owner: UUID, undoable: Bool = true, _ change: (inout [PluginSlot]) -> Void) {
        if owner == Song.masterID {
            if undoable { edit { change(&$0.master.inserts) } } else { change(&song.master.inserts) }
        } else if song.busIndex(owner) != nil {
            updateBus(owner, undoable: undoable) { change(&$0.inserts) }
        } else {
            updateTrack(owner, undoable: undoable) { change(&$0.inserts) }
        }
    }

    /// Keep Apple's delay at a note length of the tempo (nil: its own delay time).
    func setTempoSync(_ slot: UUID, in owner: UUID, _ division: DelayDivision?) {
        updateInserts(owner) { list in
            if let i = list.firstIndex(where: { $0.id == slot }) { list[i].tempoSync = division }
        }
    }

    // MARK: - Effect buses

    func updateBus(_ id: UUID, undoable: Bool = true, _ change: (inout Bus) -> Void) {
        if undoable {
            edit { s in if let i = s.busIndex(id) { change(&s.buses[i]) } }
        } else if let i = song.busIndex(id) {
            change(&song.buses[i])
        }
    }

    /// A new, empty bus at the end of the mixer, with no sends yet.
    func addBus() {
        edit { s in
            let used = Set(s.buses.map(\.name))
            let name = (1...).lazy.map { "Bus \($0)" }.first { !used.contains($0) }!
            s.buses.append(Bus(name: name))
        }
        // Every third bus adds a row of send knobs to each strip: make room for it.
        let needed = MixerView.stripHeight(buses: song.buses.count) - MixerView.stripHeight(buses: song.buses.count - 1)
        if needed > 0 { mixerHeight += needed }
    }

    /// Remove a bus, its plugins and every track's send to it.
    func removeBus(_ id: UUID) {
        for slot in song.buses.first(where: { $0.id == id })?.inserts ?? [] { PluginWindows.close(slot.id) }
        edit { s in
            s.buses.removeAll { $0.id == id }
            for i in s.tracks.indices { s.tracks[i].strip.sends[id] = nil }
        }
    }

    func renameBus(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateBus(id) { $0.name = trimmed }
    }

    /// Live (non-undoable) binding to a track's send level for one bus.
    func sendBinding(track: UUID, bus: UUID) -> Binding<Double> {
        Binding(
            get: { self.song.tracks.first { $0.id == track }?.strip.sends[bus] ?? 0 },
            set: { v in self.updateTrack(track, undoable: false) { $0.strip.sends[bus] = v > 0 ? v : nil } })
    }

    /// Live binding to a bus's return level.
    func busReturnBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { self.song.buses.first { $0.id == id }?.returnDB ?? 0 },
            set: { v in self.updateBus(id, undoable: false) { $0.returnDB = v } })
    }

    func addInsert(_ info: PluginInfo, to owner: UUID) {
        updateInserts(owner) { $0.append(info.makeSlot()) }
    }

    func removeInsert(_ slot: UUID, from owner: UUID) {
        PluginWindows.close(slot)
        updateInserts(owner) { $0.removeAll { $0.id == slot } }
    }

    func moveInsert(_ slot: UUID, in owner: UUID, by delta: Int) {
        updateInserts(owner) { list in
            guard let i = list.firstIndex(where: { $0.id == slot }) else { return }
            let j = max(0, min(list.count - 1, i + delta))
            list.insert(list.remove(at: i), at: j)
        }
    }

    /// Reorder the effect chain (from a drag in the FX panel); the audio is rewired to match.
    func moveInserts(in owner: UUID, from: IndexSet, to: Int) {
        updateInserts(owner) { $0.move(fromOffsets: from, toOffset: to) }
    }

    func toggleBypass(_ slot: UUID, in owner: UUID) {
        updateInserts(owner, undoable: false) { list in
            if let i = list.firstIndex(where: { $0.id == slot }) { list[i].bypass.toggle() }
        }
    }

    /// nil switches back to the built-in General MIDI sounds.
    func setInstrument(_ info: PluginInfo?, on track: UUID) {
        updateTrack(track) { t in
            t.instrument = info?.makeSlot()
            if info != nil { t.external = nil }
        }
    }

    func openEditor(_ slot: PluginSlot, track: Track) { openEditor(slot, owner: track.id) }

    /// Open a plugin's own window. `owner` is its track or bus, or Song.masterID.
    func openEditor(_ slot: PluginSlot, owner: UUID) {
        guard let unit = audio.unit(slot.id) else {
            message = audio.pluginErrors[slot.id] ?? "\(slot.name) is still loading."
            return
        }
        // Effects get an on/off button in the window's title bar, to compare with and without them.
        let isEffect = inserts(of: owner).contains { $0.id == slot.id }
        let power = isEffect ? NSHostingView(rootView: PluginPowerButton(session: self, ownerID: owner, slotID: slot.id)) : nil
        PluginWindows.open(unit, slot: slot.id, title: "\(slot.name) — \(chainName(owner))", accessory: power)
    }

    func pluginStatus(_ slot: PluginSlot) -> String? {
        _ = pluginRevision
        if let e = audio.pluginErrors[slot.id] { return e }
        if audio.unit(slot.id) == nil { return "Loading…" }
        return nil
    }

    func setBufferFrames(_ frames: Int) {
        bufferFrames = frames
        Prefs.bufferFrames = frames
        rebuildEngine()
    }

    // MARK: - UI clock

    private func tickUI() {
        audio.meters.decay()
        guard isPlaying, let pos = transport.currentPosition() else { return }
        playhead.position = pos
        if followPlayhead && !followSuspended {
            let visible = timelineWidth / pixelsPerSecond
            if pos > scrollX + visible * 0.92 || pos < scrollX {
                scrollX = max(0, pos - visible * 0.1)
            }
        }
    }

    // MARK: - Transport

    var loopRange: TimeRange? { song.loopEnabled && song.loop.isValid ? song.loop : nil }

    func togglePlay() {
        if isPlaying { stop() } else { play(from: playhead.position) }
    }

    func play(from position: Double) {
        guard exportProgress == nil else { return }
        guard ensureRunning() else { return }
        followSuspended = false
        playStart = position
        audio.applyAutomation(song, at: position)
        transport.start(PlayRequest(song: song, position: position, loop: loopRange))
        isPlaying = true
    }

    func stop() {
        guard isPlaying else { return }
        let stoppedAt = transport.currentPosition() ?? playhead.position
        isPlaying = false
        let wasRecording = isRecording
        if wasRecording { finishRecording() }
        transport.stop()
        playhead.position = returnOnStop ? playStart : max(0, stoppedAt)
        if wasRecording { deviceChanged() }   // a device change that arrived during the take was held back
    }

    /// Restart from the current position so edits take effect immediately.
    private func restartIfPlaying() {
        guard isPlaying, !isRecording, let pos = transport.currentPosition() else { return }
        let keepStart = playStart
        play(from: max(0, pos))
        playStart = keepStart
    }

    func locate(_ t: Double) {
        let t = max(0, t)
        if isRecording { return }
        if isPlaying {
            play(from: t)
        } else {
            playhead.position = t
            playStart = t
            audio.applyAutomation(song, at: t)
        }
    }

    func goToStart() { locate(0) }

    // MARK: - Recording

    func toggleRecord() {
        if isRecording { stop(); return }
        startRecording()
    }

    /// Start the engine if needed; if it can't run, say so instead of failing silently.
    private func ensureRunning() -> Bool {
        do {
            try audio.start()
            return true
        } catch {
            message = "Audio isn't running with the current devices. Pick System default in Settings (⌘,) and try again."
            return false
        }
    }

    func startRecording() {
        guard exportProgress == nil else { message = "Wait for the mixdown to finish."; return }
        guard ensureRunning() else { return }
        // Plenty of room? A few minutes of 96 kHz stereo is around 100 MB per track.
        if let free = (try? audioFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage {
            if free < 300_000_000 {
                message = "Your disk is almost full (\(free / 1_000_000) MB free), so recording is off. Free up some space first."
                return
            }
            if free < 2_000_000_000 {
                message = "Disk space is getting low (\(free / 1_000_000) MB free). Recording, but free up some space soon."
            }
        }
        if !song.tracks.contains(where: \.armed) {
            edit { s in
                if let id = selectedTrackID, let i = s.trackIndex(id) {
                    s.tracks[i].armed = true
                } else if !s.tracks.isEmpty {
                    s.tracks[0].armed = true
                } else {
                    s.tracks.append(Track(name: "Track 1", armed: true))
                }
            }
        }
        let audioTracks = song.tracks.filter { $0.armed && $0.kind == .audio }
        if !audioTracks.isEmpty && !audio.hasInput {
            message = audio.inputProblem ?? "No audio input found. Pick an input device in Settings."
            return
        }
        if !audioTracks.isEmpty && audio.inputSampleRate != audio.sampleRate {
            message = "Input and output sample rates differ. Set them to the same rate in Audio MIDI Setup."
            return
        }
        // Audio files only play at the song's rate, so a take at another rate would be silent.
        if hasAudioRecordings {
            if !audioTracks.isEmpty, song.sampleRate != audio.sampleRate {
                message = "This song is at \(Int(song.sampleRate)) Hz and your device can't switch from \(Int(audio.sampleRate)) Hz, so a new take wouldn't play. Pick a device that supports \(Int(song.sampleRate)) Hz."
                return
            }
        } else if song.sampleRate != audio.sampleRate {
            song.sampleRate = audio.sampleRate
        }

        let stamp = Int(Date().timeIntervalSince1970)
        var targets: [Recorder.Target] = []
        for t in audioTracks {
            let name = "\(ProjectStore.sanitize(t.name))-\(stamp)-\(t.id.uuidString.prefix(4)).caf"
            do {
                let file = try Recorder.makeFile(url: audioFolder.appendingPathComponent(name),
                                                 sampleRate: audio.sampleRate, channels: t.channels)
                targets.append(.init(trackID: t.id, fileName: name, channels: t.channels,
                                     inputChannel: min(t.inputChannel, max(0, inputChannelCount - 1)) + audio.inputChannelOffset,
                                     file: file))
            } catch {
                message = "Couldn't create a file to record into: \(error.localizedDescription)"
                return
            }
        }

        recMIDITracks = song.tracks.filter { $0.armed && $0.kind == .midi }.map(\.id)
        midiLock.lock(); midiEvents = []; midiRecording = !recMIDITracks.isEmpty; midiLock.unlock()

        if isPlaying, let timing = transport.timing, let pos = transport.currentPosition() {
            // Punch in on the fly.
            recStartSong = song.punchEnabled ? max(pos, song.punch.start) : pos
            startRecordMute(from: recStartSong)
            transport.update(song: playbackSong)
            let now = HostTime.seconds(HostTime.now) - HostTime.seconds(timing.anchorHost)
            recStartPlayer = max(0, now - audio.outputLatency)
            recorder.begin(targets: targets, sampleRate: audio.sampleRate)
            isRecording = true
        } else {
            var start = playhead.position
            if song.punchEnabled, start >= song.punch.start { start = max(0, song.punch.start - song.secondsPerBar) }
            if jamReady {
                // JAM: play straight on from the loop start; the loop repeats on the other tracks.
                start = song.loop.start
                jamLoop = song.loop
                jamExcluded = Set(song.tracks.filter(\.armed).map(\.id))
            } else {
                jamLoop = nil
            }
            let countIn = Double(song.countInBars) * song.secondsPerBar
            recStartSong = song.punchEnabled ? max(song.punch.start, start) : start
            startRecordMute(from: recStartSong)
            recorder.begin(targets: targets, sampleRate: audio.sampleRate)
            try? audio.start()
            playStart = start
            transport.start(PlayRequest(song: playbackSong, position: start, countIn: countIn, recording: true,
                                        loop: jamLoop == nil ? loopRange : nil))
            let map = transport.timing!.map
            recStartPlayer = Double(map.firstPlayerFrame(reaching: Int64(recStartSong * audio.sampleRate))) / audio.sampleRate
            isPlaying = true
            isRecording = true
        }
    }

    /// Player-time pieces (with song positions) covered by this recording pass.
    private func keptPieces(map: TimelineMap, endPlayer: Double) -> [(player: Double, song: TimeRange)] {
        let sr = audio.sampleRate
        let p0 = Int64(recStartPlayer * sr), p1 = Int64(endPlayer * sr)
        guard p1 > p0 else { return [] }
        return map.pieces(playerStart: p0, count: p1 - p0).compactMap { p in
            var r = TimeRange(start: Double(p.songStart) / sr, end: Double(p.songStart + p.length) / sr)
            let playerStart = Double(p.playerStart) / sr
            var shift = 0.0
            if song.punchEnabled {
                guard let c = r.clamped(to: song.punch) else { return nil }
                shift = c.start - r.start
                r = c
            }
            if r.start < 0 {
                shift += -r.start
                r.start = 0
            }
            guard r.length >= 0.25 else { return nil }
            return (playerStart + shift, r)
        }
    }

    private func finishRecording() {
        isRecording = false
        recordMute = nil
        guard let timing = transport.timing else { _ = recorder.finish(); jamLoop = nil; return }
        let map = timing.map
        let anchor = HostTime.seconds(timing.anchorHost)
        let outLat = audio.outputLatency
        let inLat = audio.inputLatency
        let offset = latencyOffsetMs / 1000
        let nowPlayer = HostTime.seconds(HostTime.now) - anchor - outLat

        midiLock.lock(); let events = midiEvents; midiEvents = []; midiRecording = false; midiLock.unlock()
        let result = recorder.finish()

        var newSong = song
        var recordedTrackIDs: [UUID] = []

        if let result, result.writeFailures > 0 {
            message = "Part of this take couldn't be saved (\(result.writeFailures) write error\(result.writeFailures == 1 ? "" : "s")). "
                + "Check that the disk has space."
        }
        if let result {
            let fileStart = HostTime.seconds(result.firstHost) - anchor - inLat - outLat - offset
            let fileEnd = fileStart + Double(result.frames) / result.sampleRate
            let pieces = keptPieces(map: map, endPlayer: min(fileEnd, nowPlayer + 0.05))
            for target in result.targets {
                guard let ti = newSong.trackIndex(target.trackID) else { continue }
                recordedTrackIDs.append(target.trackID)
                var newTakes: [Take] = []
                for p in pieces where p.player >= fileStart {
                    var take = Take(name: "Take \(newSong.tracks[ti].takes.count + newTakes.count + 1)",
                                    fileName: target.fileName, fileOffset: p.player - fileStart,
                                    start: p.song.start, duration: p.song.length)
                    take.duration = min(take.duration, fileEnd - p.player)
                    if take.duration > 0.25 { newTakes.append(take) }
                }
                for take in newTakes {
                    newSong.tracks[ti].takes.append(take)
                    newSong.tracks[ti].assign(takeID: take.id, over: take.range)
                }
                if newSong.tracks[ti].takes.count > 1 && newTakes.count > 1 { newSong.tracks[ti].showTakes = true }
                waveforms.load(target.fileName, folder: audioFolder, force: true)
                transport.fileChanged(target.fileName)
            }
        }

        if !recMIDITracks.isEmpty {
            let notes = Session.pairNotes(events, toPlayer: { HostTime.seconds($0) - anchor - outLat - offset }, endPlayer: nowPlayer)
            let pieces = keptPieces(map: map, endPlayer: nowPlayer)
            for id in recMIDITracks {
                guard let ti = newSong.trackIndex(id) else { continue }
                recordedTrackIDs.append(id)
                var added: [Take] = []
                for p in pieces {
                    let inPiece = notes.filter { $0.on >= p.player && $0.on < p.player + p.song.length }
                    guard !inPiece.isEmpty else { continue }
                    let take = Take(name: "Take \(newSong.tracks[ti].takes.count + added.count + 1)",
                                    start: p.song.start, duration: p.song.length,
                                    notes: inPiece.map { n in
                                        MIDINote(pitch: n.pitch, velocity: n.velocity, start: n.on - p.player,
                                                 duration: max(0.02, min(n.off, p.player + p.song.length) - n.on))
                                    })
                    added.append(take)
                }
                for take in added {
                    newSong.tracks[ti].takes.append(take)
                    newSong.tracks[ti].assign(takeID: take.id, over: take.range)
                }
                if added.count > 1 { newSong.tracks[ti].showTakes = true }
            }
        }

        if let loop = jamLoop {
            // Paste the loop out to the end of the take, in whole passes. Stopping within the
            // first beat of a new pass doesn't add another repeat.
            let stopSong = map.songTime(atPlayerTime: max(0, nowPlayer))
            let end = Session.jamEnd(loop: loop, stoppedAt: stopSong, beat: newSong.secondsPerBeat)
            newSong = newSong.tilingLoop(loop, until: end, excluding: jamExcluded)
            newSong.loopEnabled = false
            jamLoop = nil
            jamExcluded = []
        }

        applyAutoArm(&newSong, recorded: recordedTrackIDs)
        edit { $0 = newSong }
    }

    private struct RawNote { var pitch: UInt8; var velocity: UInt8; var on: Double; var off: Double }

    private static func pairNotes(_ events: [(UInt8, UInt8, UInt8, UInt64)], toPlayer: (UInt64) -> Double,
                                  endPlayer: Double) -> [RawNote] {
        var open: [UInt8: (Double, UInt8)] = [:]
        var notes: [RawNote] = []
        for (status, d1, d2, ts) in events {
            let t = toPlayer(ts)
            let kind = status & 0xF0
            if kind == 0x90 && d2 > 0 {
                if let o = open[d1] { notes.append(RawNote(pitch: d1, velocity: o.1, on: o.0, off: t)) }
                open[d1] = (t, d2)
            } else if kind == 0x80 || (kind == 0x90 && d2 == 0) {
                if let o = open.removeValue(forKey: d1) { notes.append(RawNote(pitch: d1, velocity: o.1, on: o.0, off: t)) }
            }
        }
        for (pitch, o) in open { notes.append(RawNote(pitch: pitch, velocity: o.1, on: o.0, off: endPlayer)) }
        return notes.sorted { $0.on < $1.on }
    }

    func applyAutoArm(_ s: inout Song, recorded: [UUID]) {
        guard s.autoArm != .off, let lastID = recorded.last, let li = s.trackIndex(lastID) else { return }
        let template = s.tracks[li]
        for i in s.tracks.indices { s.tracks[i].armed = false }
        // Monitoring follows the arm: the recorded tracks go quiet, the next one listens.
        for id in recorded { if let i = s.trackIndex(id) { s.tracks[i].monitor = false } }
        if s.autoArm == .nextTrack, li + 1 < s.tracks.count, s.tracks[li + 1].kind == template.kind {
            s.tracks[li + 1].armed = true
            s.tracks[li + 1].monitor = template.kind == .audio
            selectedTrackID = s.tracks[li + 1].id
            return
        }
        var t = Track(name: "Track \(s.tracks.count + 1)", kind: template.kind,
                      colorIndex: (template.colorIndex + 1) % TrackPalette.count, channels: template.channels,
                      inputChannel: template.inputChannel, armed: true, program: template.program)
        t.strip = ChannelStrip()
        t.monitor = template.kind == .audio
        s.tracks.insert(t, at: li + 1)
        selectedTrackID = t.id
    }

    /// Live recording overlay for a track: song position of the first shown peak and the peaks.
    func livePeaks(for trackID: UUID) -> (songStart: Double, step: Double, peaks: ArraySlice<Float>)? {
        guard isRecording, let live = recorder.live(trackID), let timing = transport.timing else { return nil }
        let anchor = HostTime.seconds(timing.anchorHost)
        let outLat = audio.outputLatency
        let inLat = audio.inputLatency
        let fileStart = HostTime.seconds(live.firstHost) - anchor - inLat - outLat - latencyOffsetMs / 1000
        let step = Double(Recorder.peakFrames) / audio.sampleRate
        let nowPlayer = fileStart + Double(live.peaks.count) * step
        let sr = audio.sampleRate
        let p0 = Int64(recStartPlayer * sr), p1 = Int64(nowPlayer * sr)
        guard p1 > p0, let piece = timing.map.pieces(playerStart: p0, count: p1 - p0).last else { return nil }
        let pieceStart = Double(piece.playerStart) / sr
        let first = max(0, Int(((pieceStart - fileStart) / step).rounded(.up)))
        guard first < live.peaks.count else { return nil }
        let songStart = timing.map.songTime(atPlayerTime: fileStart + Double(first) * step)
        return (songStart, step, live.peaks[first...])
    }

    // MARK: - Tracks

    func addTrack(kind: TrackKind) {
        edit { s in
            let n = s.tracks.count + 1
            var t = Track(name: kind == .midi ? "Keys \(n)" : "Track \(n)", kind: kind, colorIndex: s.tracks.count % TrackPalette.count)
            if kind == .midi { t.channels = 2 }
            if let sel = selectedTrackID, let i = s.trackIndex(sel) {
                s.tracks.insert(t, at: i + 1)
            } else {
                s.tracks.append(t)
            }
            selectedTrackID = t.id
            // The new track is the one to record next: it takes the arm and the monitoring (ready for headphones).
            if !isRecording { Self.armOnly([t.id], in: &s) }
        }
    }

    func deleteTrack(_ id: UUID) {
        if isRecording, song.tracks.first(where: { $0.id == id })?.armed == true {
            message = "That track is recording. Stop first, then delete it."
            return
        }
        edit { $0.tracks.removeAll { $0.id == id } }
        selectedTrackIDs.remove(id)
        if selectedTrackID == id { selectedTrackID = selectedTrackIDs.first }
    }

    func updateTrack(_ id: UUID, undoable: Bool = true, _ change: (inout Track) -> Void) {
        if undoable {
            edit { s in if let i = s.trackIndex(id) { change(&s.tracks[i]) } }
        } else if let i = song.trackIndex(id) {
            change(&song.tracks[i])
        }
    }

    // MARK: - Automation

    // Automation belongs to a track, or to the Master row when the ID is Song.masterID.

    func automation(_ owner: UUID) -> Automation {
        owner == Song.masterID ? song.master.auto : song.tracks.first { $0.id == owner }?.auto ?? Automation()
    }

    func updateAutomation(_ owner: UUID, undoable: Bool = true, _ change: (inout Automation) -> Void) {
        if undoable {
            edit { $0.updateAutomation(owner, change) }
        } else {
            song.updateAutomation(owner, change)
        }
    }

    /// Point lane `index` at another setting. A setting already on show elsewhere swaps places with it.
    func setLane(_ owner: UUID, _ index: Int, to target: AutoTarget) {
        updateAutomation(owner, undoable: false) { a in
            guard a.lanes.indices.contains(index) else { return }
            if let other = a.lanes.firstIndex(of: target) { a.lanes[other] = a.lanes[index] }
            a.lanes[index] = target
        }
    }

    /// Show another lane under lane `index`: the next automated setting not on show, or else the next one along.
    func addLane(_ owner: UUID, after index: Int) {
        let a = automation(owner)
        let choices = automationTargets(owner)
        let target = a.curves.keys.sorted { $0.key < $1.key }.first { !a.lanes.contains($0) }
            ?? choices.first { !a.lanes.contains($0) }
        guard let target else { return }
        updateAutomation(owner, undoable: false) { $0.lanes.insert(target, at: min(index + 1, $0.lanes.count)) }
    }

    /// Hide a lane. Its curve stays and keeps playing.
    func removeLane(_ owner: UUID, _ index: Int) {
        updateAutomation(owner, undoable: false) { a in
            guard a.lanes.count > 1, a.lanes.indices.contains(index) else { return }
            a.lanes.remove(at: index)
        }
    }

    /// The built-in settings a lane can move, in menu order (plugin parameters come on top of these).
    func automationTargets(_ owner: UUID) -> [AutoTarget] {
        if owner == Song.masterID {
            return [.volume, .limiterOn] + song.buses.flatMap { [AutoTarget.busReturn($0.id), .busMute($0.id)] }
        }
        return [.volume, .pan, .mute, .solo, .eqOn, .hpfOn, .lowGain, .midGain, .midFreq, .highGain,
                .compOn, .compThreshold, .compMakeup] + song.buses.map { .send($0.id) }
    }

    /// The setting's value without automation: what the mixer shows.
    func staticValue(_ owner: UUID, _ target: AutoTarget) -> Double {
        func b(_ v: Bool) -> Double { v ? 1 : 0 }
        if case .plugin(let slot, let address) = target {
            return Double(audio.unit(slot)?.auAudioUnit.parameterTree?.parameter(withAddress: address)?.value ?? 0)
        }
        if owner == Song.masterID {
            let m = song.master
            switch target {
            case .volume: return m.volumeDB
            case .limiterOn: return b(m.limiterOn)
            case .busReturn(let id): return song.buses.first { $0.id == id }?.returnDB ?? 0
            case .busMute(let id): return b(song.buses.first { $0.id == id }?.mute ?? false)
            default: return 0
            }
        }
        guard let t = song.tracks.first(where: { $0.id == owner }) else { return 0 }
        let s = t.strip
        switch target {
        case .volume: return s.volumeDB
        case .pan: return s.pan
        case .mute: return b(t.mute)
        case .solo: return b(t.solo)
        case .eqOn: return b(s.eqOn)
        case .hpfOn: return b(s.hpfOn)
        case .lowGain: return s.lowGain
        case .midGain: return s.midGain
        case .midFreq: return s.midFreq
        case .highGain: return s.highGain
        case .compOn: return b(s.compOn)
        case .compThreshold: return s.compThreshold
        case .compMakeup: return s.compMakeup
        case .send(let id): return s.sends[id] ?? 0
        default: return 0
        }
    }

    func toggleArm(_ id: UUID) {
        guard !isRecording else { return }
        updateTrack(id, undoable: false) { $0.armed.toggle() }
    }

    /// Apply a change to every selected track (or `fallback` when none is selected), as M and S do.
    func forSelectedTracks(fallback: UUID?, _ change: (inout Track) -> Void) {
        let ids = selectedTrackIDs.isEmpty ? Set(fallback.map { [$0] } ?? []) : selectedTrackIDs
        for id in ids { updateTrack(id, undoable: false, change) }
    }

    /// A: arm the selected tracks, or disarm them if they're all armed already.
    func toggleArmSelected(fallback: UUID?) {
        guard !isRecording else { return }
        let ids = selectedTrackIDs.isEmpty ? Set(fallback.map { [$0] } ?? []) : selectedTrackIDs
        let allArmed = song.tracks.filter { ids.contains($0.id) }.allSatisfy(\.armed)
        for id in ids { updateTrack(id, undoable: false) { $0.armed = !allArmed } }
    }

    /// Clicking a track header: select it, and record arming and monitoring follow the selection. With `extend`
    /// (⇧-click) the track is added to or taken out of the selection, to record several inputs at once.
    func selectTrack(_ id: UUID, extend: Bool) {
        if extend, !selectedTrackIDs.isEmpty {
            if selectedTrackIDs.contains(id) {
                guard selectedTrackIDs.count > 1 else { return }
                selectedTrackIDs.remove(id)
                if selectedTrackID == id { selectedTrackID = song.tracks.first { selectedTrackIDs.contains($0.id) }?.id }
            } else {
                selectedTrackIDs.insert(id)
                selectedTrackID = id
            }
        } else {
            selectedTrackID = id
            selectedTrackIDs = [id]
        }
        // A take in progress keeps its armed tracks.
        guard !isRecording else { return }
        let ids = selectedTrackIDs
        Self.armOnly(ids, in: &song)
    }

    /// Arm exactly `ids`; audio tracks monitor while armed and stop when they're not.
    static func armOnly(_ ids: Set<UUID>, in s: inout Song) {
        for i in s.tracks.indices {
            let on = ids.contains(s.tracks[i].id)
            s.tracks[i].armed = on
            if s.tracks[i].kind == .audio { s.tracks[i].monitor = on }
        }
    }

    func moveTrack(_ id: UUID, by delta: Int) {
        edit { s in
            guard let i = s.trackIndex(id) else { return }
            let j = max(0, min(s.tracks.count - 1, i + delta))
            let t = s.tracks.remove(at: i)
            s.tracks.insert(t, at: j)
        }
    }

    // MARK: - Takes and comping

    func comp(track: UUID, take: UUID, range: TimeRange) {
        updateTrack(track) { $0.assign(takeID: take, over: range) }
    }

    func useWholeTake(track: UUID, take: UUID) {
        guard let t = song.tracks.first(where: { $0.id == track })?.take(take) else { return }
        comp(track: track, take: take, range: t.range)
    }

    func deleteTake(track: UUID, take: UUID) {
        updateTrack(track) { $0.removeTake(take) }
    }

    /// Delete selected regions if any, otherwise silence the selected range on the selected track.
    func deleteSelection() {
        if !selectedRegions.isEmpty {
            let ids = selectedRegions
            edit { s in for i in s.tracks.indices { s.tracks[i].removeSegments(ids) } }
            selectedRegions = []
            return
        }
        guard let sel = selection, let id = selectedTrackID else { return }
        updateTrack(id) { $0.clearComp(sel) }
    }

    // MARK: - Region editing

    /// Start a drag: later previews are applied to this snapshot, and the end is one undo step.
    func beginGesture() { gestureBase = song }

    func previewGesture(_ change: (inout Song) -> Void) {
        guard var s = gestureBase else { return }
        change(&s)
        song = s
    }

    func endGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        guard song != base else { return }
        undoStack.append(base)
        redoStack.removeAll()
        if arrangementDiffers(base, song) { restartIfPlaying() }
    }

    /// For knobs and faders: a whole drag becomes one undo step.
    func continuousEdit(_ began: Bool) {
        if began { beginGesture() } else { endGesture() }
    }

    /// Snap to bars unless Option is held (region edits).
    func snapBar(_ t: Double) -> Double {
        NSEvent.modifierFlags.contains(.option) ? max(0, t) : max(0, song.snapToBar(t))
    }

    /// Regions the edit commands act on: the selection, or whatever sits under the playhead on the selected track.
    private var targetRegions: [(track: UUID, seg: CompSegment)] {
        var result: [(UUID, CompSegment)] = []
        for t in song.tracks {
            for seg in t.comp where selectedRegions.contains(seg.id) { result.append((t.id, seg)) }
        }
        if result.isEmpty, let id = selectedTrackID, let t = song.tracks.first(where: { $0.id == id }),
           let seg = t.segment(at: playhead.position) {
            result.append((id, seg))
        }
        return result
    }

    func splitAtPlayhead() {
        let t = playhead.position
        var targets = targetRegions
        if selectedRegions.isEmpty && targets.isEmpty {
            // Nothing selected: cut every track at the playhead.
            targets = song.tracks.compactMap { tr in tr.segment(at: t).map { (tr.id, $0) } }
        }
        guard !targets.isEmpty else { return }
        edit { s in
            for (tid, seg) in targets {
                if let i = s.trackIndex(tid) { s.tracks[i].splitSegment(seg.id, at: t) }
            }
        }
    }

    func copyRegions() {
        let targets = targetRegions
        guard let first = targets.map(\.seg.start).min() else { return }
        let last = targets.map(\.seg.end).max() ?? first
        var items: [RegionClipboard.Item] = []
        for (tid, seg) in targets {
            guard let take = song.tracks.first(where: { $0.id == tid })?.take(seg.takeID) else { continue }
            var s = seg
            s.start -= first
            s.end -= first
            s.offset -= first
            items.append(.init(take: take, segment: s))
        }
        clipboard = RegionClipboard(items: items, length: last - first)
    }

    /// Paste onto the selected track at `at` (default: the playhead).
    func pasteRegions(at: Double? = nil) {
        guard let clip = clipboard, !clip.items.isEmpty,
              let tid = selectedTrackID ?? song.tracks.first?.id else { return }
        let at = at ?? playhead.position
        edit { s in
            guard let i = s.trackIndex(tid) else { return }
            var newIDs: Set<UUID> = []
            for item in clip.items {
                let isAudio = item.take.fileName != nil
                guard isAudio == (s.tracks[i].kind == .audio) else { continue }
                if s.tracks[i].take(item.take.id) == nil { s.tracks[i].takes.append(item.take) }
                var seg = item.segment
                seg.id = UUID()
                seg.start += at
                seg.end += at
                seg.offset += at
                s.tracks[i].place(seg)
                newIDs.insert(seg.id)
            }
            selectedRegions = newIDs
        }
    }

    /// Copy the selected regions and paste them straight after themselves.
    func duplicateRegions() {
        let targets = targetRegions
        guard let tid = targets.first?.track, let start = targets.map(\.seg.start).min() else { return }
        copyRegions()
        guard let length = clipboard?.length else { return }
        selectedTrackID = tid
        pasteRegions(at: start + length)
    }

    func importAudio(_ urls: [URL]) {
        // Imports are converted to the song's rate so they play alongside what's already recorded.
        let sr = hasAudioRecordings && song.sampleRate > 0 ? song.sampleRate : audio.sampleRate
        if song.sampleRate != sr { song.sampleRate = sr }
        let at = playhead.position
        DispatchQueue.global(qos: .userInitiated).async { [audioFolder] in
            var imported: [(String, Double, Int, String)] = []
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let r = try? ProjectStore.importAudio(url, into: audioFolder, sampleRate: sr) {
                    imported.append((r.fileName, r.duration, r.channels, url.deletingPathExtension().lastPathComponent))
                } else {
                    failures.append(url.lastPathComponent)
                }
            }
            DispatchQueue.main.async {
                if !failures.isEmpty { self.message = "Couldn't import: \(failures.joined(separator: ", "))" }
                guard !imported.isEmpty else { return }
                self.edit { s in
                    for (file, dur, ch, name) in imported {
                        var t = Track(name: name, colorIndex: s.tracks.count % TrackPalette.count, channels: ch)
                        let take = Take(name: name, fileName: file, start: at, duration: dur)
                        t.takes = [take]
                        t.comp = [CompSegment(takeID: take.id, start: take.start, end: take.start + dur)]
                        s.tracks.append(t)
                    }
                }
                for (file, _, _, _) in imported { self.waveforms.load(file, folder: self.audioFolder) }
            }
        }
    }

    // MARK: - Markers, loop, punch

    static let sectionNames = ["Intro", "Verse", "Pre-Chorus", "Chorus", "Verse 2", "Chorus 2", "Bridge", "Solo", "Chorus 3", "Outro"]

    var sortedMarkers: [Marker] { song.markers.sorted { $0.position < $1.position } }

    func addMarker() {
        let pos = song.snapToBar(isPlaying ? (transport.currentPosition() ?? playhead.position) : playhead.position)
        guard !song.markers.contains(where: { abs($0.position - pos) < 0.01 }) else { return }
        edit { s in
            let name = Session.sectionNames[min(s.markers.count, Session.sectionNames.count - 1)]
            s.markers.append(Marker(name: name, position: pos))
        }
    }

    /// The span from a marker to the next one (or the end of the song).
    func sectionRange(_ marker: Marker) -> TimeRange {
        let next = sortedMarkers.first { $0.position > marker.position + 0.001 }?.position
        let end = next ?? max(song.contentEnd, marker.position + song.secondsPerBar * 4)
        return TimeRange(start: marker.position, end: song.snapToBar(end) > marker.position ? song.snapToBar(end) : end)
    }

    func loopSection(_ marker: Marker) {
        edit { s in
            s.loop = sectionRange(marker)
            s.loopEnabled = true
        }
        locate(marker.position)
    }

    func jumpToMarker(index: Int) {
        let m = sortedMarkers
        guard index < m.count else { return }
        locate(m[index].position)
    }

    /// Move one bar, snapping to the bar grid.
    func nudgeBar(forward: Bool) {
        let bar = song.secondsPerBar
        let pos = playhead.position
        let idx = forward ? floor(pos / bar + 1e-6) + 1 : ceil(pos / bar - 1e-6) - 1
        locate(max(0, idx * bar))
    }

    /// Jump to the next/previous section marker (or the song's start/end).
    func jumpMarker(forward: Bool) {
        let pos = playhead.position
        let stops = Set(sortedMarkers.map(\.position) + [0, song.contentEnd]).sorted()
        if forward {
            if let next = stops.first(where: { $0 > pos + 0.01 }) { locate(next) }
        } else {
            locate(stops.last { $0 < pos - 0.05 } ?? 0)
        }
    }

    func loopSelection() {
        guard let sel = selection, sel.isValid else { return }
        edit { $0.loop = sel; $0.loopEnabled = true }
    }

    func punchSelection() {
        guard let sel = selection, sel.isValid else { return }
        edit { $0.punch = sel; $0.punchEnabled = true }
    }

    func toggleLoop() {
        edit { s in
            if !s.loop.isValid || (s.loop.start == 0 && s.loop.end == 8 && s.contentEnd > 8 && !s.loopEnabled) {
                s.loop = TimeRange(start: s.snapToBar(playhead.position), end: s.snapToBar(playhead.position) + s.secondsPerBar * 4)
            }
            s.loopEnabled.toggle()
        }
    }

    func tapTempo() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 3 } + [now]
        guard tapTimes.count >= 3 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0.timeIntervalSince($1) }
        let bpm = 60 / (intervals.reduce(0, +) / Double(intervals.count))
        edit { $0.tempo = (bpm * 10).rounded() / 10 }
    }

    // MARK: - Export

    func export(format: ExportFormat, range: TimeRange, stems: Bool, completion: @escaping (URL?) -> Void) {
        stop()
        let base = song
        let folder = ProjectStore.bouncesFolder(projectURL)
        let stamp = Session.mixdownStamp(Date())
        var jobs: [(Song, URL)] = []
        let mixURL = Session.unusedURL(folder.appendingPathComponent(ProjectStore.sanitize("\(base.name) mix \(stamp)")),
                                       ext: format.ext)
        jobs.append((base, mixURL))
        if stems {
            let stemName = ProjectStore.sanitize("\(base.name) stems \(stamp)")
            let stemFolder = Session.unusedURL(folder.appendingPathComponent(stemName), ext: nil)
            try? FileManager.default.createDirectory(at: stemFolder, withIntermediateDirectories: true)
            for (i, t) in base.tracks.enumerated() where !t.comp.isEmpty && !t.mute {
                var s = base
                // Solo automation would pull other tracks into the stem.
                for j in s.tracks.indices { s.tracks[j].solo = j == i; s.tracks[j].auto.curves[.solo] = nil }
                let name = ProjectStore.sanitize(String(format: "%02d %@", i + 1, t.name))
                jobs.append((s, stemFolder.appendingPathComponent(name).appendingPathExtension(format.ext)))
            }
        }

        exportProgress = 0
        if audio.hasInput { audio.engine.inputNode.removeTap(onBus: 0) }
        audio.detachInputSink()
        let audio = self.audio, transport = self.transport!
        transport.queue.async {
            var failure: Error?
            for (i, job) in jobs.enumerated() {
                do {
                    try Exporter.render(audio: audio, transport: transport, song: job.0, range: range,
                                        to: job.1, format: format) { p in
                        DispatchQueue.main.async { self.exportProgress = (Double(i) + p) / Double(jobs.count) }
                    }
                } catch {
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async {
                self.exportProgress = nil
                self.audio.sync(self.song)
                self.rebuildEngine()
                if let failure {
                    self.message = "Export failed: \(failure.localizedDescription)"
                    completion(nil)
                } else {
                    completion(jobs.first?.1)
                }
            }
        }
    }

    /// Date and time for mixdown names, e.g. "2026-11-07 5.48 PM": the date sorts in order, and ":" can't be in
    /// a file name.
    static func mixdownStamp(_ date: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "\u{202F}", with: " ")   // the narrow space before AM/PM
        return "\(day.string(from: date)) \(time)"
    }

    /// `base` with the extension, or "base 2", "base 3"… if that's taken (two mixdowns in the same minute).
    static func unusedURL(_ base: URL, ext: String?) -> URL {
        func url(_ n: Int) -> URL {
            let u = n == 1 ? base : base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(n)")
            return ext.map { u.appendingPathExtension($0) } ?? u
        }
        var n = 1
        while FileManager.default.fileExists(atPath: url(n).path) { n += 1 }
        return url(n)
    }

    /// Default mixdown range: the whole song plus a reverb tail.
    var songRange: TimeRange {
        TimeRange(start: 0, end: max(song.contentEnd + 3, 1))
    }
}
