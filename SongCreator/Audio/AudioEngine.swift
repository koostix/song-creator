import AVFoundation
import Accelerate

/// Thread-safe peak meters, written from audio taps and polled by the UI.
final class MeterStore {
    private let lock = NSLock()
    private var levels: [UUID: Float] = [:]
    private var inputs: [Float] = []

    static let masterID = UUID()

    func set(_ id: UUID, _ v: Float) { lock.lock(); levels[id] = max(v, (levels[id] ?? 0) * 0.85); lock.unlock() }
    func level(_ id: UUID) -> Float { lock.lock(); defer { lock.unlock() }; return levels[id] ?? 0 }
    func setInputs(_ v: [Float]) { lock.lock(); inputs = v; lock.unlock() }
    func input(_ ch: Int) -> Float { lock.lock(); defer { lock.unlock() }; return ch < inputs.count ? inputs[ch] : 0 }

    /// Decay all meters a little; called from the UI refresh.
    func decay() {
        lock.lock()
        for k in levels.keys { levels[k]! *= 0.8 }
        inputs = inputs.map { $0 * 0.8 }
        lock.unlock()
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var m: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            var p: Float = 0
            vDSP_maxmgv(data[c], 1, &p, vDSP_Length(buffer.frameLength))
            m = max(m, p)
        }
        return m
    }
}

/// The nodes behind one track:
/// source (+ live input monitor) → preMix → EQ → compressor → AU inserts → strip → (master, reverb, delay).
final class TrackNodes {
    let id: UUID
    let kind: TrackKind
    let player: AVAudioPlayerNode?
    /// Built-in sampler or an Audio Unit instrument (MIDI tracks).
    let instrument: AVAudioUnitMIDIInstrument?
    /// Plugin slot of the instrument; nil when it's the built-in sampler.
    let instrumentSlot: UUID?
    let preMix = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let comp = AVAudioUnitEffect(audioComponentDescription: AudioEngine.dynamicsDesc)
    let strip = AVAudioMixerNode()
    var monitorNode: AVAudioSourceNode?
    var monitorReader: MonitorReader?
    /// Insert slots currently wired between the compressor and the strip.
    var inserts: [UUID] = []
    /// Format of buffers scheduled on the player.
    let format: AVAudioFormat
    let inputChannel: Int
    var masterBus: AVAudioNodeBus = 0
    var reverbBus: AVAudioNodeBus = 0
    var delayBus: AVAudioNodeBus = 0
    var loadedProgram = Int.min

    init(track: Track, sampleRate: Double, instrument plugin: (UUID, AVAudioUnitMIDIInstrument)?) {
        id = track.id
        kind = track.kind
        inputChannel = track.inputChannel
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                               channels: AVAudioChannelCount(track.kind == .midi ? 2 : track.channels))!
        if track.kind == .audio {
            player = AVAudioPlayerNode()
            instrument = nil
            instrumentSlot = nil
        } else {
            player = nil
            instrument = plugin?.1 ?? AVAudioUnitSampler()
            instrumentSlot = plugin?.0
        }
    }

    var source: AVAudioNode { (player as AVAudioNode?) ?? instrument! }
    var sampler: AVAudioUnitSampler? { instrumentSlot == nil ? instrument as? AVAudioUnitSampler : nil }
}

final class AudioEngine {
    static let dynamicsDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    static let limiterDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    static let soundBank = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    private(set) var engine = AVAudioEngine()
    private(set) var sampleRate: Double = 48000
    private(set) var stereo: AVAudioFormat!
    private(set) var tracks: [UUID: TrackNodes] = [:]

    // Created fresh with each engine: audio units carry render state that doesn't move between engines.
    private(set) var masterMixer = AVAudioMixerNode()
    private(set) var limiter = AVAudioUnitEffect(audioComponentDescription: AudioEngine.limiterDesc)
    private(set) var reverbBus = AVAudioMixerNode()
    private(set) var reverb = AVAudioUnitReverb()
    private(set) var delayBus = AVAudioMixerNode()
    private(set) var delay = AVAudioUnitDelay()
    private(set) var clickPlayer = AVAudioPlayerNode()
    /// Plugin state carried across an engine rebuild, applied when each plugin reloads.
    private var carriedStates: [UUID: [String: Any]] = [:]
    private(set) var clickFormat: AVAudioFormat!
    /// Whether the selected input device has any channels. Touching inputNode without one is unsafe.
    private(set) var hasInput = false

