import AudioToolbox
import Foundation

/// A half-open range of song time, in seconds.
struct TimeRange: Codable, Equatable {
    var start: Double
    var end: Double

    var length: Double { end - start }
    var isValid: Bool { end - start > 0.01 }

    func clamped(to other: TimeRange) -> TimeRange? {
        let r = TimeRange(start: max(start, other.start), end: min(end, other.end))
        return r.length > 0 ? r : nil
    }

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

enum TrackKind: String, Codable {
    case audio, midi
}

enum AutoArmMode: String, Codable, CaseIterable, Identifiable {
    case off, newTrack, nextTrack
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Stay on track"
        case .newTrack: return "Arm a new track"
        case .nextTrack: return "Arm next track"
        }
    }
}

enum DelayDivision: String, Codable, CaseIterable, Identifiable {
    case quarter, eighth, dottedEighth, sixteenth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .dottedEighth: return "1/8."
        case .sixteenth: return "1/16"
        }
    }
    /// Length in beats.
    var beats: Double {
        switch self {
        case .quarter: return 1
        case .eighth: return 0.5
        case .dottedEighth: return 0.75
        case .sixteenth: return 0.25
        }
    }
}

struct MIDINote: Codable, Equatable {
    var pitch: UInt8
    var velocity: UInt8
    /// Relative to the owning take's start, in seconds.
    var start: Double
    var duration: Double
}

struct Take: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Audio file name inside the project's Audio folder (audio takes only).
    var fileName: String?
    /// Seconds into the audio file where this take's content begins.
    var fileOffset: Double = 0
    /// Song position of the take's first sample.
    var start: Double
    var duration: Double
    var notes: [MIDINote] = []

    var range: TimeRange { TimeRange(start: start, end: start + duration) }
}

/// One region of the comp: which take plays over a range of the song.
struct CompSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var takeID: UUID
    var start: Double
    var end: Double
    /// How far the take's material has been moved: at song time t we hear the take at t - offset.
    var offset: Double = 0
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    var range: TimeRange { TimeRange(start: start, end: end) }
    var length: Double { end - start }
}

struct AutoPoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Double
}

enum AutoParam: String, Codable, CaseIterable, Identifiable {
    case volume, pan
    var id: String { rawValue }
    var label: String { self == .volume ? "Volume" : "Pan" }
}

/// A MIDI track playing outboard gear: its notes go out to a MIDI device instead of an instrument.
struct ExternalMIDI: Codable, Equatable {
    var deviceID: Int32
    var deviceName: String
    var channel = 1
    /// Hear the gear's audio, plugged into the track's input channel(s), through the track's strip.
    var audioReturn = false
    /// Send notes this much earlier to make up for the gear's own delay.
    var latencyMs: Double = 0

    init(deviceID: Int32, deviceName: String, channel: Int = 1) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.channel = channel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(Int32.self, forKey: .deviceID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "MIDI device"
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        audioReturn = try c.decodeIfPresent(Bool.self, forKey: .audioReturn) ?? false
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
    }
}

/// Non-destructive MIDI quantize: notes are moved toward the grid as they play; the recorded notes stay as played.
struct Quantize: Codable, Equatable {
    enum Grid: String, Codable, CaseIterable, Identifiable {
        case quarter, eighth, eighthTriplet, sixteenth, sixteenthTriplet, thirtySecond
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quarter: return "1/4"
            case .eighth: return "1/8"
            case .eighthTriplet: return "1/8T"
            case .sixteenth: return "1/16"
            case .sixteenthTriplet: return "1/16T"
            case .thirtySecond: return "1/32"
            }
        }
        /// Grid spacing in beats (quarter notes).
        var beats: Double {
            switch self {
            case .quarter: return 1
            case .eighth: return 0.5
            case .eighthTriplet: return 1.0 / 3
            case .sixteenth: return 0.25
            case .sixteenthTriplet: return 1.0 / 6
            case .thirtySecond: return 0.125
            }
        }
        var isTriplet: Bool { self == .eighthTriplet || self == .sixteenthTriplet }
    }

    var grid: Grid = .sixteenth
    /// 1 moves notes all the way onto the grid; 0.5 halfway.
    var strength: Double = 1
    /// Where the second note of each grid pair falls: 0.5 is straight, 0.66 is a triplet shuffle.
    var swing: Double = 0.5

    init(grid: Grid = .sixteenth, strength: Double = 1, swing: Double = 0.5) {
        self.grid = grid
        self.strength = strength
        self.swing = swing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grid = try c.decodeIfPresent(Grid.self, forKey: .grid) ?? .sixteenth
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        swing = try c.decodeIfPresent(Double.self, forKey: .swing) ?? 0.5
    }

    /// Where a note starting at song time `t` plays.
    func apply(_ t: Double, secondsPerBeat spb: Double) -> Double {
        let g = grid.beats * spb
        guard g > 0 else { return t }
        // Swing works on pairs of grid steps (not for triplet grids, which already swing).
        let useSwing = !grid.isTriplet && abs(swing - 0.5) > 0.001
        var target: Double
        if useSwing {
            let pair = 2 * g
            let pairStart = floor(t / pair) * pair
            let candidates = [pairStart, pairStart + pair * swing, pairStart + pair]
            target = candidates.min { abs($0 - t) < abs($1 - t) }!
        } else {
            target = (t / g).rounded() * g
        }
        target = max(0, target)
        return t + (target - t) * strength
    }
}

