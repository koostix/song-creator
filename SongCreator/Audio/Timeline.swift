import Foundation
import Darwin

/// Converts between mach host ticks and seconds.
enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    static var now: UInt64 { mach_absolute_time() }
}

/// A contiguous stretch where player time maps linearly onto song time.
struct TimelinePiece {
    var playerStart: Int64
    var songStart: Int64
    var length: Int64
}

/// Maps the transport's player timeline (frames since play started) onto song
/// positions (frames), wrapping inside the loop when cycling.
struct TimelineMap {
    var sampleRate: Double
    /// Song frame at player frame 0. Negative during a count-in.
    var startFrame: Int64
    var loop: (start: Int64, end: Int64)?

    init(sampleRate: Double, startTime: Double, loop: TimeRange?) {
        self.sampleRate = sampleRate
        self.startFrame = Int64((startTime * sampleRate).rounded())
        if let loop, loop.isValid {
            let s = Int64((loop.start * sampleRate).rounded())
            let e = Int64((loop.end * sampleRate).rounded())
            // Only cycle if we start before the loop end; otherwise play straight through.
            self.loop = startFrame < e ? (s, e) : nil
        } else {
            self.loop = nil
        }
    }

    func songFrame(atPlayerFrame p: Int64) -> Int64 {
        let linear = startFrame + p
        guard let loop, linear >= loop.end else { return linear }
        let len = loop.end - loop.start
        return loop.start + (linear - loop.end) % len
    }

    func songTime(atPlayerTime t: Double) -> Double {
        Double(songFrame(atPlayerFrame: Int64(t * sampleRate))) / sampleRate
    }

    /// Player frame where the song first reaches `songFrame` (moving forward).
    func firstPlayerFrame(reaching songFrame: Int64) -> Int64 {
        max(0, songFrame - startFrame)
    }

    /// Split player range [p0, p0+count) into linear pieces.
    func pieces(playerStart p0: Int64, count: Int64) -> [TimelinePiece] {
        var result: [TimelinePiece] = []
        var p = p0
        let end = p0 + count
        while p < end {
            let s = songFrame(atPlayerFrame: p)
            var len = end - p
            // With a loop the song position never passes loop.end, so cut each piece there.
            if let loop { len = min(len, loop.end - s) }
            len = max(1, len)
            result.append(TimelinePiece(playerStart: p, songStart: s, length: len))
            p += len
        }
        return result
    }
}
