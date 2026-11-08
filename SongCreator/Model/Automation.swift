import Foundation

struct AutoPoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Double

    init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try c.decode(Double.self, forKey: .time)
        value = try c.decode(Double.self, forKey: .value)
    }
}

/// A setting that automation can move. Track lanes use the track settings (and `.volume` is the track's fader);
/// the Master row uses `.volume` for the master fader, `.limiterOn`, and the buses' returns and mutes. Any
/// plugin parameter on either is `.plugin(slot, address)`, with the value in the parameter's own units.
enum AutoTarget: Hashable {
    case volume, pan, mute, solo
    case eqOn, hpfOn, lowGain, midGain, midFreq, highGain
    case compOn, compThreshold, compMakeup
    /// A track's send to a bus.
    case send(UUID)
    case limiterOn
    case busReturn(UUID), busMute(UUID)
    case plugin(UUID, UInt64)

    /// Switches jump from one point's value to the next instead of sliding (value 1 is on).
    var isSwitch: Bool {
        switch self {
        case .mute, .solo, .eqOn, .hpfOn, .compOn, .limiterOn, .busMute: return true
        default: return false
        }
    }

    var key: String {
        switch self {
        case .volume: return "volume"
        case .pan: return "pan"
        case .mute: return "mute"
        case .solo: return "solo"
        case .eqOn: return "eqOn"
        case .hpfOn: return "hpfOn"
        case .lowGain: return "lowGain"
        case .midGain: return "midGain"
        case .midFreq: return "midFreq"
        case .highGain: return "highGain"
        case .compOn: return "compOn"
        case .compThreshold: return "compThreshold"
        case .compMakeup: return "compMakeup"
        case .limiterOn: return "limiterOn"
        case .send(let id): return "send:\(id.uuidString)"
        case .busReturn(let id): return "busReturn:\(id.uuidString)"
        case .busMute(let id): return "busMute:\(id.uuidString)"
        case .plugin(let id, let address): return "plugin:\(id.uuidString):\(address)"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":").map(String.init)
        switch parts.first {
        case "send": guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }; self = .send(id)
        case "busReturn": guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }; self = .busReturn(id)
        case "busMute": guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }; self = .busMute(id)
        case "plugin":
            guard parts.count == 3, let id = UUID(uuidString: parts[1]), let address = UInt64(parts[2]) else { return nil }
            self = .plugin(id, address)
        default:
            let simple: [AutoTarget] = [.volume, .pan, .mute, .solo, .eqOn, .hpfOn, .lowGain, .midGain, .midFreq,
                                        .highGain, .compOn, .compThreshold, .compMakeup, .limiterOn]
            guard let t = simple.first(where: { $0.key == key }) else { return nil }
            self = t
        }
    }

    /// The plugin slot this target belongs to, if it's a plugin parameter.
    var pluginSlot: UUID? { if case .plugin(let id, _) = self { return id } else { return nil } }

    /// The bus this target refers to, if any.
    var bus: UUID? {
        switch self {
        case .send(let id), .busReturn(let id), .busMute(let id): return id
        default: return nil
        }
    }
}

extension AutoTarget: Codable, CodingKeyRepresentable, Identifiable {
    var id: String { key }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let t = AutoTarget(key: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown automation \(s)"))
        }
        self = t
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    var codingKey: CodingKey { Key(stringValue: key) }
    init?<T: CodingKey>(codingKey: T) { self.init(key: codingKey.stringValue) }
}

/// The automation on a track or on the master: a curve per setting, and which lanes are on show.
struct Automation: Codable, Equatable {
    var curves: [AutoTarget: [AutoPoint]] = [:]
    /// Follow the curves during playback.
    var read = true
    var show = false
    /// The lanes shown, top to bottom.
    var lanes: [AutoTarget] = [.volume]

    func points(_ target: AutoTarget) -> [AutoPoint] { curves[target] ?? [] }

    /// Store a curve, or drop it when it's empty.
    mutating func set(_ target: AutoTarget, _ points: [AutoPoint]) {
        curves[target] = points.isEmpty ? nil : points.sorted { $0.time < $1.time }
    }

    var isEmpty: Bool { curves.values.allSatisfy(\.isEmpty) }
    var isActive: Bool { read && !isEmpty }

    /// The automated value of `target` at time t, or nil when it isn't automated (or read is off).
    func value(_ target: AutoTarget, at t: Double, step: Bool? = nil) -> Double? {
        guard read, let pts = curves[target], !pts.isEmpty else { return nil }
        return Automation.evaluate(pts, at: t, step: step ?? target.isSwitch)
    }

    /// A curve at time t: straight lines between points, or holding each point's value until the next one
    /// when `step` (switches and stepped plugin settings). Nil if the curve is empty.
    static func evaluate(_ points: [AutoPoint], at t: Double, step: Bool = false) -> Double? {
        guard let first = points.first else { return nil }
        if t <= first.time { return first.value }
        for (a, b) in zip(points, points.dropFirst()) where t < b.time {
            if step { return a.value }
            let f = (t - a.time) / max(1e-9, b.time - a.time)
            return a.value + (b.value - a.value) * f
        }
        return points.last!.value
    }

