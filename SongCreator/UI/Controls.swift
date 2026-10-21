import SwiftUI

enum Theme {
    static let background = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let panel = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let lane = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let laneAlt = Color(red: 0.145, green: 0.145, blue: 0.165)
    static let grid = Color.white.opacity(0.06)
    static let gridBar = Color.white.opacity(0.13)
    static let text = Color.white.opacity(0.88)
    static let dim = Color.white.opacity(0.5)
    static let record = Color(red: 0.95, green: 0.25, blue: 0.25)
    static let loop = Color(red: 0.95, green: 0.75, blue: 0.2)
    static let punch = Color(red: 0.9, green: 0.35, blue: 0.5)
    static let accent = Color(red: 0.35, green: 0.7, blue: 1.0)

    static let trackColors: [Color] = [
        Color(red: 0.35, green: 0.65, blue: 1.0), Color(red: 0.4, green: 0.85, blue: 0.55),
        Color(red: 1.0, green: 0.62, blue: 0.3), Color(red: 0.8, green: 0.5, blue: 1.0),
        Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 0.35, green: 0.85, blue: 0.85),
        Color(red: 0.95, green: 0.85, blue: 0.35), Color(red: 0.65, green: 0.7, blue: 0.8),
    ]
    static func color(_ i: Int) -> Color { trackColors[((i % trackColors.count) + trackColors.count) % trackColors.count] }
}

/// Small toggle button like a console's illuminated switch.
struct LitButton: View {
    let label: String
    let on: Bool
    var color: Color = Theme.accent
    var width: CGFloat = 22
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: width, height: 18)
                .foregroundStyle(on ? Color.black : Theme.dim)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? color : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Rotary control. Drag up/down to change, double-click to reset, hold Option for fine.
struct Knob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var label: String
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var color: Color = Theme.accent
    var logarithmic = false

    @State private var dragStart: Double?

    private var norm: Double {
        if logarithmic { return log(value / range.lowerBound) / log(range.upperBound / range.lowerBound) }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func denorm(_ n: Double) -> Double {
        let n = min(1, max(0, n))
        if logarithmic { return range.lowerBound * pow(range.upperBound / range.lowerBound, n) }
        return range.lowerBound + n * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * norm)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = norm }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                    value = denorm(dragStart! - g.translation.height / 150 * fine)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { value = defaultValue }
            Text(dragStart != nil ? format(value) : label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(dragStart != nil ? Theme.text : Theme.dim)
                .lineLimit(1)
                .frame(width: 44)
        }
        .help("\(label): \(format(value)) — drag, double-click to reset")
    }
}

/// Peak meter polled from the engine's MeterStore.
struct MeterBar: View {
    let level: () -> Float
    var vertical = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let v = Double(level())
            let db = v > 0 ? 20 * log10(v) : -60
            let n = max(0, min(1, (db + 60) / 66))
            GeometryReader { geo in
                ZStack(alignment: vertical ? .bottom : .leading) {
                    Rectangle().fill(Color.black.opacity(0.5))
                    Rectangle()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                             startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing))
                        .mask(alignment: vertical ? .bottom : .leading) {
                            Rectangle().frame(width: vertical ? nil : geo.size.width * n,
                                              height: vertical ? geo.size.height * n : nil)
                        }
                    if v >= 1 {
                        Rectangle().fill(Color.red)
                            .frame(width: vertical ? nil : 3, height: vertical ? 3 : nil)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .top : .trailing)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
    }
}

/// Vertical fader in dB. Drag to move, double-click for 0 dB, Option for fine.
struct Fader: View {
    @Binding var db: Double
    var height: CGFloat = 150

    @State private var dragStart: Double?

    // Map dB to 0...1 with more resolution near unity.
    static func pos(_ db: Double) -> Double {
        if db <= -60 { return 0 }
        return pow((db + 60) / 66, 2.2)
    }
    static func db(_ pos: Double) -> Double {
        let p = min(1, max(0, pos))
        if p <= 0.0001 { return -60 }
        return pow(p, 1 / 2.2) * 66 - 60
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - 16
            let y = (1 - Fader.pos(db)) * h
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.6)).frame(width: 4)
                    .frame(maxHeight: .infinity).padding(.vertical, 8)
                Rectangle().fill(Theme.dim).frame(width: 14, height: 1).offset(y: (1 - Fader.pos(0)) * h + 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(height: 1.5))
                    .frame(width: 26, height: 16)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = Fader.pos(db) }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                    let p = dragStart! - g.translation.height / h * fine
                    db = (Fader.db(p) * 10).rounded() / 10
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { db = 0 }
        }
        .frame(width: 30, height: height)
    }
}

extension Double {
    var dbString: String { self <= -60 ? "-∞" : String(format: "%+.1f", self) }
}
