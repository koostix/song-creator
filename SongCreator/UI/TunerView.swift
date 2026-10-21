import Accelerate
import SwiftUI

/// YIN pitch detection on the most recent input samples.
enum PitchDetector {
    static func detect(_ x: [Float], sampleRate: Double, minHz: Double = 38, maxHz: Double = 1400) -> Double? {
        let w = 2048
        guard x.count >= w * 2 else { return nil }
        let frame = Array(x.suffix(w * 2))
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        guard rms > 0.004 else { return nil }

        let minLag = max(2, Int(sampleRate / maxHz)), maxLag = min(w - 1, Int(sampleRate / minHz))
        var diff = [Float](repeating: 0, count: maxLag + 1)
        frame.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            var e0: Float = 0
            vDSP_svesq(base, 1, &e0, vDSP_Length(w))
            for tau in 1...maxLag {
                var r: Float = 0, e1: Float = 0
                vDSP_dotpr(base, 1, base + tau, 1, &r, vDSP_Length(w))
                vDSP_svesq(base + tau, 1, &e1, vDSP_Length(w))
                diff[tau] = e0 + e1 - 2 * r
            }
        }
        // Cumulative mean normalised difference.
        var cmnd = [Float](repeating: 1, count: maxLag + 1)
        var running: Float = 0
        for tau in 1...maxLag {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Float(tau) / running : 1
        }
        var tau = minLag
        while tau < maxLag {
            if cmnd[tau] < 0.15 {
                while tau + 1 < maxLag && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                break
            }
            tau += 1
        }
        guard tau < maxLag, cmnd[tau] < 0.3 else { return nil }
        // Parabolic interpolation around the minimum.
        let a = Double(cmnd[tau - 1]), b = Double(cmnd[tau]), c = Double(cmnd[min(maxLag, tau + 1)])
        let denom = a - 2 * b + c
        let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
        return sampleRate / (Double(tau) + shift)
    }
}

struct TunerView: View {
    let session: Session
    @State private var hz: Double?
    @State private var smoothed: Double?
    @State private var a4 = Prefs.tunerA4
    @State private var timer: Timer?

    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private var channel: Int {
        let t = session.song.tracks.first { $0.id == session.selectedTrackID && $0.kind == .audio }
            ?? session.song.tracks.first { $0.armed && $0.kind == .audio }
        return t?.inputChannel ?? 0
    }

    var body: some View {
        let reading = smoothed.map { f -> (String, Int, Double) in
            let midi = 69 + 12 * log2(f / a4)
            let nearest = Int(midi.rounded())
            return (TunerView.names[((nearest % 12) + 12) % 12], nearest / 12 - 1, (midi - Double(nearest)) * 100)
        }
        VStack(spacing: 10) {
            Text("Input \(channel + 1)").font(.caption).foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(reading?.0 ?? "–").font(.system(size: 48, weight: .bold, design: .rounded))
                if let r = reading { Text("\(r.1)").font(.title3).foregroundStyle(Theme.dim) }
            }
            .foregroundStyle(reading.map { abs($0.2) < 5 ? Color.green : Theme.text } ?? Theme.dim)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    ForEach([-50, -25, 0, 25, 50], id: \.self) { c in
                        Rectangle().fill(c == 0 ? Color.green.opacity(0.7) : Theme.dim.opacity(0.5))
                            .frame(width: c == 0 ? 2 : 1, height: c == 0 ? 22 : 12)
                            .position(x: w / 2 + CGFloat(c) / 50 * (w / 2 - 6), y: 14)
                    }
                    if let r = reading {
                        Capsule().fill(abs(r.2) < 5 ? Color.green : Color.orange)
                            .frame(width: 6, height: 26)
                            .position(x: w / 2 + CGFloat(max(-50, min(50, r.2))) / 50 * (w / 2 - 6), y: 14)
                            .animation(.easeOut(duration: 0.08), value: r.2)
                    }
                }
            }
            .frame(height: 28)

            Text(reading.map { String(format: "%+.0f cents · %.1f Hz", $0.2, smoothed ?? 0) } ?? "Play a note")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.dim)
            Stepper(value: $a4, in: 430...450, step: 1) { Text("A4 = \(Int(a4)) Hz").font(.caption) }
                .onChange(of: a4) { _, v in Prefs.tunerA4 = v }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear {
            session.recorder.setTunerChannel(channel + session.audio.inputChannelOffset)
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                let f = PitchDetector.detect(session.recorder.latestTunerSamples(), sampleRate: session.recorder.inputRate)
                hz = f
                if let f {
                    // Smooth small wobbles, jump on note changes.
                    if let s = smoothed, abs(1200 * log2(f / s)) < 80 { smoothed = s * 0.6 + f * 0.4 } else { smoothed = f }
                } else {
                    smoothed = nil
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            session.recorder.setTunerChannel(nil)
        }
    }
}
