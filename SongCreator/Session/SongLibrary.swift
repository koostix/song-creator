import AVFoundation
import Foundation
import Observation

/// Where a song is in its life. Shown as a badge and used for filtering.
enum SongStatus: String, Codable, CaseIterable, Identifiable {
    case idea, writing, recording, mixing, done
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Library-only details kept beside each song in info.json, so song.json stays untouched.
struct SongInfo: Codable, Equatable {
    var status: SongStatus = .idea
    var favorite = false
    var notes = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(SongStatus.self, forKey: .status) ?? .idea
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct SongEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Project folder name, nil for songs at the top of the library.
    let project: String?
    let modified: Date
    let created: Date
    let tempo: Double
    let beatsPerBar: Int
    let length: Double
    let trackCount: Int
    var info: SongInfo
    /// Exported mixes, newest first.
    let mixdowns: [URL]

    var id: URL { url }
    var projectName: String { project ?? "" }
    var statusOrder: Int { SongStatus.allCases.firstIndex(of: info.status) ?? 0 }
    var favoriteOrder: Int { info.favorite ? 1 : 0 }

    static func == (a: SongEntry, b: SongEntry) -> Bool { a.url == b.url && a.info == b.info && a.modified == b.modified }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum LibraryFilter: Hashable {
    case all, favorites, ungrouped
    case project(String)
}

/// The songs on disk: ~/Music/Song Creator/<song>/ and ~/Music/Song Creator/<project>/<song>/.
/// A folder with a song.json is a song; any other folder is a project.
@Observable
final class SongLibrary {
    private(set) var songs: [SongEntry] = []
    private(set) var projects: [String] = []
    var error: String?

    static let infoFile = "info.json"

    // MARK: - Scanning

