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
    enum MonitorMode { case none, input, monoReturn, stereoReturn }
    /// What live input feeds this strip: an audio track's input, or a MIDI track's gear audio return.
    let monitorMode: MonitorMode

    static func monitorMode(for track: Track) -> MonitorMode {
        if track.kind == .audio { return .input }
        guard track.external?.audioReturn == true else { return .none }
        return track.channels == 1 ? .monoReturn : .stereoReturn
    }
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
        monitorMode = TrackNodes.monitorMode(for: track)
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
    /// Read from the transport and MIDI threads while the main thread adds and removes tracks, so it's locked.
    private(set) var tracks: [UUID: TrackNodes] {
        get { tracksLock.lock(); defer { tracksLock.unlock() }; return lockedTracks }
        set { tracksLock.lock(); lockedTracks = newValue; tracksLock.unlock() }
    }
    private let tracksLock = NSLock()
    private var lockedTracks: [UUID: TrackNodes] = [:]

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
    /// Whether the input is usable. Touching inputNode without one is unsafe (or, for a mismatched
    /// Bluetooth headset, degrades the output), so everything checks this first.
    private(set) var hasInput = false
    /// Why audio recording is unavailable, for the UI.
    private(set) var inputProblem: String?
    /// The user has denied microphone access (the UI offers to open System Settings).
    private(set) var micDenied = false
    /// The output device in use (selected or system default).
    private(set) var outputDeviceID: AudioDeviceID?
    /// Feedback protection: when true, no track monitors its input, whatever its I button says.
    var monitorMuted = false

    // Live input for per-track monitoring.
    private var inputRing: InputRing?
    private var inputSink: AVAudioSinkNode?
    private var liveInput = false
    /// The input format we set on the engine with our own connection. The input node may still report the
    /// system default device's format, which mustn't be used for taps or connections.
    private var manualInputFormat: AVAudioFormat?

    /// The format audio arrives in from the input (what taps and connections on the input node must use).
    var inputFormat: AVAudioFormat? {
        guard hasInput else { return nil }
        return manualInputFormat ?? engine.inputNode.outputFormat(forBus: 0)
    }

    // The app's own hardware connection when specific devices are chosen.
    private var io: HALIO?
    private var ioRunning = false

    // Audio Unit plugins, keyed by slot id. They outlive engine rebuilds.
    private(set) var units: [UUID: AVAudioUnit] = [:]
    private var loading: Set<UUID> = []
    private(set) var pluginErrors: [UUID: String] = [:]
    /// Called on the main thread when a plugin finishes loading (the session re-syncs).
    var onPluginsChanged: (() -> Void)?

    let meters = MeterStore()
    private var lastReverbRoom: ReverbRoom?

    /// Channels of the chosen input device (in an aggregate, the output device's own inputs are skipped).
    var inputChannelCount: Int {
        guard let f = inputFormat else { return 0 }
        return max(0, Int(f.channelCount) - inputChannelOffset)
    }
    /// Where the chosen input's channel 1 sits in the engine's input (non-zero only for some aggregates).
    private(set) var inputChannelOffset = 0
    private var aggregateID: AudioObjectID?

    func destroyAggregate() {
        if let agg = aggregateID { AudioHardwareDestroyAggregateDevice(agg) }
        aggregateID = nil
    }
    /// The input's rate and channels come from `inputFormat`: with our own connection the input node can
    /// still report the system default device, which has nothing to do with the chosen input.
    var inputSampleRate: Double { inputFormat?.sampleRate ?? 0 }

    /// Build a fresh engine graph, optionally on specific devices.
    func build(song: Song, inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?, inputEnabled: Bool = true,
               bufferFrames: Int? = nil) {
        io?.stop()
        io = nil
        ioRunning = false
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
        liveInput = false
        manualInputFormat = nil

        destroyAggregate()
        inputChannelOffset = 0
        outputDeviceID = outputDevice ?? AudioDevices.defaultDevice(input: false)
        let inID = inputDevice ?? AudioDevices.defaultDevice(input: true)
        hasInput = inID.map { AudioDevices.inputChannels($0) > 0 } ?? false
        inputProblem = hasInput ? nil : "No audio input device found. Pick one in Settings."
        micDenied = false
        if !inputEnabled {
            // Input switched off: never open the mic (no recording input, no monitoring, no feedback).
            hasInput = false
            inputProblem = "Audio input is off. Turn it on in the status bar or Settings to record audio."
        }
        switch inputEnabled ? AVCaptureDevice.authorizationStatus(for: .audio) : .authorized {
        case .denied, .restricted:
            hasInput = false
            micDenied = true
            inputProblem = "Song Creator isn't allowed to use the microphone, so audio recording is off. "
                + "Allow it in System Settings → Privacy & Security → Microphone."
        case .notDetermined:
            // Don't open the input until the user answers the permission prompt.
            hasInput = false
            inputProblem = "Waiting for microphone permission…"
        default:
            break
        }
        // Recording needs input and output at the same rate. If they differ, leave the input closed:
        // opening a Bluetooth headset's mic (e.g. 16 kHz) drops its output to 16 kHz call quality too.
        if hasInput, let inID, let outID = outputDevice ?? AudioDevices.defaultDevice(input: false) {
            // Follow the output's rate when the input can run at it (built-in mics, interfaces).
            if inID != outID, AudioDevices.sampleRate(inID) != AudioDevices.sampleRate(outID) {
                AudioDevices.setSampleRate(inID, AudioDevices.sampleRate(outID))
            }
            let inRate = AudioDevices.sampleRate(inID), outRate = AudioDevices.sampleRate(outID)
            if inRate > 0, outRate > 0, inRate != outRate {
                hasInput = false
                let name = AudioDevices.name(inID) ?? "The input"
                inputProblem = "\(name) records at \(Int(inRate)) Hz but plays at \(Int(outRate)) Hz, so audio recording is off. "
                    + "Playback, KEYS and MIDI still work. To record audio, pick another input in Settings (⌘,)."
            }
        }
        // Chosen devices get the app's own hardware connection (HALIO): AVAudioEngine's built-in I/O follows
        // the system default and overrides a device set on it. Separate input and output devices are joined
        // into a private aggregate first. "System default" keeps AVAudioEngine's own I/O.
        if inputDevice != nil || outputDevice != nil, let outID = outputDeviceID {
            var ioDevice = outID
            if hasInput, let inID, inID != outID {
                if let agg = AudioDevices.makeAggregate(output: outID, input: inID) {
                    aggregateID = agg
                    ioDevice = agg
                    inputChannelOffset = AudioDevices.inputChannels(outID)   // the output device's inputs come first
                } else {
                    hasInput = false
                    inputProblem = "Couldn't combine \(AudioDevices.name(inID) ?? "the input") with \(AudioDevices.name(outID) ?? "the output"). Try System default in Settings."
                }
            }
            if let bufferFrames { AudioDevices.setBufferSize(ioDevice, frames: bufferFrames) }
            let inChannels = hasInput ? AudioDevices.inputChannels(ioDevice) : 0
            if hasInput && inChannels == 0 {
                hasInput = false
                inputProblem = "The audio input isn't available right now. Check the device, or pick another input in Settings."
            }
            let rate = AudioDevices.sampleRate(ioDevice)
            if let hal = HALIO(device: ioDevice, sampleRate: rate > 0 ? rate : 48000, inputChannels: inChannels) {
                io = hal
            } else {
                hasInput = false
                inputProblem = "Couldn't open \(AudioDevices.name(outID) ?? "the chosen device"). Pick System default in Settings."
            }
        }
        if io == nil, hasInput {
            let f = engine.inputNode.inputFormat(forBus: 0)
            if f.channelCount == 0 || f.sampleRate == 0 {
                hasInput = false
                inputProblem = "The audio input isn't available right now. Check the device and microphone permission, or pick another input in Settings."
            }
        }

        if let hal = io {
            sampleRate = hal.sampleRate
        } else {
            sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if sampleRate <= 0 { sampleRate = 48000 }
        }
        stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)

        // With our own connection, the engine renders when the hardware asks (realtime manual rendering).
        if let hal = io {
            do {
                try engine.enableManualRenderingMode(.realtime, format: stereo, maximumFrameCount: hal.maxFrames)
                if hal.inputChannels > 0,
                   let inFormat = AudioEngine.floatFormat(sampleRate, channels: hal.inputChannels) {
                    _ = engine.inputNode.setManualRenderingInputPCMFormat(inFormat) { _ in hal.inputBufferList }
                    manualInputFormat = inFormat
                }
                hal.render = engine.manualRenderingBlock
            } catch {
                io = nil
                hasInput = false
                inputProblem = "Couldn't drive the chosen devices (\(error.localizedDescription)). Pick System default in Settings."
            }
        }

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
        if let io, !ioRunning {
            let status = io.start()
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "The audio device wouldn't start (Core Audio error \(status))."])
            }
            ioRunning = true
            // Wait (briefly) for the first hardware cycle so timing conversions have a reference.
            let deadline = Date().addingTimeInterval(0.5)
            while io.lastHost.load(ordering: .acquiring) == 0 && Date() < deadline { usleep(2_000) }
        }
    }

    deinit {
        // Stop our hardware connection before anything else is released: its callback renders the engine.
        io?.stop()
        io = nil
        destroyAggregate()
    }

    /// Stop everything (the hardware connection first, then the engine).
    func shutdown() {
        io?.stop()
        ioRunning = false
        engine.stop()
    }

    /// Engine sample time of the latest hardware cycle (own connection only; for diagnostics).
    var lastRenderedSample: Int64 { io?.lastSample.load(ordering: .acquiring) ?? 0 }

    /// Whether the app drives the hardware itself (chosen devices) instead of AVAudioEngine's own I/O.
    var usesOwnIO: Bool { io != nil }

    /// The engine render sample time at host time `h`, for scheduling against the hardware clock.
    func renderSample(atHost h: UInt64) -> Int64? {
        if let io { return io.sample(atHost: h) }
        guard let last = engine.outputNode.lastRenderTime, last.isSampleTimeValid, last.isHostTimeValid else { return nil }
        let dt = HostTime.seconds(h) - HostTime.seconds(last.hostTime)
        return last.sampleTime + Int64((dt * sampleRate).rounded())
    }

    /// Host time of an engine render sample (only needed with our own connection, whose engine times carry no host time).
    func hostTime(atRenderSample s: Int64) -> UInt64? { io?.hostTime(atSample: s) }

    /// Time from rendering to hearing.
    var outputLatency: Double {
        if let io { return AudioDevices.latency(io.device, input: false) }
        return engine.outputNode.presentationLatency
    }

    /// Time from sound reaching the input to it arriving in the app.
    var inputLatency: Double {
        guard hasInput else { return 0 }
        if let io { return AudioDevices.latency(io.device, input: true) }
        return engine.inputNode.presentationLatency
    }

    // MARK: - Live input

    private func attachInputSink() {
        guard hasInput else { return }
        if let hal = io {
            // Our own connection already has each cycle's input: feed the monitoring ring from it directly.
            let ring = InputRing(channels: hal.inputChannels)
            hal.onInput = { abl, frames, sample in ring.write(abl, frames: frames, atSample: sample) }
            inputRing = ring
            liveInput = true
            return
        }
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
        liveInput = true
    }

    /// Switch to faster-than-realtime offline rendering. Live input can't be pulled offline: once the
    /// engine has opened an input (e.g. a 16 kHz Bluetooth headset mic) an offline render with no input
    /// data comes out silent, so the input is fed silence and live monitoring is disconnected.
    func enableOfflineRendering(maxFrames: AVAudioFrameCount = 4096) throws {
        detachInputSink()
        io?.stop()          // waits until no hardware callback is running
        ioRunning = false
        engine.stop()
        let wasRealtimeManual = engine.isInManualRenderingMode
        if wasRealtimeManual { engine.disableManualRenderingMode() }
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: maxFrames)
        if hasInput {
            // Keep the input's current format (mono mic, multichannel interface…): anything attached to it,
            // like the recorder's tap, stays valid.
            let current = inputFormat ?? stereo!
            let format = current.channelCount > 0 && current.sampleRate == sampleRate ? current : stereo!
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames)!
            _ = engine.inputNode.setManualRenderingInputPCMFormat(format) { frames in
                silence.frameLength = min(frames, maxFrames)
                for buf in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
                }
                return UnsafePointer(silence.audioBufferList)
            }
        }
        // Leaving realtime manual mode briefly re-attaches the engine to the system default hardware, and it
        // then stops itself once (a configuration change). Start it and wait until it stays running, so
        // offline renders don't fail with "not running".
        if wasRealtimeManual {
            try engine.start()
            var stable = 0
            let deadline = Date().addingTimeInterval(1.5)
            while stable < 6 && Date() < deadline {
                usleep(20_000)
                if engine.isRunning { stable += 1 } else { stable = 0; try engine.start() }
            }
        }
    }

    /// Offline rendering can't pull live input; call before entering manual rendering mode.
    func detachInputSink() {
        io?.onInput = nil
        liveInput = false
        for n in tracks.values { n.monitorReader?.enabled.store(false, ordering: .relaxed) }
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
               existing.inputChannel == track.inputChannel,
               existing.monitorMode == TrackNodes.monitorMode(for: track) {
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

        // Live input into the strip: an audio track's input, or a MIDI track's outboard gear coming back in.
        if n.monitorMode != .none, let ring = inputRing {
            let reader = MonitorReader(ring: ring, firstChannel: track.inputChannel + inputChannelOffset,
                                       mono: n.monitorMode == .monoReturn)
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
                // Only on a real change: this runs on every mixer move, and many plugins (compressors,
                // reverbs) reset their state whenever bypass is set, even to the same value. That clicks and
                // briefly drops a compressor's gain reduction, so the track jumps to full level.
                if unit.auAudioUnit.shouldBypassEffect != slot.bypass {
                    unit.auAudioUnit.shouldBypassEffect = slot.bypass
                }
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
        // Out of process by default: a plugin that crashes then takes down only itself, not the app.
        let options: AudioComponentInstantiationOptions = Prefs.pluginsOutOfProcess ? .loadOutOfProcess : []
        AVAudioUnit.instantiate(with: slot.description, options: options) { [weak self] unit, error in
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

    /// Deinterleaved float format for any channel count. The plain "standard format" initializer returns nil
    /// above 2 channels (an interface with 4 inputs, say) unless a channel layout is given.
    static func floatFormat(_ rate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(max(1, channels))) }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
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
            // Gear coming back from a MIDI track isn't a mic, so feedback protection doesn't apply to it.
            // Only the armed track listens: new tracks default to monitoring, and every unarmed one playing the
            // same input as well would stack it up louder and louder.
            let wanted = track.kind == .audio ? track.monitor && track.armed && !monitorMuted : n.monitorMode != .none
            n.monitorReader?.enabled.store(wanted && liveInput, ordering: .relaxed)

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

    var canMonitorInput: Bool { liveInput }

    /// With our own connection, the recorder reads the input from here (the engine never pulls its input
    /// node, so a tap on it would get nothing).
    var ownInputRing: InputRing? { io != nil ? inputRing : nil }

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
