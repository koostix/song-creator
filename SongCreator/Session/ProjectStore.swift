import AVFoundation
import Foundation

/// Songs live in ~/Music/Song Creator/<song>/ (or <project>/<song>/) with song.json and an Audio folder.
enum ProjectStore {
    /// Tests point the library somewhere else.
    static var rootOverride: URL?

    static var root: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        let url = rootOverride ?? music.appendingPathComponent("Song Creator", isDirectory: true)
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

    /// Create a song folder in `folder` (the library root or a project folder).
    static func create(_ song: Song, in folder: URL? = nil) throws -> URL {
        let url = uniqueURL(in: folder ?? root, name: sanitize(song.name))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = audioFolder(url)
        try save(song, to: url)
        return url
    }

    /// "Name", or "Name 2", "Name 3"… if taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    // MARK: - New-song default

    /// The saved setup New Song starts from (hidden in the library folder).
    static var templateURL: URL { root.appendingPathComponent(".new-song-default.json") }

    static var hasTemplate: Bool { FileManager.default.fileExists(atPath: templateURL.path) }

    /// Keep a song's setup, without its recordings, as the start for new songs.
    static func saveTemplate(_ song: Song) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(song.asTemplate()).write(to: templateURL, options: .atomic)
    }

    static func clearTemplate() { try? FileManager.default.removeItem(at: templateURL) }

    /// A brand-new song: from the saved default if there is one, else the plain one-track start.
    static func newSong() -> Song {
        let fresh = Song.newIdea()
        guard let data = try? Data(contentsOf: templateURL),
              let template = try? JSONDecoder().decode(Song.self, from: data) else { return fresh }
        var song = template.asTemplate()   // fresh IDs again, so songs never share anything
        song.id = UUID()
        song.name = fresh.name
        return song
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
