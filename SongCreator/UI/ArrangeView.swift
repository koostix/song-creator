import SwiftUI

enum Layout {
    static let headerWidth: CGFloat = 236
    static let rulerHeight: CGFloat = 32
    static let markerHeight: CGFloat = 20
    static let laneHeight: CGFloat = 76
    static let takeHeight: CGFloat = 32
    static let automationHeight: CGFloat = 64
}

/// Time ↔ x conversion for the visible timeline.
struct TimeScale {
    let pps: Double
    let scrollX: Double
    func x(_ t: Double) -> CGFloat { CGFloat((t - scrollX) * pps) }
    func t(_ x: CGFloat) -> Double { Double(x) / pps + scrollX }
}

extension Session {
    var scale: TimeScale { TimeScale(pps: pixelsPerSecond, scrollX: scrollX) }

    /// Snap to the beat grid unless Option is held.
    func snap(_ t: Double) -> Double {
        NSEvent.modifierFlags.contains(.option) ? max(0, t) : max(0, song.snapToBeat(t))
    }
}

struct ArrangeView: View {
    @Bindable var session: Session
    @State private var hovering = false
    @State private var hoverX: CGFloat = 0
    @State private var scrollMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TrackListCorner(session: session)
                    .frame(width: Layout.headerWidth, height: Layout.rulerHeight + Layout.markerHeight)
                GeometryReader { geo in
                    RulerView(session: session)
                        .onAppear { session.timelineWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in session.timelineWidth = w }
                }
                .frame(height: Layout.rulerHeight + Layout.markerHeight)
            }
            .background(Theme.panel)
            Divider().overlay(Color.black)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(session.song.tracks) { track in
                        TrackRow(session: session, track: track)
                        Divider().overlay(Color.black.opacity(0.6))
                    }
                    AddTrackRow(session: session)
                }
            }
            .overlay(alignment: .topLeading) {
                LaneOverlay(session: session, playhead: session.playhead)
                    .padding(.leading, Layout.headerWidth)
                    .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hovering = p.x > Layout.headerWidth
                    hoverX = p.x - Layout.headerWidth
                case .ended:
                    hovering = false
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                session.importAudio(urls)
                return true
            }
        }
        .background(Theme.lane)
        .onAppear(perform: installScroll)
        .onDisappear { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }
    }

    /// Horizontal swipes scroll the timeline; ⌘/⌥ + scroll zooms around the pointer.
    private func installScroll() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { e in
            guard hovering else { return e }
            let s = session
            if e.type == .magnify {
                // Trackpad pinch zooms around the pointer.
                let anchor = s.scale.t(hoverX)
                s.pixelsPerSecond = min(800, max(4, s.pixelsPerSecond * (1 + e.magnification)))
                s.scrollX = max(0, anchor - Double(hoverX) / s.pixelsPerSecond)
                return nil
            }
            let precise = e.hasPreciseScrollingDeltas
            let dx = e.scrollingDeltaX * (precise ? 1 : 12)
            let dy = e.scrollingDeltaY * (precise ? 1 : 12)
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                let anchor = s.scale.t(hoverX)
                let factor = pow(1.01, dy)
                s.pixelsPerSecond = min(800, max(4, s.pixelsPerSecond * factor))
                s.scrollX = max(0, anchor - Double(hoverX) / s.pixelsPerSecond)
                return nil
            }
            if abs(dx) > abs(dy) {
                s.scrollX = max(0, s.scrollX - dx / s.pixelsPerSecond)
                if s.isPlaying { s.followSuspended = true }   // until the next play
                return nil
            }
            return e
        }
    }
}

struct TrackListCorner: View {
    @Bindable var session: Session
    var body: some View {
        HStack(spacing: 8) {
            // Mixer (X) and computer keyboard as MIDI (⌘K), next to the tracks they work on.
            LitButton(label: "MIX", on: session.showMixer, width: 34, help: "Mixer (X)") {
                withAnimation(.easeOut(duration: 0.15)) { session.showMixer.toggle() }
            }
            TypingToggle(session: session)
            Spacer(minLength: 4)
            Button { session.addTrack(kind: .audio) } label: { Image(systemName: "waveform.badge.plus") }
                .help("New audio track (T)")
            Button { session.addTrack(kind: .midi) } label: { Image(systemName: "pianokeys") }
                .help("New MIDI track (⇧T)")
            Button { session.followPlayhead.toggle() } label: {
                Image(systemName: session.followPlayhead ? "arrow.right.to.line.compact" : "arrow.right.to.line")
                    .foregroundStyle(session.followPlayhead ? Theme.accent : Theme.dim)
            }
            .help("Follow playhead")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
    }
}

// MARK: - Ruler and markers

struct RulerView: View {
    @Bindable var session: Session

