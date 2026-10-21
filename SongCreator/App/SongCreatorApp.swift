import AVFoundation
import Observation
import SwiftUI

@Observable
final class AppModel {
    var session: Session?
    let library = SongLibrary()
    let player = MixdownPlayer()
    var error: String?

    init() { refresh() }

    func refresh() { library.refresh() }

    /// Start a new song, inside `project` if one is given.
    func newSong(in project: String? = nil) {
        let song = Song.newIdea()
        do {
            let url = try ProjectStore.create(song, in: SongLibrary.folder(for: project))
            open(url: url, song: song)
        } catch {
            self.error = "Couldn't create the song: \(error.localizedDescription)"
        }
    }

    func open(_ entry: SongEntry) {
        do {
            open(url: entry.url, song: try ProjectStore.load(entry.url))
        } catch {
            self.error = "Couldn't open \(entry.name): \(error.localizedDescription)"
        }
    }

    private func open(url: URL, song: Song) {
        player.stop()
        session?.close()
        session = Session(projectURL: url, song: song)
    }

    func closeSong() {
        session?.close()
        session = nil
        refresh()
    }
}

@main
struct SongCreatorApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        Diagnostics.runIfRequested()
        #if DEBUG
        SelfTest.runIfRequested()
        SelfTest.snapshotIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("Song Creator") {
            RootView()
                .environment(model)
                .frame(minWidth: 1180, minHeight: 600)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Song") { model.newSong(in: Prefs.libraryProject) }.keyboardShortcut("n")
                Button("Song List") { model.closeSong() }.keyboardShortcut("o")
                    .disabled(model.session == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.session?.undo() }.keyboardShortcut("z")
                    .disabled(!(model.session?.canUndo ?? false))
                Button("Redo") { model.session?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!(model.session?.canRedo ?? false))
            }
            CommandMenu("Song") {
                Button("Save") { model.session?.saveNow() }.keyboardShortcut("s")
                Button("Import Audio…") { NotificationCenter.default.post(name: .importAudio, object: nil) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Mixdown…") { NotificationCenter.default.post(name: .showExport, object: nil) }
                    .keyboardShortcut("e")
                Divider()
                Button("Show in Finder") {
                    if let url = model.session?.projectURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for the microphone up front so the first take isn't lost to a permission prompt.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // The engine waited for the answer before opening the input; rebuild with it now.
                DispatchQueue.main.async { self.model?.session?.rebuildEngine() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.session?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let importAudio = Notification.Name("SongCreator.importAudio")
    static let showExport = Notification.Name("SongCreator.showExport")
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                MainView(session: session).id(session.projectURL)
            } else {
                ProjectBrowser()
            }
        }
        .alert("Song Creator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}
