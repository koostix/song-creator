import SwiftUI

/// The start screen: a song library organized into projects, with details for the selected song.
struct ProjectBrowser: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = ProjectBrowser.savedFilter
    @State private var search = ""
    @State private var statusFilter: SongStatus?
    @State private var selection: Set<URL> = []
    @State private var sortOrder = [KeyPathComparator(\SongEntry.modified, order: .reverse)]
    @State private var confirmTrash: [SongEntry] = []
    @State private var confirmRemoveProject: String?

    private var library: SongLibrary { model.library }

    private var rows: [SongEntry] {
        library.songs(in: filter, search: search, status: statusFilter).sorted(using: sortOrder)
    }

    private var selected: [SongEntry] { library.songs.filter { selection.contains($0.url) } }

    /// New Song goes into the project being viewed.
    private var currentProject: String? {
        if case .project(let p) = filter { return p }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(filter: $filter, selection: $selection, confirmRemoveProject: $confirmRemoveProject)
                .frame(width: 220)
            Divider().overlay(Color.black)
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.black)
                if rows.isEmpty {
                    emptyState
                } else {
                    table
                }
            }
            .frame(maxWidth: .infinity)
            Divider().overlay(Color.black)
            Group {
                if selected.count == 1 {
                    SongDetails(song: selected[0], selection: $selection, confirmTrash: $confirmTrash)
                } else if selected.count > 1 {
                    BulkPanel(songs: selected, selection: $selection, confirmTrash: $confirmTrash)
                } else {
                    Text("Select a song to see its details")
                        .font(.callout).foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 290)
            .background(Theme.panel)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.refresh() }
        .onChange(of: filter) { _, f in
            Prefs.libraryProject = { if case .project(let p) = f { return p } else { return nil } }()
            ProjectBrowser.savedFilter = f
        }
        .onDisappear { model.player.stop() }
        .alert(confirmTrash.count == 1 ? "Move “\(confirmTrash[0].name)” to the Trash?"
               : "Move \(confirmTrash.count) songs to the Trash?", isPresented: Binding(
            get: { !confirmTrash.isEmpty }, set: { if !$0 { confirmTrash = [] } })) {
            Button("Move to Trash", role: .destructive) {
                model.player.stop()
                library.trash(confirmTrash)
                selection.subtract(confirmTrash.map(\.url))
                confirmTrash = []
            }
            Button("Cancel", role: .cancel) { confirmTrash = [] }
        } message: {
            Text(confirmTrash.count == 1
                 ? "Its recordings and mixdowns go too. You can get it back from the Trash in Finder."
                 : "Their recordings and mixdowns go too. You can get them back from the Trash in Finder.")
        }
        .alert("Remove the project “\(confirmRemoveProject ?? "")”?", isPresented: Binding(
            get: { confirmRemoveProject != nil }, set: { if !$0 { confirmRemoveProject = nil } })) {
            Button("Remove Project", role: .destructive) {
                if let p = confirmRemoveProject {
                    library.removeProject(p)
                    if filter == .project(p) { filter = .all }
                }
                confirmRemoveProject = nil
            }
            Button("Cancel", role: .cancel) { confirmRemoveProject = nil }
        } message: {
            Text("Its songs stay in your library, under Ungrouped. Only the empty project folder goes to the Trash.")
        }
        .alert("Song Creator", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }

    /// Remembered across visits to the list during this run.
    static var savedFilter: LibraryFilter = Prefs.libraryProject.map { .project($0) } ?? .all

    private var title: String {
        switch filter {
        case .all: return "All Songs"
        case .favorites: return "Favorites"
        case .ungrouped: return "Ungrouped"
        case .project(let p): return p
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if case .project(let p) = filter {
                RenameField(text: p, font: .system(size: 18, weight: .bold)) { name in
                    if let renamed = library.renameProject(p, to: name) { filter = .project(renamed) }
                }
                .fixedSize()
            } else {
                Text(title).font(.system(size: 18, weight: .bold))
            }
            Text("\(rows.count)").font(.callout).foregroundStyle(Theme.dim)
            Spacer()
            Menu {
                Button("Any status") { statusFilter = nil }
                Divider()
                ForEach(SongStatus.allCases) { s in Button(s.label) { statusFilter = s } }
            } label: {
                Label(statusFilter?.label ?? "Any status", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            TextField("Search songs and notes", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            Button {
                model.newSong(in: currentProject)
            } label: {
                Label("New Song", systemImage: "plus")
            }
            .keyboardShortcut(.defaultAction)
            .help(currentProject.map { "New song in \($0) (⌘N)" } ?? "New song (⌘N)")
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var table: some View {
        Table(of: SongEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("★", value: \.favoriteOrder) { s in
                Button {
                    library.update(s) { $0.favorite.toggle() }
                } label: {
                    Image(systemName: s.info.favorite ? "star.fill" : "star")
                        .foregroundStyle(s.info.favorite ? Color.yellow : Theme.dim.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .width(22)
            TableColumn("Name", value: \.name) { s in
                Text(s.name).fontWeight(.medium)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Project", value: \.projectName) { s in
                Text(s.project ?? "—").foregroundStyle(s.project == nil ? Theme.dim : Theme.text)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Status", value: \.statusOrder) { s in StatusBadge(status: s.info.status) }
                .width(78)
            TableColumn("Tempo", value: \.tempo) { s in
                Text("\(Int(s.tempo)) · \(s.beatsPerBar)/4").font(.system(.body, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            .width(78)
            TableColumn("Length", value: \.length) { s in
                Text(ProjectBrowser.duration(s.length)).font(.system(.body, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            .width(54)
            TableColumn("Modified", value: \.modified) { s in
                Text(s.modified, format: .relative(presentation: .named)).foregroundStyle(Theme.dim)
            }
            .width(min: 80, ideal: 110)
            TableColumn("") { s in
                if let mix = s.mixdowns.first {
                    Button { model.player.toggle(mix) } label: {
                        Image(systemName: model.player.playing == mix ? "stop.circle.fill" : "play.circle")
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Play the latest mixdown")
                }
            }
            .width(24)
        } rows: {
            ForEach(rows) { s in
                // Drag songs onto a project in the sidebar to move them there.
                // A private token, not a file URL, so dropping it in Finder can't move the song's folder.
                TableRow(s).draggable(SongLibrary.dragToken(s.url))
            }
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            let songs = library.songs.filter { ids.contains($0.url) }
            if !songs.isEmpty {
                SongMenu(songs: songs, selection: $selection, confirmTrash: $confirmTrash)
            }
        } primaryAction: { ids in
            if ids.count == 1, let s = library.songs.first(where: { ids.contains($0.url) }) { model.open(s) }
        }
        .onDeleteCommand { if !selected.isEmpty { confirmTrash = selected } }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.system(size: 38)).foregroundStyle(Theme.dim)
            Text(search.isEmpty && statusFilter == nil ? "No songs here yet" : "No songs match")
                .font(.title3.bold())
            if search.isEmpty && statusFilter == nil {
                Text(currentProject.map { "New songs you start here go into \($0)." }
                     ?? "Start one and press R to record your first idea.")
                    .foregroundStyle(Theme.dim)
                Button { model.newSong(in: currentProject) } label: { Label("New Song", systemImage: "plus") }
                    .controlSize(.large)
            } else {
                Button("Clear search and filters") { search = ""; statusFilter = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func duration(_ t: Double) -> String {
        t <= 0 ? "–" : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct StatusBadge: View {
    let status: SongStatus

    static func color(_ s: SongStatus) -> Color {
        switch s {
        case .idea: return Color.gray
        case .writing: return Theme.accent
        case .recording: return Theme.record
        case .mixing: return Color.purple
        case .done: return Color.green
        }
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(StatusBadge.color(status).opacity(0.25)))
            .foregroundStyle(StatusBadge.color(status))
    }
}

/// Actions for the selected songs, shared by the table's context menu and the side panel.
struct SongMenu: View {
    @Environment(AppModel.self) private var model
    let songs: [SongEntry]
    @Binding var selection: Set<URL>
    @Binding var confirmTrash: [SongEntry]

    private var one: SongEntry? { songs.count == 1 ? songs[0] : nil }
    private var allFavorite: Bool { songs.allSatisfy(\.info.favorite) }

    var body: some View {
        if let song = one {
            Button("Open") { model.open(song) }
        }
        Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") {
            let fav = !allFavorite
            model.library.update(songs) { $0.favorite = fav }
        }
        Menu("Status") {
            ForEach(SongStatus.allCases) { s in
                Button(s.label) { model.library.update(songs) { $0.status = s } }
            }
        }
        ProjectMoveMenu(songs: songs, selection: $selection)
        if let song = one {
            Button("Duplicate") { selection = model.library.duplicate(song).map { [$0] } ?? [] }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(songs.map(\.url)) }
        Divider()
        Button(songs.count == 1 ? "Move to Trash…" : "Move \(songs.count) Songs to Trash…", role: .destructive) {
            confirmTrash = songs
        }
    }
}

/// "Move to Project" for one or many songs; keeps them selected at their new location.
struct ProjectMoveMenu: View {
    @Environment(AppModel.self) private var model
    let songs: [SongEntry]
    @Binding var selection: Set<URL>
    var title = "Move to Project"

    var body: some View {
        let library = model.library
        Menu(title) {
            Button("No project (Ungrouped)") { selection = Set(library.move(songs, to: nil)) }
                .disabled(songs.allSatisfy { $0.project == nil })
            Divider()
            ForEach(library.projects, id: \.self) { p in
                Button(p) { selection = Set(library.move(songs, to: p)) }
                    .disabled(songs.allSatisfy { $0.project == p })
            }
            Divider()
            Button("New Project…") {
                if let p = library.createProject() { selection = Set(library.move(songs, to: p)) }
            }
        }
    }
}

/// Shown when several songs are selected: act on all of them at once.
struct BulkPanel: View {
    @Environment(AppModel.self) private var model
    let songs: [SongEntry]
    @Binding var selection: Set<URL>
    @Binding var confirmTrash: [SongEntry]

    var body: some View {
        let library = model.library
        let allFavorite = songs.allSatisfy(\.info.favorite)
        VStack(alignment: .leading, spacing: 14) {
            Text("\(songs.count) songs selected").font(.system(size: 17, weight: .bold))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(songs.prefix(8)) { s in
                    Text(s.name).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                if songs.count > 8 { Text("and \(songs.count - 8) more").font(.caption).foregroundStyle(Theme.dim) }
            }

            ProjectMoveMenu(songs: songs, selection: $selection, title: "Move to Project…")
                .controlSize(.large)

            LabeledContent("Status") {
                Menu("Set Status") {
                    ForEach(SongStatus.allCases) { s in
                        Button(s.label) { library.update(songs) { $0.status = s } }
                    }
                }
                .fixedSize()
            }
            Button {
                let fav = !allFavorite
                library.update(songs) { $0.favorite = fav }
            } label: {
                Label(allFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: allFavorite ? "star.slash" : "star")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(songs.map(\.url))
            } label: { Label("Show in Finder", systemImage: "folder") }

            Spacer()
            Text("Tip: drag the selection onto a project in the sidebar.").font(.caption).foregroundStyle(Theme.dim)
            Button(role: .destructive) { confirmTrash = songs } label: {
                Label("Move \(songs.count) Songs to Trash…", systemImage: "trash").frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: LibraryFilter
    @Binding var selection: Set<URL>
    @State private var dropTarget: LibraryFilter?
    @Binding var confirmRemoveProject: String?
    @State private var showKeys = false

    var body: some View {
        let library = model.library
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Song Creator").font(.system(size: 20, weight: .heavy, design: .rounded))
                Text("Capture · stack · mix").font(.caption).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionTitle("Library")
                    row("All Songs", "music.note.list", .all, library.count(.all))
                    row("Favorites", "star", .favorites, library.count(.favorites))
                    row("Ungrouped", "tray", .ungrouped, library.count(.ungrouped))
                        .dropDestination(for: String.self) { tokens, _ in drop(tokens, into: nil) } isTargeted: { on in
                            dropTarget = on ? .ungrouped : (dropTarget == .ungrouped ? nil : dropTarget)
                        }

                    HStack {
                        sectionTitle("Projects")
                        Spacer()
                        Button {
                            if let p = library.createProject() { filter = .project(p) }
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).foregroundStyle(Theme.dim)
                            .help("New project (an album, EP or session)")
                            .padding(.trailing, 12).padding(.top, 10)
                    }
                    if library.projects.isEmpty {
                        Text("Group songs into albums, EPs or sessions with +.")
                            .font(.caption).foregroundStyle(Theme.dim)
                            .padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    ForEach(library.projects, id: \.self) { p in
                        row(p, "folder", .project(p), library.count(.project(p)))
                            .dropDestination(for: String.self) { tokens, _ in drop(tokens, into: p) } isTargeted: { on in
                                dropTarget = on ? .project(p) : (dropTarget == .project(p) ? nil : dropTarget)
                            }
                            .contextMenu {
                                Button("New Song in \(p)") { model.newSong(in: p) }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([SongLibrary.folder(for: p)])
                                }
                                Divider()
                                Button("Remove Project…", role: .destructive) { confirmRemoveProject = p }
                            }
                    }
                }
            }

            Spacer(minLength: 0)
            Divider().overlay(Color.black)
            HStack {
                Button { showKeys.toggle() } label: { Label("Shortcuts", systemImage: "keyboard") }
                    .popover(isPresented: $showKeys) { ShortcutsList().padding(16) }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.root])
                } label: { Image(systemName: "folder") }
                    .help(ProjectStore.root.path)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Theme.dim)
            .padding(12)
        }
        .background(Theme.panel)
    }

    /// Dropped songs move into the project. Dragging one song of a selection moves the whole selection.
    private func drop(_ tokens: [String], into project: String?) -> Bool {
        var targets = Set(tokens.compactMap(SongLibrary.url(fromDragToken:)))
        guard !targets.isEmpty else { return false }
        if !targets.isDisjoint(with: selection) { targets.formUnion(selection) }
        let songs = model.library.songs.filter { targets.contains($0.url) }
        guard !songs.isEmpty else { return false }
        selection = Set(model.library.move(songs, to: project))
        return true
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ title: String, _ icon: String, _ f: LibraryFilter, _ count: Int) -> some View {
        let on = filter == f
        let dropping = dropTarget == f
        return HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(on ? Color.white : Theme.accent)
            Text(title).lineLimit(1)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(on ? Color.white.opacity(0.8) : Theme.dim)
        }
        .font(.system(size: 13, weight: on ? .semibold : .regular))
        .padding(.horizontal, 10).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.35) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: dropping ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture { filter = f }
        .padding(.horizontal, 6)
    }
}

struct SongDetails: View {
    @Environment(AppModel.self) private var model
    let song: SongEntry
    @Binding var selection: Set<URL>
    @Binding var confirmTrash: [SongEntry]
    @State private var notes = ""

    var body: some View {
        let library = model.library
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    RenameField(text: song.name, font: .system(size: 17, weight: .bold)) { name in
                        selection = library.rename(song, to: name).map { [$0] } ?? []
                    }
                    Button {
                        library.update(song) { $0.favorite.toggle() }
                    } label: {
                        Image(systemName: song.info.favorite ? "star.fill" : "star")
                            .foregroundStyle(song.info.favorite ? Color.yellow : Theme.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Favorite")
                }

                Button {
                    model.open(song)
                } label: {
                    Label("Open Song", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                LabeledContent("Status") {
                    Picker("", selection: Binding(get: { song.info.status },
                                                  set: { v in library.update(song) { $0.status = v } })) {
                        ForEach(SongStatus.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent("Project") {
                    ProjectMoveMenu(songs: [song], selection: $selection, title: song.project ?? "None")
                        .fixedSize()
                }

                VStack(alignment: .leading, spacing: 4) {
                    detail("Tempo", "\(Int(song.tempo)) BPM · \(song.beatsPerBar)/4")
                    detail("Length", ProjectBrowser.duration(song.length))
                    detail("Tracks", "\(song.trackCount)")
                    detail("Created", song.created.formatted(date: .abbreviated, time: .shortened))
                    detail("Modified", song.modified.formatted(date: .abbreviated, time: .shortened))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("NOTES").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                    TextEditor(text: $notes)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 110)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                        .onChange(of: notes) { _, v in library.update(song) { $0.notes = v } }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("MIXDOWNS").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                    if song.mixdowns.isEmpty {
                        Text("None yet. Export one from the song with ⌘E.").font(.caption).foregroundStyle(Theme.dim)
                    }
                    ForEach(song.mixdowns.prefix(8), id: \.self) { mix in
                        HStack(spacing: 6) {
                            Button { model.player.toggle(mix) } label: {
                                Image(systemName: model.player.playing == mix ? "stop.circle.fill" : "play.circle")
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            Text(mix.deletingPathExtension().lastPathComponent).font(.caption).lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([mix]) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Show in Finder")
                        }
                    }
                }

                HStack {
                    Button("Duplicate") { selection = library.duplicate(song).map { [$0] } ?? [] }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.url]) }
                    Spacer()
                    Button(role: .destructive) { confirmTrash = [song] } label: { Image(systemName: "trash") }
                        .help("Move to Trash")
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .onAppear { notes = song.info.notes }
        .onChange(of: song.url) { _, _ in notes = song.info.notes }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.dim)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }
}

struct ShortcutsList: View {
    static let keys: [(String, String)] = [
        ("Space", "Play / stop"), ("R", "Record (again to stop)"), ("Return", "Go to start"),
        ("← →", "Move a bar"), ("⌥← ⌥→", "Previous / next section"), ("1–9", "Jump to section"),
        ("L / ⇧L", "Loop on/off / loop selection"), ("J", "Jam over the loop"),
        ("P / ⇧P", "Punch on/off / punch selection"), ("C", "Click on/off"), ("⇧M", "Add section marker"),
        ("A M S", "Arm / mute / solo track"), ("B", "Split at playhead"), ("⌘C ⌘V ⌘D", "Copy / paste / duplicate regions"),
        ("T / ⇧T", "New audio / MIDI track"), ("Z", "Zoom to fit"), ("⌘K", "Computer keyboard as MIDI"),
        ("X", "Mixer"), ("⌘E", "Export mixdown"),
        ("= / −", "Zoom in / out (or pinch, ⌘-scroll)"), ("⌫", "Delete selected regions"), ("Esc", "Clear selection"),
        ("⌘Z ⇧⌘Z", "Undo / redo"), ("Tab", "While renaming: next track"), ("⌘,", "Audio settings"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Keyboard shortcuts").font(.headline).padding(.bottom, 4)
            ForEach(ShortcutsList.keys, id: \.0) { k in
                HStack {
                    Text(k.0).font(.system(.caption, design: .monospaced)).frame(width: 84, alignment: .leading)
                    Text(k.1).font(.caption).foregroundStyle(Theme.dim)
                }
            }
        }
    }
}