    /// The two editable ranges in the ruler: loop (yellow, top strip) and punch (pink, bottom strip).
    enum Bar { case loop, punch }
    enum Grab { case new, move, start, end }

    @State private var drag: (bar: Bar, grab: Grab)?
    @State private var rangeAtStart = TimeRange(start: 0, end: 0)
    @State private var moved = false
    @State private var renaming: Marker?
    @State private var renameText = ""

    static let barHeight: CGFloat = 7

    var body: some View {
        let scale = session.scale
        let song = session.song
        VStack(spacing: 0) {
            Canvas { ctx, size in
                drawGridLabels(ctx, size, scale, song)
                if song.loop.isValid {
                    let r = CGRect(x: scale.x(song.loop.start), y: 0,
                                   width: scale.x(song.loop.end) - scale.x(song.loop.start), height: RulerView.barHeight + 2)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2),
                             with: .color(Theme.loop.opacity(song.loopEnabled ? 0.85 : 0.25)))
                }
                if song.punch.isValid {
                    let r = CGRect(x: scale.x(song.punch.start), y: size.height - RulerView.barHeight,
                                   width: scale.x(song.punch.end) - scale.x(song.punch.start), height: RulerView.barHeight)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2),
                             with: .color(Theme.punch.opacity(song.punchEnabled ? 0.85 : 0.25)))
                }
            }
            .frame(height: Layout.rulerHeight)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }
                if case .active(let p) = phase {
                    switch hit(p, scale).grab {
                    case .start, .end: NSCursor.resizeLeftRight.set()
                    case .move: NSCursor.openHand.set()
                    case .new: NSCursor.arrow.set()
                    }
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragChanged(g, scale) }
                .onEnded { g in dragEnded(g, scale) })
            .help("Click to move the playhead, drag to draw a loop. Yellow loop bar (top) and pink punch bar (bottom): "
                  + "drag the edges to resize, drag the middle to move, click to turn it on or off. Drag along the bottom strip to draw a punch range.")

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.15)
                ForEach(session.sortedMarkers) { m in
                    markerFlag(m, scale)
                }
            }
            .frame(height: Layout.markerHeight)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { session.addMarker() }
        }
        .clipped()
    }

    private func range(_ bar: Bar) -> TimeRange { bar == .loop ? session.song.loop : session.song.punch }

    /// Which bar and which part of it a press at `p` grabs. Each strip is a bit taller than its bar so it's easy to hit.
    private func hit(_ p: CGPoint, _ scale: TimeScale) -> (bar: Bar, grab: Grab) {
        let bar: Bar
        if p.y <= RulerView.barHeight + 6 {
            bar = .loop
        } else if p.y >= Layout.rulerHeight - RulerView.barHeight - 4 {
            bar = .punch
        } else {
            return (.loop, .new)          // the middle of the ruler draws loops, like before
        }
        let r = range(bar)
        guard r.isValid else { return (bar, .new) }
        let xs = scale.x(r.start), xe = scale.x(r.end)
        if abs(p.x - xs) < 6 { return (bar, .start) }
        if abs(p.x - xe) < 6 { return (bar, .end) }
        if p.x > xs, p.x < xe { return (bar, .move) }
        return (bar, .new)
    }

    private func dragChanged(_ g: DragGesture.Value, _ scale: TimeScale) {
        if drag == nil {
            drag = hit(g.startLocation, scale)
            rangeAtStart = range(drag!.bar)
            moved = false
            session.beginGesture()
            if drag!.grab == .move { NSCursor.closedHand.set() }
        }
        guard moved || abs(g.translation.width) > 3, let (bar, grab) = drag else { return }
        moved = true
        let dt = Double(g.translation.width) / scale.pps
        let orig = rangeAtStart
        let minLen = session.song.secondsPerBeat
        var r: TimeRange
        switch grab {
        case .new:
            let a = session.snap(scale.t(g.startLocation.x)), b = session.snap(scale.t(g.location.x))
            r = TimeRange(start: min(a, b), end: max(a, b))
        case .move:
            let start = max(0, session.snap(orig.start + dt))
            r = TimeRange(start: start, end: start + orig.length)
        case .start:
            r = TimeRange(start: min(session.snap(orig.start + dt), orig.end - minLen), end: orig.end)
        case .end:
            r = TimeRange(start: orig.start, end: max(session.snap(orig.end + dt), orig.start + minLen))
        }
        session.previewGesture { s in
            if bar == .loop { s.loop = r; s.loopEnabled = true } else { s.punch = r; s.punchEnabled = true }
        }
    }

    private func dragEnded(_ g: DragGesture.Value, _ scale: TimeScale) {
        if !moved, let (bar, grab) = drag {
            if grab == .new {
                session.locate(session.snap(scale.t(g.location.x)))
            } else {
                session.previewGesture { s in
                    if bar == .loop { s.loopEnabled.toggle() } else { s.punchEnabled.toggle() }
                }
            }
        }
        session.endGesture()
        drag = nil
        moved = false
        NSCursor.arrow.set()
    }

    private func markerFlag(_ m: Marker, _ scale: TimeScale) -> some View {
        Text(m.name)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.16)))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.loop).frame(width: 2) }
            .fixedSize()
            .offset(x: scale.x(m.position), y: 2)
            .onTapGesture(count: 2) { session.loopSection(m) }
            .onTapGesture { session.locate(m.position) }
            .help("Click to jump, double-click to loop this section")
            .contextMenu {
                Button("Loop This Section") { session.loopSection(m) }
                Button("Punch This Section") { session.edit { $0.punch = session.sectionRange(m); $0.punchEnabled = true } }
                Button("Select This Section") { session.selection = session.sectionRange(m) }
                Button("Rename…") { renameText = m.name; renaming = m }
                Menu("Rename To") {
                    ForEach(Session.sectionNames, id: \.self) { n in
                        Button(n) { session.edit { s in if let i = s.markers.firstIndex(where: { $0.id == m.id }) { s.markers[i].name = n } } }
                    }
                }
                Divider()
                Button("Delete Marker") { session.edit { $0.markers.removeAll { $0.id == m.id } } }
            }
            .popover(isPresented: Binding(get: { renaming?.id == m.id }, set: { if !$0 { renaming = nil } })) {
                TextField("Section name", text: $renameText)
                    .frame(width: 180).padding()
                    .onSubmit {
                        session.edit { s in if let i = s.markers.firstIndex(where: { $0.id == m.id }) { s.markers[i].name = renameText } }
                        renaming = nil
                    }
            }
    }

    private func drawGridLabels(_ ctx: GraphicsContext, _ size: CGSize, _ scale: TimeScale, _ song: Song) {
        let bar = song.secondsPerBar
        let barPx = bar * scale.pps
        let every = max(1, Int(ceil(48 / barPx)))
        let first = max(0, Int(floor(scale.scrollX / bar)))
        let last = Int(ceil(scale.t(size.width) / bar))
        guard last >= first else { return }
        for b in first...last {
            let x = scale.x(Double(b) * bar)
            let major = b % every == 0
            var p = Path()
            p.move(to: CGPoint(x: x, y: major ? 10 : 18))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(major ? Theme.dim : Theme.grid), lineWidth: 1)
            if major {
                ctx.draw(Text("\(b + 1)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.dim), at: CGPoint(x: x + 3, y: 16), anchor: .leading)
            }
        }
    }
}