/// A third-party Audio Unit on a track.
struct PluginSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var manufacturer: String
    var type: UInt32
    var subType: UInt32
    var manufacturerCode: UInt32
    var bypass = false
    /// The plugin's full state as a property list.
    var state: Data?

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType,
                                  componentManufacturer: manufacturerCode, componentFlags: 0, componentFlagsMask: 0)
    }
}

struct ChannelStrip: Codable, Equatable {
    var volumeDB: Double = 0
    var pan: Double = 0
    var eqOn = true
    var hpfOn = false
    var lowGain: Double = 0
    var midGain: Double = 0
    var midFreq: Double = 1000
    var highGain: Double = 0
    var compOn = false
    var compThreshold: Double = -18
    var compMakeup: Double = 4
    var reverbSend: Double = 0
    var delaySend: Double = 0
}

struct Track: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: TrackKind = .audio
    var colorIndex = 0
    /// 1 = mono, 2 = stereo.
    var channels = 1
    /// First hardware input channel (0-based). Stereo tracks use this and the next one.
    var inputChannel = 0
    var armed = false
    var mute = false
    var solo = false
    var showTakes = false
    /// General MIDI program for MIDI tracks; -1 means the drum kit.
    var program = 0
    var takes: [Take] = []
    var comp: [CompSegment] = []
    var strip = ChannelStrip()
    /// Hear the input through this track's effects (software monitoring).
    var monitor = false
    var volumeAuto: [AutoPoint] = []
    var panAuto: [AutoPoint] = []
    /// Follow the automation curves during playback.
    var autoRead = true
    var showAutomation = false
    var autoParam: AutoParam = .volume
    var inserts: [PluginSlot] = []
    /// Audio Unit instrument for MIDI tracks; nil uses the built-in General MIDI sounds.
    var instrument: PluginSlot?
    /// Outboard gear for MIDI tracks; when set, notes go to it instead of an instrument.
    var external: ExternalMIDI?
    /// MIDI quantize applied as notes play (nil = as played).
    var quantize: Quantize?

    func take(_ id: UUID) -> Take? { takes.first { $0.id == id } }

    func points(_ p: AutoParam) -> [AutoPoint] { p == .volume ? volumeAuto : panAuto }

    /// Where a note that starts at song time `t` actually plays, after this track's quantize.
    func playTime(_ t: Double, secondsPerBeat spb: Double) -> Double {
        quantize?.apply(t, secondsPerBeat: spb) ?? t
    }

    var hasAutomation: Bool { autoRead && (!volumeAuto.isEmpty || !panAuto.isEmpty) }

    /// Linear interpolation of an automation curve at time t (nil if the curve is empty).
    static func evaluate(_ points: [AutoPoint], at t: Double) -> Double? {
        guard let first = points.first else { return nil }
        if t <= first.time { return first.value }
        for (a, b) in zip(points, points.dropFirst()) where t < b.time {
            let f = (t - a.time) / max(1e-9, b.time - a.time)
            return a.value + (b.value - a.value) * f
        }
        return points.last!.value
    }

    /// End of the last piece of content on this track.
    var contentEnd: Double { comp.map(\.end).max() ?? 0 }
}

struct Marker: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var position: Double
}