    // Live input for per-track monitoring.
    private var inputRing: InputRing?
    private var inputSink: AVAudioSinkNode?

    // Audio Unit plugins, keyed by slot id. They outlive engine rebuilds.
    private(set) var units: [UUID: AVAudioUnit] = [:]
    private var loading: Set<UUID> = []
    private(set) var pluginErrors: [UUID: String] = [:]
    /// Called on the main thread when a plugin finishes loading (the session re-syncs).
    var onPluginsChanged: (() -> Void)?

    let meters = MeterStore()
    private var lastReverbRoom: ReverbRoom?

    var inputChannelCount: Int {
        hasInput ? Int(engine.inputNode.inputFormat(forBus: 0).channelCount) : 0
    }
    var inputSampleRate: Double { hasInput ? engine.inputNode.inputFormat(forBus: 0).sampleRate : 0 }

    /// Build a fresh engine graph, optionally on specific devices.
    func build(song: Song, inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?) {
        engine.stop()
        // Nothing is carried into the new engine: the old one may still be alive (a configuration-change
        // notification holds it), and its nodes and audio units belong to it. Plugins are reloaded into the
        // new engine with their current state.
        for (id, unit) in units {
            carriedStates[id] = unit.auAudioUnit.fullState
            PluginWindows.close(id)
        }
        units = [:]
        pluginErrors = [:]
        engine = AVAudioEngine()
        masterMixer = AVAudioMixerNode()
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioEngine.limiterDesc)
        reverbBus = AVAudioMixerNode()
        reverb = AVAudioUnitReverb()
        delayBus = AVAudioMixerNode()
        delay = AVAudioUnitDelay()
        clickPlayer = AVAudioPlayerNode()
        tracks = [:]
        lastReverbRoom = nil
        inputRing = nil
        inputSink = nil