// MARK: - Overlays (playhead, loop, punch, selection)

struct LaneOverlay: View {
    let session: Session
    let playhead: PlayheadModel

    var body: some View {
        let scale = session.scale
        let song = session.song
        Canvas { ctx, size in
            if song.loopEnabled, song.loop.isValid {
                let r = CGRect(x: scale.x(song.loop.start), y: 0, width: scale.x(song.loop.end) - scale.x(song.loop.start), height: size.height)
                ctx.fill(Path(r), with: .color(Theme.loop.opacity(0.05)))
            }
            if song.punchEnabled, song.punch.isValid {
                for t in [song.punch.start, song.punch.end] {
                    ctx.fill(Path(CGRect(x: scale.x(t), y: 0, width: 1, height: size.height)), with: .color(Theme.punch.opacity(0.6)))
                }
            }
            if let sel = session.selection {
                let r = CGRect(x: scale.x(sel.start), y: 0, width: scale.x(sel.end) - scale.x(sel.start), height: size.height)
                ctx.fill(Path(r), with: .color(Color.white.opacity(0.07)))
                ctx.stroke(Path(r), with: .color(Color.white.opacity(0.25)), lineWidth: 1)
            }
            let x = scale.x(playhead.position)
            if x >= 0 && x <= size.width {
                ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)),
                         with: .color(session.isRecording ? Theme.record : Color.white.opacity(0.9)))
            }
        }
    }
}