enum ReverbRoom: String, Codable, CaseIterable, Identifiable {
    case room, plate, hall, cathedral
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct MasterSettings: Codable, Equatable {
    var volumeDB: Double = 0
    var limiterOn = true
    var reverbRoom: ReverbRoom = .plate
    var reverbReturnDB: Double = 0
    var delayDivision: DelayDivision = .dottedEighth
    var delayFeedback: Double = 30
    var delayReturnDB: Double = 0
}

struct Song: Codable, Equatable {
    var id = UUID()
    var name: String
    var tempo: Double = 120
    var beatsPerBar = 4
    /// Sample rate the audio files were recorded at (0 until first recording).
    var sampleRate: Double = 0
    var tracks: [Track] = []
    var markers: [Marker] = []
    var loop = TimeRange(start: 0, end: 8)
    var loopEnabled = false
    var punch = TimeRange(start: 4, end: 8)
    var punchEnabled = false
    var clickEnabled = true
    var clickOnlyWhileRecording = false
    var clickVolume: Double = 0.6
    var countInBars = 1
    var autoArm: AutoArmMode = .off
    var master = MasterSettings()

    var secondsPerBeat: Double { 60 / tempo }
    var secondsPerBar: Double { secondsPerBeat * Double(beatsPerBar) }

    var contentEnd: Double { tracks.map(\.contentEnd).max() ?? 0 }

    func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    /// Snap a time to the nearest beat.
    func snapToBeat(_ t: Double) -> Double {
        (t / secondsPerBeat).rounded() * secondsPerBeat
    }

    func snapToBar(_ t: Double) -> Double {
        (t / secondsPerBar).rounded() * secondsPerBar
    }

    /// "bar.beat.tick" display, 1-based like every DAW.
    func barsBeats(_ t: Double) -> String {
        let beatsTotal = t / secondsPerBeat
        let bar = Int(floor(beatsTotal / Double(beatsPerBar)))
        let beatInBar = beatsTotal - Double(bar * beatsPerBar)
        let beat = Int(floor(beatInBar))
        let tick = Int((beatInBar - Double(beat)) * 100)
        return String(format: "%d.%d.%02d", bar + 1, beat + 1, max(0, tick))
    }

    /// This song's setup without its recordings: tracks, instruments, strips, plugins (with their
    /// settings), sends, master, tempo and recording options. Takes, markers and automation are left
    /// out and every ID is new.
    func asTemplate() -> Song {
        var s = self
        s.id = UUID()
        s.sampleRate = 0
        s.markers = []
        s.loopEnabled = false
        s.punchEnabled = false
        s.tracks = tracks.map { t in
            var t = t
            t.id = UUID()
            t.takes = []
            t.comp = []
            t.volumeAuto = []
            t.panAuto = []
            t.showTakes = false
            t.showAutomation = false
            t.mute = false
            t.solo = false
            t.inserts = t.inserts.map { var slot = $0; slot.id = UUID(); return slot }
            if var inst = t.instrument { inst.id = UUID(); t.instrument = inst }
            return t
        }
        return s
    }

    static func newIdea() -> Song {
        let f = DateFormatter()
        f.dateFormat = "MMM d h.mm a"
        var song = Song(name: "Idea \(f.string(from: Date()))")
        // Monitoring on from the start: you hear yourself in headphones, and feedback protection keeps it
        // quiet while sound plays through the speakers.
        song.tracks = [Track(name: "Track 1", armed: true, monitor: true)]
        return song
    }
}

enum TrackPalette {
    static let count = 8
}

// MARK: - Decoding songs saved by older versions (missing keys fall back to defaults)

extension CompSegment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        takeID = try c.decode(UUID.self, forKey: .takeID)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
    }
}

extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Track(name: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        kind = try c.decodeIfPresent(TrackKind.self, forKey: .kind) ?? d.kind
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? d.colorIndex
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? d.channels
        inputChannel = try c.decodeIfPresent(Int.self, forKey: .inputChannel) ?? d.inputChannel
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? d.armed
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? d.mute
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? d.solo
        showTakes = try c.decodeIfPresent(Bool.self, forKey: .showTakes) ?? d.showTakes
        program = try c.decodeIfPresent(Int.self, forKey: .program) ?? d.program
        takes = try c.decodeIfPresent([Take].self, forKey: .takes) ?? []
        comp = try c.decodeIfPresent([CompSegment].self, forKey: .comp) ?? []
        strip = try c.decodeIfPresent(ChannelStrip.self, forKey: .strip) ?? d.strip
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? d.monitor
        volumeAuto = try c.decodeIfPresent([AutoPoint].self, forKey: .volumeAuto) ?? []
        panAuto = try c.decodeIfPresent([AutoPoint].self, forKey: .panAuto) ?? []
        autoRead = try c.decodeIfPresent(Bool.self, forKey: .autoRead) ?? d.autoRead
        showAutomation = try c.decodeIfPresent(Bool.self, forKey: .showAutomation) ?? d.showAutomation
        autoParam = try c.decodeIfPresent(AutoParam.self, forKey: .autoParam) ?? d.autoParam
        inserts = try c.decodeIfPresent([PluginSlot].self, forKey: .inserts) ?? []
        instrument = try c.decodeIfPresent(PluginSlot.self, forKey: .instrument)
        external = try c.decodeIfPresent(ExternalMIDI.self, forKey: .external)
        quantize = try c.decodeIfPresent(Quantize.self, forKey: .quantize)
    }
}

