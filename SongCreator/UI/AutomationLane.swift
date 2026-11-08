import SwiftUI
import AVFoundation

/// How a lane draws one setting: its range, how a value reads, and its colour.
struct AutoSpec {
    var name: String
    var color: Color
    /// Value → 0...1 up the lane, and back (rounded to something sensible).
    var norm: (Double) -> Double
    var value: (Double) -> Double
    var label: (Double) -> String
    /// Jumps from point to point instead of sliding.
    var step: Bool
    /// A faint line across the lane (0 dB, centre pan).
    var reference: Double?

    static func linear(_ name: String, _ r: ClosedRange<Double>, color: Color, unit: String, digits: Int = 1,
                       reference: Double? = nil) -> AutoSpec {
        let f = 1 / pow(10, Double(digits))
        return AutoSpec(name: name, color: color,
                        norm: { ($0 - r.lowerBound) / (r.upperBound - r.lowerBound) },
                        value: { n in ((r.lowerBound + max(0, min(1, n)) * (r.upperBound - r.lowerBound)) / f).rounded() * f },
                        label: { String(format: "%.\(digits)f", $0) + unit }, step: false, reference: reference)
    }

    static func fader(_ name: String, color: Color) -> AutoSpec {
        AutoSpec(name: name, color: color, norm: Fader.pos, value: { (Fader.db($0) * 10).rounded() / 10 },
                 label: { $0.dbString + " dB" }, step: false, reference: 0)
    }

    static func onOff(_ name: String, color: Color, on: String = "On", off: String = "Off") -> AutoSpec {
        AutoSpec(name: name, color: color, norm: { $0 >= 0.5 ? 0.8 : 0.2 }, value: { $0 >= 0.5 ? 1 : 0 },
                 label: { $0 >= 0.5 ? on : off }, step: true, reference: nil)
    }

    static let pan = AutoSpec(name: "Pan", color: .cyan, norm: { ($0 + 1) / 2 },
                              value: { n in let p = max(-1, min(1, n * 2 - 1)); return abs(p) < 0.03 ? 0 : (p * 100).rounded() / 100 },
                              label: AutomationLane.panString, step: false, reference: 0)

    static let frequency: AutoSpec = {
        let lo = log(200.0), hi = log(6000.0)
        return AutoSpec(name: "EQ Mid Freq", color: .green, norm: { (log(max(200, $0)) - lo) / (hi - lo) },
                        value: { n in exp(lo + max(0, min(1, n)) * (hi - lo)).rounded() },
                        label: { $0 >= 1000 ? String(format: "%.2f kHz", $0 / 1000) : String(format: "%.0f Hz", $0) },
                        step: false, reference: nil)
    }()

    /// A plugin parameter, in its own range and with its own wording.
    static func plugin(_ slot: String, _ p: AUParameter?) -> AutoSpec {
        guard let p, p.maxValue > p.minValue else {
            return linear("\(slot): parameter", 0...1, color: .pink, unit: "", digits: 2)
        }
        let lo = Double(p.minValue), hi = Double(p.maxValue)
        let step = AudioEngine.steps(p)
        return AutoSpec(name: "\(slot): \(p.displayName)", color: .pink,
                        norm: { ($0 - lo) / (hi - lo) },
                        value: { n in
                            let v = lo + max(0, min(1, n)) * (hi - lo)
                            return step ? v.rounded() : v
                        },
                        label: { v in
                            var value = AUValue(v)
                            return p.string(fromValue: &value)
                        },
                        step: step, reference: nil)
    }
}

extension Session {
    func autoSpec(_ owner: UUID, _ target: AutoTarget) -> AutoSpec {
        let busName = { (id: UUID) in self.song.buses.first { $0.id == id }?.name ?? "Bus" }
        let busColor = { (id: UUID) in BusStrip.color(self.song.busIndex(id) ?? 0) }
        let gain = { (name: String) in AutoSpec.linear(name, -12...12, color: .green, unit: " dB", reference: 0) }
        switch target {
        case .volume: return .fader(owner == Song.masterID ? "Master Volume" : "Volume", color: Theme.accent)
        case .pan: return .pan
        case .mute: return .onOff("Mute", color: .orange, on: "Muted", off: "On")
        case .solo: return .onOff("Solo", color: .yellow, on: "Solo", off: "Off")
        case .eqOn: return .onOff("EQ On", color: .green)
        case .hpfOn: return .onOff("Low Cut", color: .green)
        case .lowGain: return gain("EQ Low")
        case .midGain: return gain("EQ Mid")
        case .midFreq: return .frequency
        case .highGain: return gain("EQ High")
        case .compOn: return .onOff("Comp On", color: .purple)
        case .compThreshold: return .linear("Comp Threshold", -40...0, color: .purple, unit: " dB")
        case .compMakeup: return .linear("Comp Gain", 0...20, color: .purple, unit: " dB")
        case .send(let id):
            var s = AutoSpec.linear("Send: \(busName(id))", 0...1, color: busColor(id), unit: "", digits: 2)
            s.label = { String(format: "%.0f%%", $0 * 100) }
            return s
        case .limiterOn: return .onOff("Limiter", color: .red)
        case .busReturn(let id): return .fader("\(busName(id)) Return", color: busColor(id))
        case .busMute(let id): return .onOff("\(busName(id)) Mute", color: .orange, on: "Muted", off: "On")
        case .plugin(let slot, let address):
            let name = allPluginSlots.first { $0.id == slot }?.name ?? "Plugin"
            return .plugin(name, audio.unit(slot)?.auAudioUnit.parameterTree?.parameter(withAddress: address))
        }
    }