// MARK: - Track rows

struct TrackRow: View {
    @Bindable var session: Session
    let track: Track

    var body: some View {
        HStack(spacing: 0) {
            TrackHeader(session: session, track: track)
                .frame(width: Layout.headerWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 0) {
                MainLane(session: session, track: track)
                    .frame(height: Layout.laneHeight)
                if track.showTakes {
                    ForEach(track.takes.reversed()) { take in
                        TakeLane(session: session, track: track, take: take)
                            .frame(height: Layout.takeHeight)
                    }
                }
                if track.showAutomation {
                    AutomationLane(session: session, track: track)
                        .frame(height: Layout.automationHeight)
                }
            }
        }
        .background(session.selectedTrackID == track.id ? Color.white.opacity(0.035) : Color.clear)
    }
}

struct AddTrackRow: View {
    let session: Session
    var body: some View {
        HStack(spacing: 12) {
            Button { session.addTrack(kind: .audio) } label: { Label("Audio Track", systemImage: "plus") }
            Button { session.addTrack(kind: .midi) } label: { Label("MIDI Track", systemImage: "plus") }
            Button { NotificationCenter.default.post(name: .importAudio, object: nil) } label: {
                Label("Import Audio…", systemImage: "square.and.arrow.down")
            }
            Spacer()
            Text("Drop audio files here to import them as new tracks").font(.caption).foregroundStyle(Theme.dim)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.dim)
        .padding(12)
    }
}

/// The comped result: what you hear. Regions can be moved, trimmed, faded and selected here.
struct MainLane: View {
    @Bindable var session: Session
    let track: Track

    enum DragKind: Equatable {
        case select, move(UUID), trimStart(UUID), trimEnd(UUID), fadeIn(UUID), fadeOut(UUID)
    }

    @State private var drag: DragKind?
    @State private var original: CompSegment?
    @State private var moved = false

