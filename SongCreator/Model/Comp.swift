import Foundation

extension Track {
    /// Make `takeID` the active take over `range` (clipped to the take's extent),
    /// cutting whatever was there before. This is swipe comping.
    mutating func assign(takeID: UUID, over range: TimeRange) {
        guard let take = take(takeID), let r = range.clamped(to: take.range) else { return }
        place(CompSegment(takeID: takeID, start: r.start, end: r.end))
    }

    /// Put a region on the timeline; it wins over anything it overlaps.
    mutating func place(_ seg: CompSegment) {
        clearComp(seg.range)
        comp.append(seg)
        normalizeComp()
    }

    /// Silence the comp over `range`, splitting regions at its edges.
    mutating func clearComp(_ range: TimeRange) {
        var result: [CompSegment] = []
        for seg in comp {
            if seg.end <= range.start || seg.start >= range.end {
                result.append(seg)
                continue
            }
            if seg.start < range.start {
                var left = seg
                left.id = UUID()
                left.end = range.start
                left.fadeOut = 0
                result.append(left)
            }
            if seg.end > range.end {
                var right = seg
                right.id = UUID()
                right.start = range.end
                right.fadeIn = 0
                result.append(right)
            }
        }
        comp = result
    }

    mutating func removeTake(_ id: UUID) {
        takes.removeAll { $0.id == id }
        comp.removeAll { $0.takeID == id }
    }

    /// Sort, drop slivers and clamp fades. Touching regions are kept apart so splits stay split.
    mutating func normalizeComp() {
        comp = comp.filter { $0.end - $0.start > 0.001 }.sorted { $0.start < $1.start }.map { seg in
            var seg = seg
            seg.fadeIn = max(0, min(seg.fadeIn, seg.length))
            seg.fadeOut = max(0, min(seg.fadeOut, seg.length - seg.fadeIn))
            return seg
        }
    }

    /// Which take is heard at time `t`, if any.
    func activeTake(at t: Double) -> UUID? {
        comp.first { t >= $0.start && t < $0.end }?.takeID
    }

    func segment(_ id: UUID) -> CompSegment? { comp.first { $0.id == id } }

    func segment(at t: Double) -> CompSegment? { comp.first { t >= $0.start && t < $0.end } }

    /// Song range the region could cover: its take's material, shifted by the region's offset.
    func contentRange(_ seg: CompSegment) -> TimeRange? {
        guard let take = take(seg.takeID) else { return nil }
        return TimeRange(start: take.start + seg.offset, end: take.start + seg.offset + take.duration)
    }

    // MARK: - Region edits

    /// Move a region (and its material) by `delta` seconds.
    mutating func moveSegment(_ id: UUID, by delta: Double) {
        guard var seg = segment(id) else { return }
        let d = max(-seg.start, delta)
        comp.removeAll { $0.id == id }
        seg.start += d
        seg.end += d
        seg.offset += d
        place(seg)
    }

    /// Move a region's start and/or end edge, revealing or hiding material.
    mutating func trimSegment(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard var seg = segment(id), let content = contentRange(seg) else { return }
        comp.removeAll { $0.id == id }
        if let start { seg.start = max(0, max(content.start, min(start, seg.end - 0.02))) }
        if let end { seg.end = min(content.end, max(end, seg.start + 0.02)) }
        place(seg)
    }

    mutating func setFades(_ id: UUID, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard let i = comp.firstIndex(where: { $0.id == id }) else { return }
        if let fadeIn { comp[i].fadeIn = max(0, min(fadeIn, comp[i].length - comp[i].fadeOut)) }
        if let fadeOut { comp[i].fadeOut = max(0, min(fadeOut, comp[i].length - comp[i].fadeIn)) }
    }

    /// Cut a region in two at `t`.
    mutating func splitSegment(_ id: UUID, at t: Double) {
        guard let i = comp.firstIndex(where: { $0.id == id }), t > comp[i].start + 0.005, t < comp[i].end - 0.005 else { return }
        var right = comp[i]
        right.id = UUID()
        right.start = t
        right.fadeIn = 0
        comp[i].end = t
        comp[i].fadeOut = 0
        comp.insert(right, at: i + 1)
    }

    mutating func removeSegments(_ ids: Set<UUID>) {
        comp.removeAll { ids.contains($0.id) }
    }
}

/// Regions on the clipboard, with the takes they need, relative to the earliest start.
struct RegionClipboard {
    struct Item {
        var take: Take
        var segment: CompSegment
    }
    var items: [Item]
    var length: Double
}
