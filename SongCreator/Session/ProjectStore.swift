import AVFoundation
import Foundation

struct ProjectInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let modified: Date
    var id: URL { url }
}

/// Songs live in ~/Music/Song Creator/<name>/ with song.json and an Audio folder.
enum ProjectStore {
    static var root: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        let url = music.appendingPathComponent("Song Creator", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func songFile(_ project: URL) -> URL { project.appendingPathComponent("song.json") }
    static func audioFolder(_ project: URL) -> URL {
        let url = project.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func bouncesFolder(_ project: URL) -> URL {
        let url = project.appendingPathComponent("Mixdowns", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func list() -> [ProjectInfo] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            let file = songFile(dir)
            guard let attrs = try? fm.attributesOfItem(atPath: file.path) else { return nil }
            return ProjectInfo(url: dir, name: dir.lastPathComponent,
                               modified: attrs[.modificationDate] as? Date ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    static func create(_ song: Song) throws -> URL {
        var url = root.appendingPathComponent(sanitize(song.name), isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(sanitize(song.name)) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = audioFolder(url)
        try save(song, to: url)
        return url
    }

    static func load(_ project: URL) throws -> Song {
        let data = try Data(contentsOf: songFile(project))
        return try JSONDecoder().decode(Song.self, from: data)
    }

    static func save(_ song: Song, to project: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(song).write(to: songFile(project), options: .atomic)
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled" : s
    }

    /// Copy an audio file into the project at the session sample rate (mono or stereo).
    static func importAudio(_ source: URL, into folder: URL, sampleRate: Double) throws -> (fileName: String, duration: Double, channels: Int) {
        let input = try AVAudioFile(forReading: source)
        let channels = min(2, Int(input.processingFormat.channelCount))
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let name = sanitize(source.deletingPathExtension().lastPathComponent) + "-\(UUID().uuidString.prefix(6)).caf"
        let output = try Recorder.makeFile(url: folder.appendingPathComponent(name), sampleRate: sampleRate, channels: channels)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: outFormat) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
        var finished = false
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)!
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if finished { outStatus.pointee = .endOfStream; return nil }
                do { try input.read(into: inBuf) } catch { finished = true; outStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { finished = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            if outBuf.frameLength > 0 { try output.write(from: outBuf) }
            if status == .endOfStream || status == .error { break }
        }
        return (name, Double(output.length) / sampleRate, channels)
    }
}
