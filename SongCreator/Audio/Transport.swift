import AVFoundation

/// What the transport should do when it starts.
struct PlayRequest {
    var song: Song
    /// Song position where playback (or recording) proper begins.
    var position: Double
    /// Seconds of count-in before `position`.
    var countIn: Double = 0
    var recording = false
    var loop: TimeRange?
    var includeClick = true
}

/// Streams the arrangement to the engine's player nodes in small chunks just
/// ahead of the playhead. All mutable state lives on `queue`.
final class Transport {
    let audio: AudioEngine
    let queue = DispatchQueue(label: "songcreator.transport", qos: .userInteractive)

    private var renderer: ChunkRenderer
    private var timer: DispatchSourceTimer?
    private var autoTimer: DispatchSourceTimer?

    // Queue-confined state
    private var song: Song
    private var request: PlayRequest?
    private var map = TimelineMap(sampleRate: 48000, startTime: 0, loop: nil)
    private var scheduledUntil: Int64 = 0
    private var midiBase: Int64?
    /// Host time of player frame 0 during realtime playback (nil offline): external MIDI is timestamped from it.
    private var runAnchor: UInt64?
    private var countInFrames: (start: Int64, end: Int64) = (0, 0)

    private let chunkFrames: Int64 = 4096
    private let lookahead = 0.3

    // Read from the main thread (written once per start under lock).
    private let lock = NSLock()
    private var _anchorHost: UInt64 = 0
    private var _map: TimelineMap?

    init(audio: AudioEngine, audioFolder: URL, song: Song) {
        self.audio = audio
        self.song = song
        self.renderer = ChunkRenderer(sampleRate: audio.sampleRate, audioFolder: audioFolder)
    }

    /// Call after the engine is rebuilt (sample rate may have changed).
    func engineRebuilt(audioFolder: URL) {
        queue.sync {
            renderer = ChunkRenderer(sampleRate: audio.sampleRate, audioFolder: audioFolder)
        }
    }

    func update(song: Song) {
        queue.async { self.song = song }
    }

    func fileChanged(_ name: String) {
        queue.async { self.renderer.forget(file: name) }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _map != nil }

    /// Host time of player frame 0 and the active timeline, if running.
    var timing: (anchorHost: UInt64, map: TimelineMap)? {
        lock.lock(); defer { lock.unlock() }
        guard let m = _map else { return nil }
        return (_anchorHost, m)
    }

    /// Current song position, as heard (compensated for output latency).
    func currentPosition() -> Double? {
        guard let t = timing else { return nil }
        let outLatency = audio.outputLatency
        let playerTime = HostTime.seconds(HostTime.now &- min(HostTime.now, t.anchorHost)) - outLatency
        guard HostTime.now >= t.anchorHost else { return t.map.songTime(atPlayerTime: 0) }
        return t.map.songTime(atPlayerTime: max(0, playerTime))
    }

    // MARK: - Realtime playback