    /// Drop curves and lanes whose setting no longer exists.
    mutating func prune(keeping valid: (AutoTarget) -> Bool) {
        curves = curves.filter { valid($0.key) }
        lanes = lanes.filter(valid)
        if lanes.isEmpty { lanes = [.volume] }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Automation()
        // A setting this version doesn't know is skipped rather than failing the whole song.
        let raw = try c.decodeIfPresent([String: [AutoPoint]].self, forKey: .curves) ?? [:]
        curves = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in AutoTarget(key: k).map { ($0, v) } })
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? d.read
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? d.show
        let laneKeys = try c.decodeIfPresent([String].self, forKey: .lanes) ?? []
        lanes = laneKeys.compactMap(AutoTarget.init(key:))
        if lanes.isEmpty { lanes = d.lanes }
    }
}

extension Track {
    /// What the track's settings are at time t, with automation applied.
    struct Live {
        var strip: ChannelStrip
        var mute: Bool
        var solo: Bool
    }

    func live(at t: Double) -> Live {
        var s = strip
        var mute = self.mute, solo = self.solo
        guard auto.isActive else { return Live(strip: s, mute: mute, solo: solo) }
        let a = auto
        func on(_ target: AutoTarget, _ current: Bool) -> Bool { a.value(target, at: t).map { $0 >= 0.5 } ?? current }
        s.volumeDB = a.value(.volume, at: t) ?? s.volumeDB
        s.pan = a.value(.pan, at: t) ?? s.pan
        s.eqOn = on(.eqOn, s.eqOn)
        s.hpfOn = on(.hpfOn, s.hpfOn)
        s.lowGain = a.value(.lowGain, at: t) ?? s.lowGain
        s.midGain = a.value(.midGain, at: t) ?? s.midGain
        s.midFreq = a.value(.midFreq, at: t) ?? s.midFreq
        s.highGain = a.value(.highGain, at: t) ?? s.highGain
        s.compOn = on(.compOn, s.compOn)
        s.compThreshold = a.value(.compThreshold, at: t) ?? s.compThreshold
        s.compMakeup = a.value(.compMakeup, at: t) ?? s.compMakeup
        for case .send(let bus) in a.curves.keys {
            if let v = a.value(.send(bus), at: t) { s.sends[bus] = max(0, min(1, v)) }
        }
        mute = on(.mute, mute)
        solo = on(.solo, solo)
        return Live(strip: s, mute: mute, solo: solo)
    }

    /// The plugins whose parameters this track's lanes can move.
    var automatablePlugins: [PluginSlot] { (instrument.map { [$0] } ?? []) + inserts }
}

extension Song {
    /// The master and the buses at time t, with the Master row's automation applied.
    struct LiveMaster {
        var volumeDB: Double
        var limiterOn: Bool
        var busReturnDB: [UUID: Double]
        var busMute: [UUID: Bool]
    }

    func liveMaster(at t: Double) -> LiveMaster {
        let a = master.auto
        var m = LiveMaster(volumeDB: a.value(.volume, at: t) ?? master.volumeDB,
                           limiterOn: a.value(.limiterOn, at: t).map { $0 >= 0.5 } ?? master.limiterOn,
                           busReturnDB: [:], busMute: [:])
        for bus in buses {
            m.busReturnDB[bus.id] = a.value(.busReturn(bus.id), at: t) ?? bus.returnDB
            m.busMute[bus.id] = a.value(.busMute(bus.id), at: t).map { $0 >= 0.5 } ?? bus.mute
        }
        return m
    }

    var hasAutomation: Bool { master.auto.isActive || tracks.contains { $0.auto.isActive } }

    /// Every automated plugin parameter that should follow its curve: (slot, address, points).
    var pluginCurves: [(slot: UUID, address: UInt64, points: [AutoPoint])] {
        var out: [(UUID, UInt64, [AutoPoint])] = []
        for a in tracks.map(\.auto) + [master.auto] where a.read {
            for (target, pts) in a.curves where !pts.isEmpty {
                if case .plugin(let slot, let address) = target { out.append((slot, address, pts)) }
            }
        }
        return out
    }

    /// Change the automation of a track, or of the Master row for Song.masterID.
    mutating func updateAutomation(_ owner: UUID, _ change: (inout Automation) -> Void) {
        if owner == Song.masterID {
            change(&master.auto)
        } else if let i = trackIndex(owner) {
            change(&tracks[i].auto)
        }
    }

    /// Forget automation for buses and plugins that have been removed.
    mutating func pruneAutomation() {
        let busIDs = Set(buses.map(\.id))
        let masterSlots = Set((master.inserts + buses.flatMap(\.inserts)).map(\.id))
        master.auto.prune { t in
            if let b = t.bus { return busIDs.contains(b) }
            if let slot = t.pluginSlot { return masterSlots.contains(slot) }
            return [.volume, .limiterOn].contains(t)
        }
        for i in tracks.indices {
            let slots = Set(tracks[i].automatablePlugins.map(\.id))
            tracks[i].auto.prune { t in
                if let b = t.bus { return busIDs.contains(b) && { if case .send = t { return true } else { return false } }() }
                if let slot = t.pluginSlot { return slots.contains(slot) }
                return t != .limiterOn
            }
        }
    }
}
