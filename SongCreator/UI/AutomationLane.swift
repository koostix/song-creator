import SwiftUI

/// Volume or pan curve under a track. Click to add a point, drag to move it, ⌥-click to delete it.
struct AutomationLane: View {
    @Bindable var session: Session
    let track: Track

    @State private var dragging: UUID?
    /// Points created by the current gesture (not yet in the gesture's base song).
    @State private var newPoints: [AutoPoint] = []

    private var param: AutoParam { track.autoParam }
    private var points: [AutoPoint] { track.points(param) }
    private let pad: CGFloat = 6

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let n = param == .volume ? Fader.pos(v) : (v + 1) / 2
        return pad + (1 - CGFloat(n)) * (h - pad * 2)
    }

    private func value(_ y: CGFloat, _ h: CGFloat) -> Double {
        let n = Double(1 - (y - pad) / (h - pad * 2))
        if param == .volume { return (Fader.db(n) * 10).rounded() / 10 }
        let p = max(-1, min(1, n * 2 - 1))
        return abs(p) < 0.03 ? 0 : (p * 100).rounded() / 100
    }

    private var staticValue: Double { param == .volume ? track.strip.volumeDB : track.strip.pan }
    private var color: Color { param == .volume ? Theme.accent : Color.cyan }

    var body: some View {
        let scale = session.scale
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.3)))
                    LaneDrawing.grid(ctx, size, scale, session.song)
                    let ref = y(param == .volume ? 0 : 0, h)
                    ctx.fill(Path(CGRect(x: 0, y: ref, width: size.width, height: 0.5)), with: .color(Color.white.opacity(0.15)))
                    let active = track.autoRead ? 1.0 : 0.35
                    if points.isEmpty {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y(staticValue, h)))
                        p.addLine(to: CGPoint(x: size.width, y: y(staticValue, h)))
                        ctx.stroke(p, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        return
                    }
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(points[0].value, h)))
                    for pt in points { line.addLine(to: CGPoint(x: scale.x(pt.time), y: y(pt.value, h))) }
                    line.addLine(to: CGPoint(x: size.width, y: y(points.last!.value, h)))
                    ctx.stroke(line, with: .color(color.opacity(active)), lineWidth: 1.5)
                    for pt in points {
                        let c = CGPoint(x: scale.x(pt.time), y: y(pt.value, h))
                        guard c.x > -6, c.x < size.width + 6 else { continue }
                        let r = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
                        ctx.fill(Path(ellipseIn: r), with: .color(dragging == pt.id ? .white : color.opacity(active)))
                        if dragging == pt.id {
                            let label = param == .volume ? pt.value.dbString + " dB" : AutomationLane.panString(pt.value)
                            ctx.draw(Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(.white),
                                     at: CGPoint(x: c.x + 8, y: max(8, c.y - 8)), anchor: .leading)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in changed(g, h, scale) }
                    .onEnded { _ in
                        if dragging != nil { session.endGesture() }
                        dragging = nil
                        newPoints = []
                    })

                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { track.autoParam },
                                                  set: { v in session.updateTrack(track.id, undoable: false) { $0.autoParam = v } })) {
                        ForEach(AutoParam.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120).controlSize(.mini)
                    LitButton(label: "READ", on: track.autoRead, color: .green, width: 38,
                              help: "Follow this track's automation on playback") {
                        session.updateTrack(track.id) { $0.autoRead.toggle() }
                    }
                    Button("Clear") {
                        session.updateTrack(track.id) { t in
                            if t.autoParam == .volume { t.volumeAuto = [] } else { t.panAuto = [] }
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.dim)
                    .disabled(points.isEmpty)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel.opacity(0.85)))
                .padding(4)
            }
        }
        .help("Click to add a point, drag to move it, ⌥-click to delete it")
    }

    private func changed(_ g: DragGesture.Value, _ h: CGFloat, _ scale: TimeScale) {
        let id = track.id, param = self.param
        if dragging == nil {
            let hitID = points.first { pt in
                hypot(scale.x(pt.time) - g.startLocation.x, y(pt.value, h) - g.startLocation.y) < 7
            }?.id
            if NSEvent.modifierFlags.contains(.option) {
                if let hitID {
                    session.updateTrack(id) { t in
                        if param == .volume { t.volumeAuto.removeAll { $0.id == hitID } } else { t.panAuto.removeAll { $0.id == hitID } }
                    }
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
                let pt = AutoPoint(time: max(0, scale.t(g.startLocation.x)), value: value(g.startLocation.y, h))
                dragging = pt.id
                newPoints = [pt]
                if points.isEmpty && pt.time > 0.01 { newPoints.insert(AutoPoint(time: 0, value: staticValue), at: 0) }
            }
        }
        guard let target = dragging else { return }
        let t = max(0, scale.t(g.location.x)), v = value(g.location.y, h)
        let added = newPoints
        session.previewGesture { s in
            guard let i = s.trackIndex(id) else { return }
            AutomationLane.mutate(&s.tracks[i], param) { pts in
                pts += added
                if let k = pts.firstIndex(where: { $0.id == target }) {
                    pts[k].time = t
                    pts[k].value = v
                }
            }
        }
    }

    static func mutate(_ track: inout Track, _ param: AutoParam, _ change: (inout [AutoPoint]) -> Void) {
        var pts = track.points(param)
        change(&pts)
        pts.sort { $0.time < $1.time }
        if param == .volume { track.volumeAuto = pts } else { track.panAuto = pts }
    }

    static func panString(_ v: Double) -> String {
        v == 0 ? "C" : (v < 0 ? String(format: "L%.0f", -v * 100) : String(format: "R%.0f", v * 100))
    }
}