    var body: some View {
        let scale = session.scale
        let color = Theme.color(track.colorIndex)
        ZStack {
            Canvas { ctx, size in
                LaneDrawing.grid(ctx, size, scale, session.song)
                for seg in track.comp {
                    guard let take = track.take(seg.takeID) else { continue }
                    let x0 = scale.x(seg.start), x1 = scale.x(seg.end)
                    guard x1 > 0, x0 < size.width else { continue }
                    let selected = session.selectedRegions.contains(seg.id)
                    let rect = CGRect(x: x0, y: 3, width: max(1, x1 - x0), height: size.height - 6)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(track.mute ? 0.08 : (selected ? 0.38 : 0.22))))
                    LaneDrawing.content(ctx, rect: rect, take: take, offset: seg.offset, from: seg.start, to: seg.end, scale: scale,
                                        session: session, color: color.opacity(track.mute ? 0.35 : 0.95), quantize: track.quantize)
                    LaneDrawing.fades(ctx, rect: rect, seg: seg, scale: scale)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 4),
                               with: .color(selected ? Color.white : color.opacity(0.5)), lineWidth: selected ? 1.5 : 1)
                    if x1 - x0 > 50 && track.takes.count > 1 {
                        ctx.draw(Text(take.name).font(.system(size: 9, weight: .semibold)).foregroundColor(color),
                                 at: CGPoint(x: max(x0, 0) + 8, y: 20), anchor: .leading)
                    }
                }
            }
            if session.isRecording && track.armed {
                LiveRecording(session: session, track: track)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard drag == nil else { return }
            switch phase {
            case .active(let p):
                switch hit(p) {
                case .trimStart, .trimEnd: NSCursor.resizeLeftRight.set()
                case .fadeIn, .fadeOut: NSCursor.crosshair.set()
                case .move: NSCursor.openHand.set()
                default: NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in changed(g, scale) }
            .onEnded { g in ended(g, scale) })
        .contextMenu {
            Button(track.showTakes ? "Hide Takes" : "Show Takes") { session.updateTrack(track.id, undoable: false) { $0.showTakes.toggle() } }
                .disabled(track.takes.isEmpty)
            Button(track.showAutomation ? "Hide Automation" : "Show Automation") {
                session.updateTrack(track.id, undoable: false) { $0.showAutomation.toggle() }
            }
            Divider()
            Button("Split at Playhead (B)") { session.selectedTrackID = track.id; session.splitAtPlayhead() }
            Button("Copy (⌘C)") { session.selectedTrackID = track.id; session.copyRegions() }
            Button("Paste at Playhead (⌘V)") { session.selectedTrackID = track.id; session.pasteRegions() }
                .disabled(session.clipboard == nil)
            Button("Duplicate (⌘D)") { session.selectedTrackID = track.id; session.duplicateRegions() }
            Button("Delete Selected Regions") { session.deleteSelection() }.disabled(session.selectedRegions.isEmpty)
            if session.selection != nil {
                Divider()
                Button("Loop Selection") { session.loopSelection() }
                Button("Punch Selection") { session.punchSelection() }
                Button("Silence Selection on This Track") {
                    session.selectedRegions = []
                    session.selectedTrackID = track.id
                    session.deleteSelection()
                }
            }
        }
    }

    /// What a press at `p` would grab.
    private func hit(_ p: CGPoint) -> DragKind? {
        let scale = session.scale
        for seg in track.comp.reversed() {
            let x0 = scale.x(seg.start), x1 = scale.x(seg.end)
            guard p.x >= x0 - 5, p.x <= x1 + 5 else { continue }
            if p.y < 16 {
                let fi = x0 + CGFloat(seg.fadeIn * scale.pps), fo = x1 - CGFloat(seg.fadeOut * scale.pps)
                if abs(p.x - fi) < 7 { return .fadeIn(seg.id) }
                if abs(p.x - fo) < 7 { return .fadeOut(seg.id) }
            }
            if abs(p.x - x0) < 6 { return .trimStart(seg.id) }
            if abs(p.x - x1) < 6 { return .trimEnd(seg.id) }
            if p.x >= x0, p.x <= x1 { return .move(seg.id) }
        }
        return nil
    }

    private func regionID(_ k: DragKind) -> UUID? {
        switch k {
        case .select: return nil
        case .move(let id), .trimStart(let id), .trimEnd(let id), .fadeIn(let id), .fadeOut(let id): return id
        }
    }

    private func changed(_ g: DragGesture.Value, _ scale: TimeScale) {
        if drag == nil {
            let kind = hit(g.startLocation) ?? .select
            drag = kind
            moved = false
            session.selectedTrackID = track.id
            if let id = regionID(kind) {
                original = track.segment(id)
                if NSEvent.modifierFlags.contains(.shift) {
                    session.selectedRegions.formSymmetricDifference([id])
                } else if !session.selectedRegions.contains(id) {
                    session.selectedRegions = [id]
                }
                session.beginGesture()
                if case .move = kind { NSCursor.closedHand.set() }
            }
        }
        guard abs(g.translation.width) > 3 || moved else { return }
        moved = true
        let dt = Double(g.translation.width) / scale.pps
        guard let kind = drag else { return }
        if kind == .select {
            let a = session.snap(scale.t(g.startLocation.x)), b = session.snap(scale.t(g.location.x))
            session.selection = a == b ? nil : TimeRange(start: min(a, b), end: max(a, b))
            return
        }
        guard let o = original, let ti = session.song.trackIndex(track.id) else { return }
        session.previewGesture { s in
            switch kind {
            case .move(let id): s.tracks[ti].moveSegment(id, by: session.snapBar(o.start + dt) - o.start)
            case .trimStart(let id): s.tracks[ti].trimSegment(id, start: session.snapBar(o.start + dt))
            case .trimEnd(let id): s.tracks[ti].trimSegment(id, end: session.snapBar(o.end + dt))
            case .fadeIn(let id): s.tracks[ti].setFades(id, fadeIn: o.fadeIn + dt)
            case .fadeOut(let id): s.tracks[ti].setFades(id, fadeOut: o.fadeOut - dt)
            case .select: break
            }
        }
    }

    private func ended(_ g: DragGesture.Value, _ scale: TimeScale) {
        if drag == .select || drag == nil {
            if !moved {
                session.selection = nil
                session.selectedRegions = []
                session.locate(session.snap(scale.t(g.location.x)))
            }
        } else {
            session.endGesture()
            NSCursor.arrow.set()
        }
        drag = nil
        original = nil
        moved = false
    }
}

