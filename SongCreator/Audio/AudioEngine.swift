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
/// source (+ live input monitor) → preMix → EQ → compressor → AU inserts → strip → (master, each bus's send).
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
    /// Head of the insert chain. The compressor feeds it and never changes, so wiring plugins in and out
    /// never touches the player's own path (see AudioEngine.wireChain).
    let insertIn = AVAudioMixerNode()
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
    /// Insert slots currently wired between insertIn and the strip.
    var inserts: [UUID] = []
    /// Format of buffers scheduled on the player.
    let format: AVAudioFormat
    let inputChannel: Int
    var masterBus: AVAudioNodeBus = 0
    /// The strip's input on keepAlive (the strip always feeds it, so its sends can come and go).
    var keepBus: AVAudioNodeBus = 0
    /// The strip's input on each bus it sends to, by bus ID.
    var sendBuses: [UUID: AVAudioNodeBus] = [:]
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

/// The nodes behind one effect bus: sends sum into `input` → insertIn → its plugins → `output` (the return
/// level) → the master mix.
final class BusNodes {
    let id: UUID
    let input = AVAudioMixerNode()
    /// Head of the plugin chain (see AudioEngine.wireChain).
    let insertIn = AVAudioMixerNode()
    let output = AVAudioMixerNode()
    var inserts: [UUID] = []
    /// Its links into the mix are made (see AudioEngine.linkBus).
    var linked = false
    init(id: UUID) { self.id = id }
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
    /// The master chain: every track and return sums here → the master's plugins → masterFader → limiter.
    private(set) var masterMixer = AVAudioMixerNode()
    /// The master volume, after the master's plugins so they see the same mix however the fader is set.
    private(set) var masterFader = AVAudioMixerNode()
    /// Head of the master's plugin chain (masterMixer feeds it; see wireChain).
    private(set) var masterIn = AVAudioMixerNode()
    /// The master's plugins, wired in this order between masterIn and masterFader.
    private(set) var masterInserts: [UUID] = []
    /// A muted mixer into the output. Every chain's source also feeds it, so the source always has a path to
    /// the output while plugins are wired in or out. When that path is cut, even for a moment, the engine
    /// resets everything upstream: a playing track's player throws away its queued audio and stays silent
    /// until playback is restarted.
    private(set) var keepAlive = AVAudioMixerNode()
    private(set) var limiter = AVAudioUnitEffect(audioComponentDescription: AudioEngine.limiterDesc)
    /// Effect buses, by bus ID.
    private(set) var buses: [UUID: BusNodes] = [:]
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
        masterFader = AVAudioMixerNode()
        masterIn = AVAudioMixerNode()
        keepAlive = AVAudioMixerNode()
        masterInserts = []
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioEngine.limiterDesc)
        buses = [:]
        clickPlayer = AVAudioPlayerNode()
        tracks = [:]
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

        for node in [masterMixer, masterIn, masterFader, limiter, clickPlayer, keepAlive] as [AVAudioNode] {
            engine.attach(node)
        }
        engine.connect(keepAlive, to: engine.mainMixerNode, fromBus: 0,
                       toBus: engine.mainMixerNode.nextAvailableInputBus, format: stereo)
        keepAlive.outputVolume = 0
        feedChain(from: masterMixer, to: masterIn)
        engine.connect(masterIn, to: masterFader, format: stereo)
        engine.connect(masterFader, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        engine.connect(clickPlayer, to: engine.mainMixerNode, format: clickFormat)

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
        // New buses first, so tracks can send to them; removed ones once no track sends there any more.
        for bus in song.buses where buses[bus.id] == nil { addBus(bus.id) }
        let busIDs = song.buses.map(\.id)
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
                routeSends(existing, to: busIDs, levels: track.strip.sends)
                wireInserts(existing, track)
                continue
            }
            if let old = tracks[track.id] { removeNodes(old) }
            let n = addNodes(for: track, instrument: plugin, buses: busIDs)
            wireInserts(n, track)
        }
        for (id, nodes) in buses where !busIDs.contains(id) { removeBus(nodes) }
        for bus in song.buses {
            guard let n = buses[bus.id] else { continue }
            linkBus(n)
            if n.linked { n.inserts = wireChain(bus.inserts, current: n.inserts, from: n.insertIn, to: n.output) }
        }
        masterInserts = wireChain(song.master.inserts, current: masterInserts, from: masterIn, to: masterFader)

        // Plugins no longer referenced anywhere are released (after rewiring, which has already taken removed
        // effects out of their chains without breaking them).
        let liveSlots = Set(song.tracks.flatMap { $0.inserts.map(\.id) + ($0.instrument.map { [$0.id] } ?? []) }
                            + song.master.inserts.map(\.id) + song.buses.flatMap { $0.inserts.map(\.id) })
        for (id, unit) in units where !liveSlots.contains(id) {
            if unit.engine != nil {
                engine.disconnectNodeOutput(unit)
                engine.detach(unit)
            }
            units[id] = nil
            PluginWindows.close(id)
        }
        applyParameters(song)
    }

    @discardableResult
    private func addNodes(for track: Track, instrument: (UUID, AVAudioUnitMIDIInstrument)?, buses busIDs: [UUID]) -> TrackNodes {
        let n = TrackNodes(track: track, sampleRate: sampleRate, instrument: instrument)
        if n.source.engine != nil { n.source.engine?.detach(n.source) }
        for node in [n.source, n.preMix, n.eq, n.comp, n.insertIn, n.strip] { engine.attach(node) }
        engine.connect(n.source, to: n.preMix, fromBus: 0, toBus: 0, format: n.kind == .midi ? stereo : n.format)
        engine.connect(n.preMix, to: n.eq, format: stereo)
        engine.connect(n.eq, to: n.comp, format: stereo)
        feedChain(from: n.comp, to: n.insertIn)
        engine.connect(n.insertIn, to: n.strip, fromBus: 0, toBus: 0, format: stereo)
        n.masterBus = masterMixer.nextAvailableInputBus
        n.keepBus = keepAlive.nextAvailableInputBus
        routeSends(n, to: busIDs, levels: track.strip.sends, force: true)

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
        var nodes: [AVAudioNode] = [n.source, n.preMix, n.eq, n.comp, n.insertIn, n.strip]
        if let m = n.monitorNode { nodes.append(m) }
        for node in nodes where node.engine != nil {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        tracks[n.id] = nil
    }

    /// Point a track's strip at the master and at each bus. The strip always feeds keepAlive as well: the engine
    /// won't take a fan-out down to a single link, and that keeps it at two or more as buses come and go.
    private func routeSends(_ n: TrackNodes, to busIDs: [UUID], levels: [UUID: Double], force: Bool = false) {
        let wanted = busIDs.filter { buses[$0] != nil }
        guard force || Set(wanted) != Set(n.sendBuses.keys) else { return }
        var points = [AVAudioConnectionPoint(node: masterMixer, bus: n.masterBus),
                      AVAudioConnectionPoint(node: keepAlive, bus: n.keepBus)]
        var sends: [UUID: AVAudioNodeBus] = [:]
        for id in wanted {
            let input = buses[id]!.input
            let bus = n.sendBuses[id] ?? input.nextAvailableInputBus
            sends[id] = bus
            points.append(AVAudioConnectionPoint(node: input, bus: bus))
        }
        engine.connect(n.strip, to: points, fromBus: 0, format: stereo)
        n.sendBuses = sends
        // A new link starts at full level: set the real one now, not a render cycle later.
        for (id, bus) in sends {
            n.strip.destination(forMixer: buses[id]!.input, bus: bus)?.volume = Float(levels[id] ?? 0)
        }
    }

    private func addBus(_ id: UUID) {
        let n = BusNodes(id: id)
        for node in [n.input, n.insertIn, n.output] { engine.attach(node) }
        buses[id] = n
    }

    /// Link a bus into the mix, from its input down: input → insertIn → output → master. Done after the tracks'
    /// strips feed its input, because a running engine silently drops a link from a node that nothing feeds yet.
    /// If that still happens (a bus with no tracks to feed it), the next sync tries again.
    private func linkBus(_ n: BusNodes) {
        guard !n.linked else { return }
        engine.connect(n.input, to: n.insertIn, fromBus: 0, toBus: 0, format: stereo)
        engine.connect(n.insertIn, to: n.output, fromBus: 0, toBus: 0, format: stereo)
        engine.connect(n.output, to: masterMixer, fromBus: 0, toBus: masterMixer.nextAvailableInputBus, format: stereo)
        guard !engine.outputConnectionPoints(for: n.output, outputBus: 0).isEmpty else { return }
        n.linked = true
        let id = n.id
        n.output.installTap(onBus: 0, bufferSize: 1024, format: nil) { [meters] buf, _ in
            meters.set(id, MeterStore.peak(buf))
        }
    }

    /// Called once no track sends to the bus any more, so nothing that plays is cut off.
    private func removeBus(_ n: BusNodes) {
        if n.linked { n.output.removeTap(onBus: 0) }
        for id in n.inserts {
            guard let unit = units[id], unit.engine != nil else { continue }
            engine.disconnectNodeOutput(unit)
            engine.detach(unit)
        }
        for node in [n.input, n.insertIn, n.output] where node.engine != nil {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        buses[n.id] = nil
    }

    /// Put the track's loaded, stereo-capable insert plugins between insertIn and the strip.
    private func wireInserts(_ n: TrackNodes, _ track: Track) {
        n.inserts = wireChain(track.inserts, current: n.inserts, from: n.insertIn, to: n.strip)
    }

    /// Connect a chain's source to its head mixer, and also to the muted keepAlive mixer, for good. Done once,
    /// when the nodes are built; from then on only the links after the head mixer change.
    private func feedChain(from source: AVAudioNode, to head: AVAudioMixerNode) {
        engine.connect(source, to: [AVAudioConnectionPoint(node: head, bus: 0),
                                    AVAudioConnectionPoint(node: keepAlive, bus: keepAlive.nextAvailableInputBus)],
                       fromBus: 0, format: stereo)
    }

    /// Wire the loaded plugins of `slots`, in order, from `head` to `destination`. `current` is what's wired
    /// now; returns what's wired after. Untouched when nothing changed.
    ///
    /// This runs while the song plays (a plugin finishing loading, an effect added, removed or dragged), so it
    /// changes only the links that differ and builds new ones before letting go of old ones. Two engine rules
    /// make that matter: cutting a player's path to the output resets the player for good (keepAlive covers
    /// that), and links left in place keep their plugins running without a re-initialise.
    private func wireChain(_ slots: [PluginSlot], current: [UUID], from head: AVAudioMixerNode,
                           to destination: AVAudioMixerNode) -> [UUID] {
        var wanted: [UUID] = []
        for slot in slots {
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
        guard wanted != current else { return current }

        let old = current.compactMap { units[$0] }.filter { $0.engine === engine }
        let new = wanted.compactMap { units[$0] }
        /// What `unit` feeds in `chain`: the next plugin, or the destination after the last; nil if it isn't in it.
        func output(of unit: AVAudioUnit, in chain: [AVAudioUnit]) -> AVAudioNode? {
            guard let i = chain.firstIndex(where: { $0 === unit }) else { return nil }
            return i + 1 < chain.count ? chain[i + 1] : destination
        }
        func connect(_ from: AVAudioNode, to node: AVAudioNode) {
            // A fresh mixer input each time, so the new link never lands on one still in use.
            engine.connect(from, to: node, fromBus: 0, toBus: node === destination ? destination.nextAvailableInputBus : 0,
                           format: stereo)
        }

        // 1. Unhook the plugin outputs that change. Unchanged links stay.
        for unit in old where output(of: unit, in: new) !== output(of: unit, in: old) {
            engine.disconnectNodeOutput(unit)
        }
        for unit in new where unit.engine == nil { engine.attach(unit) }
        let oldFirst: AVAudioNode = old.first ?? destination
        let newFirst: AVAudioNode = new.first ?? destination
        // 2. A plugin moving off the front needs its input freed before something else connects into it.
        let frontFirst = new.dropFirst().contains { $0 === oldFirst }
        if frontFirst { connect(head, to: newFirst) }
        // 3. The new links, built while the old chain still plays.
        for unit in new where output(of: unit, in: old) !== output(of: unit, in: new) {
            connect(unit, to: output(of: unit, in: new)!)
        }
        // 4. Point the head at the new chain in one step.
        if !frontFirst && newFirst !== oldFirst { connect(head, to: newFirst) }
        for unit in old where !new.contains(where: { $0 === unit }) { engine.detach(unit) }
        return wanted
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
                } else {
                    // Not saved yet: the slot's starting settings, if any (the built-in reverb and delay buses).
                    if let number = slot.preset, let preset = unit.auAudioUnit.factoryPresets?.first(where: { $0.number == number }) {
                        unit.auAudioUnit.currentPreset = preset
                    }
                    for (address, value) in slot.params ?? [:] {
                        unit.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(address))?.value = value
                    }
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
                    // Get the plugin ready to render now, not when it's connected: the engine holds up the
                    // audio while it connects a plugin that isn't ready, a gap of 100 ms or more mid-song.
                    unit.auAudioUnit.maximumFramesToRender = AudioEngine.maxRenderFrames
                    try? unit.auAudioUnit.allocateRenderResources()
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

    /// The largest render the engine asks for (realtime and offline).
    static let maxRenderFrames: AUAudioFrameCount = 4096

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
            for (id, bus) in n.sendBuses {
                guard let input = buses[id]?.input else { continue }
                n.strip.destination(forMixer: input, bus: bus)?.volume = Float(s.sends[id] ?? 0)
            }
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
        masterFader.outputVolume = AudioEngine.gain(m.volumeDB)
        limiter.bypass = !m.limiterOn
        setParam(limiter, 2, 0) // pre-gain
        for bus in song.buses {
            buses[bus.id]?.output.outputVolume = bus.mute ? 0 : AudioEngine.gain(bus.returnDB)
        }
        // Apple's delay, synced to the tempo where the slot asks for it.
        let slots = song.buses.flatMap(\.inserts) + song.master.inserts + song.tracks.flatMap(\.inserts)
        for slot in slots where slot.isAppleDelay {
            guard let division = slot.tempoSync,
                  let time = units[slot.id]?.auAudioUnit.parameterTree?.parameter(withAddress: 1) else { continue }
            let wanted = AUValue(min(2, division.beats * song.secondsPerBeat))
            if abs(time.value - wanted) > 0.0001 { time.value = wanted }
        }
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