    /// Start playback. Returns the host time at which player frame 0 sounds.
    @discardableResult
    func start(_ req: PlayRequest) -> UInt64 {
        stop()
        return queue.sync { () -> UInt64 in
            prepare(req)
            let anchor = HostTime.now + HostTime.ticks(0.12)
            // The render sample that plays at the anchor: MIDI is scheduled against it, and with the app's own
            // hardware connection (whose engine times carry no host time) so are the players.
            midiBase = audio.renderSample(atHost: anchor)
            runAnchor = anchor
            fill(throughPlayerFrame: Int64(lookahead * audio.sampleRate))

            let when = audio.usesOwnIO
                ? AVAudioTime(sampleTime: midiBase ?? 0, atRate: audio.sampleRate)
                : AVAudioTime(hostTime: anchor)
            for n in audio.tracks.values { n.player?.play(at: when) }
            audio.clickPlayer.play(at: when)

            lock.lock(); _anchorHost = anchor; _map = map; lock.unlock()

            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick(anchor: anchor) }
            t.resume()
            timer = t

            if song.tracks.contains(where: \.hasAutomation) {
                let a = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
                a.schedule(deadline: .now(), repeating: 0.005, leeway: .milliseconds(1))
                a.setEventHandler { [weak self] in self?.automationTick(anchor: anchor) }
                a.resume()
                autoTimer = a
            }
            return anchor
        }
    }

    func stop() {
        let externals = queue.sync { () -> [ExternalMIDI] in
            timer?.cancel()
            timer = nil
            autoTimer?.cancel()
            autoTimer = nil
            request = nil
            runAnchor = nil
            lock.lock(); _map = nil; lock.unlock()
            return song.tracks.compactMap(\.external)
        }
        // Outboard gear: drop notes already queued with Core MIDI and turn everything off.
        for ext in externals { MIDIOutput.shared.silence(device: ext.deviceID, channel: ext.channel) }
        for n in audio.tracks.values {
            n.player?.stop()
            n.instrument?.reset()
        }
        audio.clickPlayer.stop()
        audio.allNotesOff()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [audio] in audio.allNotesOff() }
    }

    private func tick(anchor: UInt64) {
        let now = HostTime.now
        guard now >= anchor else { return }
        let played = Int64(HostTime.seconds(now - anchor) * audio.sampleRate)
        fill(throughPlayerFrame: played + Int64(lookahead * audio.sampleRate))
    }

    /// Follows automation at the position being rendered right now (not yet heard).
    private func automationTick(anchor: UInt64) {
        let now = HostTime.now
        let t = now >= anchor ? HostTime.seconds(now - anchor) : 0
        audio.applyAutomation(song, at: map.songTime(atPlayerTime: t))
    }

    // MARK: - Shared with offline export

    /// Set up the timeline for a run. Queue-confined (or exclusive offline use).
    func prepare(_ req: PlayRequest) {
        request = req
        runAnchor = nil
        song = req.song
        let sr = audio.sampleRate
        map = TimelineMap(sampleRate: sr, startTime: req.position - req.countIn, loop: req.loop)
        scheduledUntil = 0
        countInFrames = (map.startFrame, Int64((req.position * sr).rounded()))
        for n in audio.tracks.values { n.player?.stop() }
        audio.clickPlayer.stop()
    }

    /// For offline rendering: MIDI events are timed against the manual render clock.
    func setMIDIBase(_ base: Int64?) { midiBase = base }

    func fill(throughPlayerFrame target: Int64) {
        guard let req = request else { return }
        while scheduledUntil < target {
            scheduleChunk(start: scheduledUntil, req: req)
            scheduledUntil += chunkFrames
        }
    }

    private func scheduleChunk(start: Int64, req: PlayRequest) {
        let pieces = map.pieces(playerStart: start, count: chunkFrames)
        let when = AVAudioTime(sampleTime: start, atRate: audio.sampleRate)

        for track in song.tracks {
            guard let nodes = audio.tracks[track.id] else { continue }
            switch track.kind {
            case .audio:
                guard let player = nodes.player, !track.comp.isEmpty else { continue }
                let buf = Transport.silentBuffer(nodes.format, chunkFrames)
                var any = false
                for p in pieces where p.songStart + p.length > 0 {
                    any = renderer.renderTrack(track, songStart: p.songStart, count: p.length,
                                               into: buf, outOffset: p.playerStart - start) || any
                }
                if any { player.scheduleBuffer(buf, at: when) }
            case .midi:
                scheduleMIDI(track, nodes: nodes, pieces: pieces)
            }
        }

        if req.includeClick {
            let clickOn = song.clickEnabled && (!song.clickOnlyWhileRecording || req.recording)
            let buf = Transport.silentBuffer(audio.clickFormat, chunkFrames)
            var any = false
            for p in pieces {
                var from = p.songStart, to = p.songStart + p.length
                if !clickOn {
                    // Count-in clicks only.
                    from = max(from, countInFrames.start)
                    to = min(to, countInFrames.end)
                }
                guard to > from else { continue }
                any = renderer.renderClick(tempo: song.tempo, beatsPerBar: song.beatsPerBar,
                                           volume: 1, songStart: from, count: to - from,
                                           into: buf, outOffset: p.playerStart - start + (from - p.songStart)) || any
            }
            if any { audio.clickPlayer.scheduleBuffer(buf, at: when) }
        }
    }

    private func scheduleMIDI(_ track: Track, nodes: TrackNodes, pieces: [TimelinePiece]) {
        let sr = audio.sampleRate
        let external = track.external
        // External gear plays live only (it can't be rendered offline), timestamped against the hardware clock.
        if external != nil && runAnchor == nil { return }
        let send = external == nil ? nodes.instrument?.auAudioUnit.scheduleMIDIEventBlock : nil
        if external == nil && send == nil { return }
        let loopEnd = map.loop.map { Double($0.end) / sr }
        for p in pieces {
            let a = Double(p.songStart) / sr, b = Double(p.songStart + p.length) / sr
            for seg in track.comp where seg.end > a && seg.start <= b {
                guard let take = track.take(seg.takeID) else { continue }
                for note in take.notes {
                    let on = take.start + seg.offset + note.start
                    var off = min(on + note.duration, seg.end)
                    if let loopEnd { off = min(off, loopEnd) }
                    if on >= seg.start, on < seg.end, on >= a, on < b {
                        emit(p, on, [0x90, note.pitch, note.velocity])
                    }
                    if on >= seg.start, on < seg.end, off > a, off <= b {
                        emit(p, off, [0x80, note.pitch, 0])
                    }
                }
            }
        }

        func emit(_ p: TimelinePiece, _ songTime: Double, _ bytes: [UInt8]) {
            let playerFrame = p.playerStart + Int64((songTime * sr).rounded()) - p.songStart
            if let ext = external, let anchor = runAnchor {
                // Due when the rest of the song is heard (output latency), minus the gear's own delay.
                let offset = Double(playerFrame) / sr + audio.outputLatency - ext.latencyMs / 1000
                let host = offset >= 0 ? anchor + HostTime.ticks(offset) : anchor &- HostTime.ticks(-offset)
                MIDIOutput.shared.send(bytes[0], bytes[1], bytes[2], to: ext.deviceID, channel: ext.channel, at: host)
                return
            }
            guard let send else { return }
            let time: AUEventSampleTime
            if let base = midiBase {
                time = AUEventSampleTime(base + playerFrame)
            } else {
                time = AUEventSampleTimeImmediate
            }
            bytes.withUnsafeBufferPointer { send(time, 0, 3, $0.baseAddress!) }
        }
    }

    static func silentBuffer(_ format: AVAudioFormat, _ frames: Int64) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        if let d = buf.floatChannelData {
            for c in 0..<Int(format.channelCount) { memset(d[c], 0, Int(frames) * MemoryLayout<Float>.size) }
        }
        return buf
    }
}