/// One recorded pass. Drag across it to make that part of the comp; click to use it whole.
struct TakeLane: View {
    @Bindable var session: Session
    let track: Track
    let take: Take
    @State private var swipe: TimeRange?

    var body: some View {
        let scale = session.scale
        let color = Theme.color(track.colorIndex)
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.22)))
            let x0 = scale.x(take.start), x1 = scale.x(take.start + take.duration)
            guard x1 > 0, x0 < size.width else { return }
            let rect = CGRect(x: x0, y: 2, width: max(1, x1 - x0), height: size.height - 4)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.white.opacity(0.04)))
            LaneDrawing.content(ctx, rect: rect, take: take, offset: 0, from: take.start, to: take.start + take.duration,
                                scale: scale, session: session, color: Color.white.opacity(0.25))
            // Highlight the parts of this take that are in the comp (where that material came from).
            for seg in track.comp where seg.takeID == take.id {
                let a = seg.start - seg.offset, b = seg.end - seg.offset
                let r = CGRect(x: scale.x(a), y: 2, width: scale.x(b) - scale.x(a), height: size.height - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(0.3)))
                LaneDrawing.content(ctx, rect: r, take: take, offset: 0, from: a, to: b,
                                    scale: scale, session: session, color: color)
            }
            if let swipe {
                let r = CGRect(x: scale.x(swipe.start), y: 1, width: scale.x(swipe.end) - scale.x(swipe.start), height: size.height - 2)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
            }
            ctx.draw(Text(take.name).font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim),
                     at: CGPoint(x: max(x0, 0) + 5, y: size.height / 2), anchor: .leading)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard abs(g.translation.width) > 3 else { return }
                let a = session.snap(scale.t(g.startLocation.x)), b = session.snap(scale.t(g.location.x))
                swipe = TimeRange(start: min(a, b), end: max(a, b)).clamped(to: take.range)
            }
            .onEnded { _ in
                if let swipe {
                    session.comp(track: track.id, take: take.id, range: swipe)
                } else {
                    session.useWholeTake(track: track.id, take: take.id)
                }
                swipe = nil
            })
        .help("\(take.name): drag across to comp this part in, click to use the whole take")
        .contextMenu {
            Button("Use Whole Take") { session.useWholeTake(track: track.id, take: take.id) }
            Button("Delete Take") { session.deleteTake(track: track.id, take: take.id) }
        }
    }
}

