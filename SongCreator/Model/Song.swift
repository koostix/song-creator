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

    func take(_ id: UUID) -> Take? { takes.first { $0.id == id } }

    func points(_ p: AutoParam) -> [AutoPoint] { p == .volume ? volumeAuto : panAuto }

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
    }
}