extension Take {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Take"
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        fileOffset = try c.decodeIfPresent(Double.self, forKey: .fileOffset) ?? 0
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        notes = try c.decodeIfPresent([MIDINote].self, forKey: .notes) ?? []
    }
}

extension ChannelStrip {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChannelStrip()
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? d.volumeDB
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? d.pan
        eqOn = try c.decodeIfPresent(Bool.self, forKey: .eqOn) ?? d.eqOn
        hpfOn = try c.decodeIfPresent(Bool.self, forKey: .hpfOn) ?? d.hpfOn
        lowGain = try c.decodeIfPresent(Double.self, forKey: .lowGain) ?? d.lowGain
        midGain = try c.decodeIfPresent(Double.self, forKey: .midGain) ?? d.midGain
        midFreq = try c.decodeIfPresent(Double.self, forKey: .midFreq) ?? d.midFreq
        highGain = try c.decodeIfPresent(Double.self, forKey: .highGain) ?? d.highGain
        compOn = try c.decodeIfPresent(Bool.self, forKey: .compOn) ?? d.compOn
        compThreshold = try c.decodeIfPresent(Double.self, forKey: .compThreshold) ?? d.compThreshold
        compMakeup = try c.decodeIfPresent(Double.self, forKey: .compMakeup) ?? d.compMakeup
        reverbSend = try c.decodeIfPresent(Double.self, forKey: .reverbSend) ?? d.reverbSend
        delaySend = try c.decodeIfPresent(Double.self, forKey: .delaySend) ?? d.delaySend
    }
}

extension MasterSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MasterSettings()
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? d.volumeDB
        limiterOn = try c.decodeIfPresent(Bool.self, forKey: .limiterOn) ?? d.limiterOn
        reverbRoom = (try? c.decodeIfPresent(ReverbRoom.self, forKey: .reverbRoom)) ?? d.reverbRoom
        reverbReturnDB = try c.decodeIfPresent(Double.self, forKey: .reverbReturnDB) ?? d.reverbReturnDB
        delayDivision = (try? c.decodeIfPresent(DelayDivision.self, forKey: .delayDivision)) ?? d.delayDivision
        delayFeedback = try c.decodeIfPresent(Double.self, forKey: .delayFeedback) ?? d.delayFeedback
        delayReturnDB = try c.decodeIfPresent(Double.self, forKey: .delayReturnDB) ?? d.delayReturnDB
    }
}

extension Song {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Song(name: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo) ?? d.tempo
        beatsPerBar = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? d.beatsPerBar
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? d.sampleRate
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        loop = try c.decodeIfPresent(TimeRange.self, forKey: .loop) ?? d.loop
        loopEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? d.loopEnabled
        punch = try c.decodeIfPresent(TimeRange.self, forKey: .punch) ?? d.punch
        punchEnabled = try c.decodeIfPresent(Bool.self, forKey: .punchEnabled) ?? d.punchEnabled
        clickEnabled = try c.decodeIfPresent(Bool.self, forKey: .clickEnabled) ?? d.clickEnabled
        clickOnlyWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .clickOnlyWhileRecording) ?? d.clickOnlyWhileRecording
        clickVolume = try c.decodeIfPresent(Double.self, forKey: .clickVolume) ?? d.clickVolume
        countInBars = try c.decodeIfPresent(Int.self, forKey: .countInBars) ?? d.countInBars
        autoArm = (try? c.decodeIfPresent(AutoArmMode.self, forKey: .autoArm)) ?? d.autoArm
        master = try c.decodeIfPresent(MasterSettings.self, forKey: .master) ?? d.master
    }
}