    private var allPluginSlots: [PluginSlot] {
        song.tracks.flatMap(\.automatablePlugins) + song.master.inserts + song.buses.flatMap(\.inserts)
    }

    /// The parameters of a loaded plugin that automation can move (nil while it loads).
    func automatableParameters(_ slot: UUID) -> [AUParameter]? {
        guard let tree = audio.unit(slot)?.auAudioUnit.parameterTree else { return nil }
        return Array(tree.allParameters.filter { $0.flags.contains(.flag_IsWritable) }.prefix(500))
    }
}

/// One automation curve under a track or the Master row. Click to add a point, drag to move it, ⌥-click to
/// delete it. The menu at the top left picks which setting the lane shows.
struct AutomationLane: View {
    @Bindable var session: Session
    let owner: UUID
    let index: Int

    @State private var dragging: UUID?
    /// Points created by the current gesture (not yet in the gesture's base song).
    @State private var newPoints: [AutoPoint] = []

    private var auto: Automation { session.automation(owner) }
    private var target: AutoTarget { auto.lanes.indices.contains(index) ? auto.lanes[index] : .volume }
    private var points: [AutoPoint] { auto.points(target) }
    private let pad: CGFloat = 6

    var body: some View {
        let scale = session.scale
        let spec = session.autoSpec(owner, target)
        let staticValue = session.staticValue(owner, target)
        let active = auto.read
        GeometryReader { geo in
            let h = geo.size.height
            let y = { (v: Double) -> CGFloat in self.pad + (1 - CGFloat(max(0, min(1, spec.norm(v))))) * (h - self.pad * 2) }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.3)))
                    LaneDrawing.grid(ctx, size, scale, session.song)
                    if let ref = spec.reference {
                        ctx.fill(Path(CGRect(x: 0, y: y(ref), width: size.width, height: 0.5)), with: .color(Color.white.opacity(0.15)))
                    }
                    let alpha = active ? 1.0 : 0.35
                    if points.isEmpty {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y(staticValue)))
                        p.addLine(to: CGPoint(x: size.width, y: y(staticValue)))
                        ctx.stroke(p, with: .color(spec.color.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        return
                    }
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(points[0].value)))
                    var last = points[0].value
                    for pt in points {
                        let x = scale.x(pt.time)
                        if spec.step { line.addLine(to: CGPoint(x: x, y: y(last))) }
                        line.addLine(to: CGPoint(x: x, y: y(pt.value)))
                        last = pt.value
                    }
                    line.addLine(to: CGPoint(x: size.width, y: y(last)))
                    ctx.stroke(line, with: .color(spec.color.opacity(alpha)), lineWidth: 1.5)
                    for pt in points {
                        let c = CGPoint(x: scale.x(pt.time), y: y(pt.value))
                        guard c.x > -6, c.x < size.width + 6 else { continue }
                        let r = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
                        ctx.fill(Path(ellipseIn: r), with: .color(dragging == pt.id ? .white : spec.color.opacity(alpha)))
                        if dragging == pt.id {
                            ctx.draw(Text(spec.label(pt.value)).font(.system(size: 9, weight: .semibold)).foregroundColor(.white),
                                     at: CGPoint(x: c.x + 8, y: max(8, c.y - 8)), anchor: .leading)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in changed(g, h, scale, spec, staticValue) }
                    .onEnded { _ in
                        if dragging != nil { session.endGesture() }
                        dragging = nil
                        newPoints = []
                    })

                controls(spec)
            }
        }
        .help("Click to add a point, drag to move it, ⌥-click to delete it")
    }

    private func controls(_ spec: AutoSpec) -> some View {
        HStack(spacing: 6) {
            AutoTargetMenu(session: session, owner: owner, index: index, title: spec.name, color: spec.color)
            if index == 0 {
                LitButton(label: "READ", on: auto.read, color: .green, width: 38,
                          help: "Follow this \(owner == Song.masterID ? "row" : "track")'s automation on playback") {
                    session.updateAutomation(owner) { $0.read.toggle() }
                }
            }
            Button("Clear") { session.updateAutomation(owner) { [target] in $0.set(target, []) } }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.dim)
                .disabled(points.isEmpty)
            Button { session.addLane(owner, after: index) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                .help("Show another automation lane")
            if auto.lanes.count > 1 {
                Button { session.removeLane(owner, index) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                    .help("Hide this lane (its automation keeps playing)")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel.opacity(0.85)))
        .padding(4)
    }

    private func changed(_ g: DragGesture.Value, _ h: CGFloat, _ scale: TimeScale, _ spec: AutoSpec, _ staticValue: Double) {
        let owner = self.owner, target = self.target
        func value(_ y: CGFloat) -> Double { spec.value(Double(1 - (y - pad) / (h - pad * 2))) }
        func y(_ v: Double) -> CGFloat { pad + (1 - CGFloat(max(0, min(1, spec.norm(v))))) * (h - pad * 2) }
        if dragging == nil {
            let hitID = points.first { pt in
                hypot(scale.x(pt.time) - g.startLocation.x, y(pt.value) - g.startLocation.y) < 7
            }?.id
            if NSEvent.modifierFlags.contains(.option) {
                if let hitID {
                    session.updateAutomation(owner) { a in a.set(target, a.points(target).filter { $0.id != hitID }) }
                }
                dragging = UUID() // swallow the rest of this gesture
                session.beginGesture()
                return
            }
            session.beginGesture()
            if let hitID {
                dragging = hitID
            } else {
                // New point. If this is the first one, also pin the current static value at the song start.
                let pt = AutoPoint(time: max(0, scale.t(g.startLocation.x)), value: value(g.startLocation.y))
                dragging = pt.id
                newPoints = [pt]
                if points.isEmpty && pt.time > 0.01 { newPoints.insert(AutoPoint(time: 0, value: staticValue), at: 0) }
            }
        }
        guard let moving = dragging else { return }
        let t = max(0, scale.t(g.location.x)), v = value(g.location.y)
        let added = newPoints
        session.previewGesture { s in
            s.updateAutomation(owner) { a in
                var pts = a.points(target) + added
                if let k = pts.firstIndex(where: { $0.id == moving }) {
                    pts[k].time = t
                    pts[k].value = v
                }
                a.set(target, pts)
            }
        }
    }

    static func panString(_ v: Double) -> String {
        v == 0 ? "C" : (v < 0 ? String(format: "L%.0f", -v * 100) : String(format: "R%.0f", v * 100))
    }
}