        if let outputDevice { AudioDevices.setDevice(outputDevice, on: engine.outputNode) }
        let inID = inputDevice ?? AudioDevices.defaultDevice(input: true)
        hasInput = inID.map { AudioDevices.inputChannels($0) > 0 } ?? false
        if let inputDevice, hasInput { AudioDevices.setDevice(inputDevice, on: engine.inputNode) }

        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 48000 }
        stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)

        for node in [masterMixer, limiter, reverbBus, reverb, delayBus, delay, clickPlayer] as [AVAudioNode] {
            engine.attach(node)
        }
        engine.connect(masterMixer, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        engine.connect(reverbBus, to: reverb, format: stereo)
        engine.connect(reverb, to: masterMixer, format: stereo)
        engine.connect(delayBus, to: delay, format: stereo)
        engine.connect(delay, to: masterMixer, format: stereo)
        engine.connect(clickPlayer, to: engine.mainMixerNode, format: clickFormat)
        reverb.wetDryMix = 100
        delay.wetDryMix = 100
        delay.lowPassCutoff = 7000

        limiter.installTap(onBus: 0, bufferSize: 1024, format: nil) { [meters] buf, _ in
            meters.set(MeterStore.masterID, MeterStore.peak(buf))
        }

        attachInputSink()
        sync(song)
    }

    func start() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: - Live input

    private func attachInputSink() {
        guard hasInput else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate == sampleRate else { return }
        let ring = InputRing(channels: Int(format.channelCount))
        let sink = AVAudioSinkNode { _, frames, abl in
            ring.write(abl, frames: Int(frames))
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)
        inputRing = ring
        inputSink = sink
    }

    /// Offline rendering can't pull live input; call before entering manual rendering mode.
    func detachInputSink() {
        guard let sink = inputSink else { return }
        engine.disconnectNodeInput(sink)
        engine.detach(sink)
        inputSink = nil
        for n in tracks.values { n.monitorReader?.enabled.store(false, ordering: .relaxed) }
    }

    // MARK: - Graph sync

    /// Create/remove/rewire track nodes so they match the song, then push all parameters.
    func sync(_ song: Song) {
        // Plugins no longer referenced anywhere are released.
        let liveSlots = Set(song.tracks.flatMap { $0.inserts.map(\.id) + ($0.instrument.map { [$0.id] } ?? []) })
        for (id, unit) in units where !liveSlots.contains(id) {
            if unit.engine != nil {
                engine.disconnectNodeOutput(unit)
                engine.detach(unit)
            }
            units[id] = nil
            PluginWindows.close(id)
        }

        let ids = Set(song.tracks.map(\.id))
        for (id, nodes) in tracks where !ids.contains(id) { removeNodes(nodes) }
        for track in song.tracks {
            var plugin: (UUID, AVAudioUnitMIDIInstrument)?
            if track.kind == .midi, let slot = track.instrument {
                load(slot)
                if let inst = units[slot.id] as? AVAudioUnitMIDIInstrument { plugin = (slot.id, inst) }
            }
            if let existing = tracks[track.id],
               existing.kind == track.kind,
               existing.format.channelCount == (track.kind == .midi ? 2 : AVAudioChannelCount(track.channels)),
               existing.instrumentSlot == plugin?.0,
               existing.inputChannel == track.inputChannel {
                wireInserts(existing, track)
                continue
            }
            if let old = tracks[track.id] { removeNodes(old) }
            let n = addNodes(for: track, instrument: plugin)
            wireInserts(n, track)
        }
        applyParameters(song)
    }

    @discardableResult
    private func addNodes(for track: Track, instrument: (UUID, AVAudioUnitMIDIInstrument)?) -> TrackNodes {
        let n = TrackNodes(track: track, sampleRate: sampleRate, instrument: instrument)
        if n.source.engine != nil { n.source.engine?.detach(n.source) }
        for node in [n.source, n.preMix, n.eq, n.comp, n.strip] { engine.attach(node) }
        engine.connect(n.source, to: n.preMix, fromBus: 0, toBus: 0, format: n.kind == .midi ? stereo : n.format)
        engine.connect(n.preMix, to: n.eq, format: stereo)
        engine.connect(n.eq, to: n.comp, format: stereo)
        engine.connect(n.comp, to: n.strip, fromBus: 0, toBus: 0, format: stereo)
        n.masterBus = masterMixer.nextAvailableInputBus
        n.reverbBus = reverbBus.nextAvailableInputBus
        n.delayBus = delayBus.nextAvailableInputBus
        engine.connect(n.strip, to: [
            AVAudioConnectionPoint(node: masterMixer, bus: n.masterBus),
            AVAudioConnectionPoint(node: reverbBus, bus: n.reverbBus),
            AVAudioConnectionPoint(node: delayBus, bus: n.delayBus),
        ], fromBus: 0, format: stereo)

        if track.kind == .audio, let ring = inputRing {
            let reader = MonitorReader(ring: ring, firstChannel: track.inputChannel)
            let node = AVAudioSourceNode(format: n.format) { isSilence, _, frames, abl in
                reader.render(isSilence, Int(frames), abl)
            }
            engine.attach(node)
            engine.connect(node, to: n.preMix, fromBus: 0, toBus: 1, format: n.format)
            n.monitorNode = node
            n.monitorReader = reader
        }

        let eq = n.eq
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 90
        eq.bands[1].filterType = .lowShelf
        eq.bands[1].frequency = 120
        eq.bands[2].filterType = .parametric
        eq.bands[2].bandwidth = 1.2
        eq.bands[3].filterType = .highShelf
        eq.bands[3].frequency = 8000
        for b in eq.bands { b.bypass = false }

        setParam(n.comp, 2, 1)       // expansion ratio: off
        setParam(n.comp, 3, -100)    // expansion threshold
        setParam(n.comp, 4, 0.005)   // attack
        setParam(n.comp, 5, 0.12)    // release

        let id = track.id
        n.strip.installTap(onBus: 0, bufferSize: 1024, format: nil) { [meters] buf, _ in
            meters.set(id, MeterStore.peak(buf))
        }
        tracks[track.id] = n
        return n
    }

    private func removeNodes(_ n: TrackNodes) {
        n.strip.removeTap(onBus: 0)
        n.player?.stop()
        n.monitorReader?.enabled.store(false, ordering: .relaxed)
        for id in n.inserts {
            guard let unit = units[id], unit.engine != nil else { continue }
            engine.disconnectNodeOutput(unit)
            engine.detach(unit)
        }
        var nodes: [AVAudioNode] = [n.source, n.preMix, n.eq, n.comp, n.strip]
        if let m = n.monitorNode { nodes.append(m) }
        for node in nodes where node.engine != nil {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        tracks[n.id] = nil
    }

    /// Put the track's loaded, stereo-capable insert plugins between the compressor and the strip.
    private func wireInserts(_ n: TrackNodes, _ track: Track) {
        var wanted: [UUID] = []
        for slot in track.inserts {
            load(slot)
            if let unit = units[slot.id], pluginErrors[slot.id] == nil {
                unit.auAudioUnit.shouldBypassEffect = slot.bypass
                wanted.append(slot.id)
            }
        }
        guard wanted != n.inserts else { return }

        engine.disconnectNodeOutput(n.comp)
        for id in n.inserts {
            guard let unit = units[id], unit.engine != nil else { continue }
            engine.disconnectNodeOutput(unit)
            if !wanted.contains(id) { engine.detach(unit) }
        }
        var last: AVAudioNode = n.comp
        var wired: [UUID] = []
        for id in wanted {
            guard let unit = units[id] else { continue }
            if unit.engine == nil { engine.attach(unit) }
            engine.connect(last, to: unit, format: stereo)
            last = unit
            wired.append(id)
        }
        engine.connect(last, to: n.strip, fromBus: 0, toBus: 0, format: stereo)
        n.inserts = wired
    }

    // MARK: - Plugins

    /// Start loading a plugin slot if it isn't loaded yet.
    func load(_ slot: PluginSlot) {
        guard units[slot.id] == nil, !loading.contains(slot.id), pluginErrors[slot.id] == nil else { return }
        loading.insert(slot.id)
        AVAudioUnit.instantiate(with: slot.description, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(slot.id)
                guard let unit else {
                    self.pluginErrors[slot.id] = error?.localizedDescription ?? "\(slot.name) couldn't be loaded."
                    self.onPluginsChanged?()
                    return
                }
                if let carried = self.carriedStates.removeValue(forKey: slot.id) {
                    unit.auAudioUnit.fullState = carried
                } else if let data = slot.state,
                   let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = state
                }
                // Effects run in stereo here; refuse plugins that can't.
                if slot.type != kAudioUnitType_MusicDevice {
                    do {
                        try unit.auAudioUnit.inputBusses[0].setFormat(self.stereo)
                        try unit.auAudioUnit.outputBusses[0].setFormat(self.stereo)
                    } catch {
                        self.pluginErrors[slot.id] = "\(slot.name) doesn't support stereo at \(Int(self.sampleRate)) Hz."
                        self.onPluginsChanged?()
                        return
                    }
                }
                self.units[slot.id] = unit
                self.onPluginsChanged?()
            }
        }
    }

    func unit(_ slot: UUID) -> AVAudioUnit? { units[slot] }
    func isLoading(_ slot: UUID) -> Bool { loading.contains(slot) }

    /// A plugin's current state for saving.
    func pluginState(_ slot: UUID) -> Data? {
        guard let state = units[slot]?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    // MARK: - Parameters

    private func setParam(_ unit: AVAudioUnit, _ id: AudioUnitParameterID, _ value: Double) {
        AudioUnitSetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
    }

    static func gain(_ db: Double) -> Float { db <= -60 ? 0 : Float(pow(10, db / 20)) }

    /// Song position the automation was last evaluated at.
    private(set) var automationTime: Double = 0

    private func setLevel(_ track: Track, _ n: TrackNodes, anySolo: Bool, at t: Double) {
        let audible = !track.mute && (!anySolo || track.solo)
        var db = track.strip.volumeDB, pan = track.strip.pan
        if track.autoRead {
            db = Track.evaluate(track.volumeAuto, at: t) ?? db
            pan = Track.evaluate(track.panAuto, at: t) ?? pan
        }
        n.strip.outputVolume = audible ? AudioEngine.gain(db) : 0
        n.strip.destination(forMixer: masterMixer, bus: n.masterBus)?.pan = Float(pan)
    }

    /// Apply volume/pan automation for song time `t`. Cheap; called every few ms while playing.
    func applyAutomation(_ song: Song, at t: Double) {
        automationTime = t
        let anySolo = song.tracks.contains { $0.solo }
        for track in song.tracks where track.hasAutomation {
            if let n = tracks[track.id] { setLevel(track, n, anySolo: anySolo, at: t) }
        }
    }

    func applyParameters(_ song: Song) {
        let anySolo = song.tracks.contains { $0.solo }
        for track in song.tracks {
            guard let n = tracks[track.id] else { continue }
            let s = track.strip
            setLevel(track, n, anySolo: anySolo, at: automationTime)
            n.strip.destination(forMixer: reverbBus, bus: n.reverbBus)?.volume = Float(s.reverbSend)
            n.strip.destination(forMixer: delayBus, bus: n.delayBus)?.volume = Float(s.delaySend)
            n.monitorReader?.enabled.store(track.monitor && inputSink != nil, ordering: .relaxed)

            n.eq.bypass = !s.eqOn && !s.hpfOn
            n.eq.bands[0].bypass = !s.hpfOn
            for b in n.eq.bands[1...] { b.bypass = !s.eqOn }
            n.eq.bands[1].gain = Float(s.lowGain)
            n.eq.bands[2].gain = Float(s.midGain)
            n.eq.bands[2].frequency = Float(s.midFreq)
            n.eq.bands[3].gain = Float(s.highGain)

            n.comp.bypass = !s.compOn
            setParam(n.comp, 0, s.compThreshold)
            setParam(n.comp, 1, 6)
            setParam(n.comp, 6, s.compMakeup)

            if let sampler = n.sampler, n.loadedProgram != track.program {
                n.loadedProgram = track.program
                let drums = track.program < 0
                try? sampler.loadSoundBankInstrument(
                    at: AudioEngine.soundBank,
                    program: UInt8(drums ? 0 : track.program),
                    bankMSB: UInt8(drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            }
        }

        let m = song.master
        masterMixer.outputVolume = AudioEngine.gain(m.volumeDB)
        limiter.bypass = !m.limiterOn
        setParam(limiter, 2, 0) // pre-gain
        if lastReverbRoom != m.reverbRoom {
            lastReverbRoom = m.reverbRoom
            switch m.reverbRoom {
            case .room: reverb.loadFactoryPreset(.mediumRoom)
            case .plate: reverb.loadFactoryPreset(.plate)
            case .hall: reverb.loadFactoryPreset(.largeHall)
            case .cathedral: reverb.loadFactoryPreset(.cathedral)
            }
            reverb.wetDryMix = 100
        }
        reverbBus.outputVolume = AudioEngine.gain(m.reverbReturnDB)
        delayBus.outputVolume = AudioEngine.gain(m.delayReturnDB)
        delay.delayTime = min(2, m.delayDivision.beats * song.secondsPerBeat)
        delay.feedback = Float(m.delayFeedback)
        clickPlayer.volume = Float(song.clickVolume)
    }

    var canMonitorInput: Bool { inputSink != nil }

    // MARK: - MIDI to instruments

    func sendMIDI(track: UUID, status: UInt8, data1: UInt8, data2: UInt8) {
        tracks[track]?.instrument?.sendMIDIEvent(status, data1: data1, data2: data2)
    }

    func allNotesOff() {
        for n in tracks.values {
            guard let s = n.instrument else { continue }
            for ch: UInt8 in 0..<16 {
                s.sendMIDIEvent(0xB0 | ch, data1: 123, data2: 0)
                s.sendMIDIEvent(0xB0 | ch, data1: 120, data2: 0)
            }
        }
    }
}