    func refresh() {
        let fm = FileManager.default
        let root = ProjectStore.root
        var found: [SongEntry] = []
        var projectNames: [String] = []
        for dir in children(root) {
            if fm.fileExists(atPath: ProjectStore.songFile(dir).path) {
                if let e = SongLibrary.entry(dir, project: nil) { found.append(e) }
            } else {
                projectNames.append(dir.lastPathComponent)
                for sub in children(dir) where fm.fileExists(atPath: ProjectStore.songFile(sub).path) {
                    if let e = SongLibrary.entry(sub, project: dir.lastPathComponent) { found.append(e) }
                }
            }
        }
        songs = found.sorted { $0.modified > $1.modified }
        projects = projectNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func children(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func entry(_ dir: URL, project: String?) -> SongEntry? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: ProjectStore.songFile(dir).path),
              let song = try? ProjectStore.load(dir) else { return nil }
        let created = (try? fm.attributesOfItem(atPath: dir.path)[.creationDate] as? Date) ?? nil
        let mixFolder = dir.appendingPathComponent("Mixdowns")
        let mixes = ((try? fm.contentsOfDirectory(at: mixFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ["wav", "m4a", "aif", "aiff", "mp3"].contains($0.pathExtension.lowercased()) }
            .sorted { modDate($0) > modDate($1) }
        return SongEntry(url: dir, name: song.name, project: project,
                         modified: attrs[.modificationDate] as? Date ?? .distantPast,
                         created: created ?? .distantPast,
                         tempo: song.tempo, beatsPerBar: song.beatsPerBar, length: song.contentEnd,
                         trackCount: song.tracks.count, info: readInfo(dir), mixdowns: mixes)
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func readInfo(_ dir: URL) -> SongInfo {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(infoFile)),
              let info = try? JSONDecoder().decode(SongInfo.self, from: data) else { return SongInfo() }
        return info
    }

    static func writeInfo(_ info: SongInfo, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(info).write(to: dir.appendingPathComponent(infoFile), options: .atomic)
    }

    // MARK: - Queries

    func songs(in filter: LibraryFilter, search: String, status: SongStatus?) -> [SongEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return songs.filter { s in
            switch filter {
            case .all: break
            case .favorites: if !s.info.favorite { return false }
            case .ungrouped: if s.project != nil { return false }
            case .project(let p): if s.project != p { return false }
            }
            if let status, s.info.status != status { return false }
            if !q.isEmpty, !s.name.lowercased().contains(q), !s.info.notes.lowercased().contains(q) { return false }
            return true
        }
    }

    func count(_ filter: LibraryFilter) -> Int { songs(in: filter, search: "", status: nil).count }

    /// Song rows drag as "songcreator-song:<path>" text, understood only by the sidebar.
    static func dragToken(_ url: URL) -> String { "songcreator-song:" + url.path }

    static func url(fromDragToken token: String) -> URL? {
        guard token.hasPrefix("songcreator-song:") else { return nil }
        return URL(fileURLWithPath: String(token.dropFirst("songcreator-song:".count)), isDirectory: true)
    }

    static func folder(for project: String?) -> URL {
        project.map { ProjectStore.root.appendingPathComponent($0, isDirectory: true) } ?? ProjectStore.root
    }

    // MARK: - Song operations

    /// Run a file operation, report failures, and rescan.
    @discardableResult
    private func perform<T>(_ what: String, _ op: () throws -> T) -> T? {
        defer { refresh() }
        do { return try op() } catch {
            self.error = "Couldn't \(what): \(error.localizedDescription)"
            return nil
        }
    }

    /// Rename the song (its title and its folder). Returns where it lives now.
    @discardableResult
    func rename(_ song: SongEntry, to newName: String) -> URL? {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != song.name else { return song.url }
        return perform("rename \(song.name)") { () -> URL in
            var s = try ProjectStore.load(song.url)
            s.name = name
            try ProjectStore.save(s, to: song.url)
            let folderName = ProjectStore.sanitize(name)
            guard folderName != song.url.lastPathComponent else { return song.url }
            let target = ProjectStore.uniqueURL(in: song.url.deletingLastPathComponent(), name: folderName)
            try FileManager.default.moveItem(at: song.url, to: target)
            return target
        }
    }

    /// Copy a song, recordings included, as "<name> copy" in the same place.
    @discardableResult
    func duplicate(_ song: SongEntry) -> URL? {
        perform("duplicate \(song.name)") { () -> URL in
            let name = "\(song.name) copy"
            let target = ProjectStore.uniqueURL(in: song.url.deletingLastPathComponent(), name: ProjectStore.sanitize(name))
            try FileManager.default.copyItem(at: song.url, to: target)
            var s = try ProjectStore.load(target)
            s.name = target.lastPathComponent
            s.id = UUID()
            try ProjectStore.save(s, to: target)
            return target
        }
    }

    /// Move a song to the Trash (recoverable from Finder).
    func trash(_ song: SongEntry) {
        perform("move \(song.name) to the Trash") {
            try FileManager.default.trashItem(at: song.url, resultingItemURL: nil)
        }
    }

    /// Move a song into a project, or out to the top of the library with nil. Returns where it lives now.
    @discardableResult
    func move(_ song: SongEntry, to project: String?) -> URL? {
        guard project != song.project else { return song.url }
        return perform("move \(song.name)") { () -> URL in
            let folder = SongLibrary.folder(for: project)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = ProjectStore.uniqueURL(in: folder, name: song.url.lastPathComponent)
            try FileManager.default.moveItem(at: song.url, to: target)
            return target
        }
    }

    /// Move several songs into a project (or out with nil). Returns their new locations.
    @discardableResult
    func move(_ list: [SongEntry], to project: String?) -> [URL] {
        let todo = list.filter { $0.project != project }
        guard !todo.isEmpty else { return list.map(\.url) }
        let kept = list.filter { $0.project == project }.map(\.url)
        return (perform("move \(todo.count) songs") { () -> [URL] in
            let folder = SongLibrary.folder(for: project)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try todo.map { song in
                let target = ProjectStore.uniqueURL(in: folder, name: song.url.lastPathComponent)
                try FileManager.default.moveItem(at: song.url, to: target)
                return target
            }
        } ?? []) + kept
    }

    /// Move several songs to the Trash.
    func trash(_ list: [SongEntry]) {
        perform("move \(list.count) songs to the Trash") {
            for song in list { try FileManager.default.trashItem(at: song.url, resultingItemURL: nil) }
        }
    }

    func update(_ list: [SongEntry], _ change: (inout SongInfo) -> Void) {
        for song in list { update(song, change) }
    }

    func update(_ song: SongEntry, _ change: (inout SongInfo) -> Void) {
        var info = song.info
        change(&info)
        guard info != song.info else { return }
        do {
            try SongLibrary.writeInfo(info, to: song.url)
            if let i = songs.firstIndex(where: { $0.url == song.url }) { songs[i].info = info }
        } catch {
            self.error = "Couldn't save details for \(song.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Projects

    @discardableResult
    func createProject(_ name: String = "New Project") -> String? {
        perform("create the project") { () -> String in
            let url = ProjectStore.uniqueURL(in: ProjectStore.root, name: ProjectStore.sanitize(name))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.lastPathComponent
        }
    }

    @discardableResult
    func renameProject(_ name: String, to newName: String) -> String? {
        let clean = ProjectStore.sanitize(newName.trimmingCharacters(in: .whitespaces))
        guard clean != name else { return name }
        return perform("rename the project") { () -> String in
            let target = ProjectStore.uniqueURL(in: ProjectStore.root, name: clean)
            try FileManager.default.moveItem(at: SongLibrary.folder(for: name), to: target)
            return target.lastPathComponent
        }
    }

    /// Remove a project: its songs move to the top of the library, and the empty folder goes to the Trash.
    func removeProject(_ name: String) {
        perform("remove the project") {
            let folder = SongLibrary.folder(for: name)
            for song in songs where song.project == name {
                let target = ProjectStore.uniqueURL(in: ProjectStore.root, name: song.url.lastPathComponent)
                try FileManager.default.moveItem(at: song.url, to: target)
            }
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
}

/// Plays a mixdown from the song list so you can compare songs without opening them.
@Observable
final class MixdownPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = url
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}