/// Redraws the growing take at 30 fps while recording.
struct LiveRecording: View {
    let session: Session
    let track: Track

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            Canvas { ctx, size in
                guard let live = session.livePeaks(for: track.id) else { return }
                let scale = session.scale
                let x0 = scale.x(live.songStart)
                let x1 = scale.x(live.songStart + Double(live.peaks.count) * live.step)
                let rect = CGRect(x: x0, y: 3, width: max(1, x1 - x0), height: size.height - 6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.record.opacity(0.25)))
                let mid = size.height / 2, h = size.height / 2 - 5
                var path = Path()
                let peaks = live.peaks
                let perPx = max(1, Int(1 / (live.step * scale.pps)))
                // Only what's on screen, so long takes stay cheap to draw.
                var i = max(0, Int((scale.t(0) - live.songStart) / live.step)) / perPx * perPx
                let last = min(peaks.count, Int((scale.t(size.width) - live.songStart) / live.step) + perPx)
                while i < last {
                    let from = peaks.startIndex + i
                    let p = peaks[from..<min(peaks.endIndex, from + perPx)].max() ?? 0
                    let x = scale.x(live.songStart + Double(i) * live.step)
                    let v = CGFloat(pow(Double(min(1, p)), 0.7)) * h
                    path.move(to: CGPoint(x: x, y: mid - v))
                    path.addLine(to: CGPoint(x: x, y: mid + v))
                    i += perPx
                }
                ctx.stroke(path, with: .color(Theme.record), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

enum LaneDrawing {
    static func grid(_ ctx: GraphicsContext, _ size: CGSize, _ scale: TimeScale, _ song: Song) {
        let beat = song.secondsPerBeat
        let beatPx = beat * scale.pps
        let first = max(0, Int(floor(scale.scrollX / beat)))
        let last = Int(ceil(scale.t(size.width) / beat))
        guard last >= first else { return }
        let drawBeats = beatPx > 10
        for b in first...last {
            let isBar = b % song.beatsPerBar == 0
            if !isBar && !drawBeats { continue }
            let x = scale.x(Double(b) * beat)
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(isBar ? Theme.gridBar : Theme.grid))
        }
    }

    /// Waveform (audio) or note bars (MIDI) for the part of `take` between song times `from` and `to`.
    /// Fade curves and their drag handles.
    static func fades(_ ctx: GraphicsContext, rect: CGRect, seg: CompSegment, scale: TimeScale) {
        let shade = Color.black.opacity(0.35)
        if seg.fadeIn > 0 {
            let w = CGFloat(seg.fadeIn * scale.pps)
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.minX + w * 0.15, y: rect.minY + 4))
            p.closeSubpath()
            ctx.fill(p, with: .color(shade))
        }
        if seg.fadeOut > 0 {
            let w = CGFloat(seg.fadeOut * scale.pps)
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - w, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX - w * 0.15, y: rect.minY + 4))
            p.closeSubpath()
            ctx.fill(p, with: .color(shade))
        }
        if rect.width > 24 {
            for x in [rect.minX + CGFloat(seg.fadeIn * scale.pps), rect.maxX - CGFloat(seg.fadeOut * scale.pps)] {
                ctx.fill(Path(CGRect(x: x - 3, y: rect.minY, width: 6, height: 6)), with: .color(Color.white.opacity(0.7)))
            }
        }
    }

    static func content(_ ctx: GraphicsContext, rect: CGRect, take: Take, offset: Double, from: Double, to: Double,
                        scale: TimeScale, session: Session, color: Color, quantize: Quantize? = nil) {
        let visible = rect.intersection(CGRect(x: 0, y: rect.minY, width: session.timelineWidth, height: rect.height))
        guard !visible.isEmpty else { return }
        if let file = take.fileName {
            guard let peaks = session.waveforms.peaks[file], !peaks.isEmpty else { return }
            let sr = session.song.sampleRate > 0 ? session.song.sampleRate : session.sampleRate
            let framesPerPeak = Double(Recorder.peakFrames)
            let mid = rect.midY, h = rect.height / 2 - 2
            var path = Path()
            var x = visible.minX
            while x < visible.maxX {
                let t0 = scale.t(x), t1 = scale.t(x + 1)
                let f0 = (t0 - take.start - offset + take.fileOffset) * sr / framesPerPeak
                let f1 = (t1 - take.start - offset + take.fileOffset) * sr / framesPerPeak
                let i0 = max(0, Int(f0)), i1 = min(peaks.count, max(i0 + 1, Int(ceil(f1))))
                if i0 < i1 {
                    var p: Float = 0
                    for i in i0..<i1 { p = max(p, peaks[i]) }
                    let v = CGFloat(pow(Double(min(1, p)), 0.7)) * h
                    path.move(to: CGPoint(x: x, y: mid - max(0.5, v)))
                    path.addLine(to: CGPoint(x: x, y: mid + max(0.5, v)))
                }
                x += 1
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        } else if !take.notes.isEmpty {
            let pitches = take.notes.map { Int($0.pitch) }
            let lo = (pitches.min() ?? 60) - 2, hi = (pitches.max() ?? 72) + 2
            let rowH = max(1.5, min(5, (rect.height - 8) / CGFloat(hi - lo)))
            for n in take.notes {
                let played = take.start + offset + n.start
                guard played >= from, played < to else { continue }
                let s = quantize?.apply(played, secondsPerBeat: session.song.secondsPerBeat) ?? played
                let e = min(s + n.duration, to)
                guard e > from else { continue }
                let y = rect.maxY - 4 - CGFloat(Int(n.pitch) - lo) * (rect.height - 8) / CGFloat(hi - lo)
                let r = CGRect(x: scale.x(s), y: y - rowH / 2, width: max(2, scale.x(e) - scale.x(s)), height: rowH)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(color))
            }
        }
    }
}