/// Picks the setting a lane shows: the strip's own settings, sends or buses, and every plugin's parameters.
/// Settings that already have a curve are marked with a dot.
struct AutoTargetMenu: View {
    @Bindable var session: Session
    let owner: UUID
    let index: Int
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            menu
        }
    }

    private var menu: some View {
        Menu {
            let builtIn = session.automationTargets(owner)
            if owner == Song.masterID {
                items(builtIn.filter { $0.bus == nil })
                pluginMenus(session.song.master.inserts)
                if !session.song.buses.isEmpty { Divider() }
                ForEach(session.song.buses) { bus in
                    Menu(bus.name) {
                        items([.busReturn(bus.id), .busMute(bus.id)])
                        pluginMenus(bus.inserts)
                    }
                }
            } else if let track = session.song.tracks.first(where: { $0.id == owner }) {
                items([.volume, .pan, .mute, .solo])
                Menu("EQ") { items([.eqOn, .hpfOn, .lowGain, .midGain, .midFreq, .highGain]) }
                Menu("Compressor") { items([.compOn, .compThreshold, .compMakeup]) }
                if !session.song.buses.isEmpty {
                    Menu("Sends") { items(session.song.buses.map { .send($0.id) }) }
                }
                pluginMenus(track.automatablePlugins)
            }
        } label: {
            Text(title).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .font(.system(size: 10, weight: .semibold))
        .fixedSize()
        .frame(maxWidth: 200, alignment: .leading)
        .help("Pick the setting this lane automates")
    }

    private func label(_ target: AutoTarget, _ name: String) -> String {
        session.automation(owner).curves[target]?.isEmpty == false ? "• \(name)" : name
    }

    @ViewBuilder private func items(_ targets: [AutoTarget]) -> some View {
        ForEach(targets) { t in
            let spec = session.autoSpec(owner, t)
            Button(label(t, menuName(spec.name))) { session.setLane(owner, index, to: t) }
        }
    }

    /// Inside a submenu the group name is already given ("EQ Low" → "Low").
    private func menuName(_ name: String) -> String {
        for prefix in ["EQ ", "Comp ", "Send: "] where name.hasPrefix(prefix) && name != "EQ On" && name != "Comp On" {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    @ViewBuilder private func pluginMenus(_ slots: [PluginSlot]) -> some View {
        if !slots.isEmpty { Divider() }
        ForEach(slots) { slot in
            Menu(slot.name) {
                if let params = session.automatableParameters(slot.id) {
                    if params.isEmpty { Text("No parameters to automate") }
                    ForEach(params, id: \.address) { p in
                        let t = AutoTarget.plugin(slot.id, p.address)
                        Button(label(t, p.displayName)) { session.setLane(owner, index, to: t) }
                    }
                } else {
                    Text(session.audio.pluginErrors[slot.id] != nil ? "Couldn't load" : "Loading…")
                }
            }
        }
    }
}
