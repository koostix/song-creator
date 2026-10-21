import SwiftUI

struct ProjectBrowser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Song Creator").font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("Capture the idea. Stack the takes. Mix it down.")
                        .foregroundStyle(Theme.dim)
                }
                Button {
                    model.newSong()
                } label: {
                    HStack(spacing: 12) {
                        Circle().fill(Theme.record).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New Song").font(.title3.bold())
                            Text("Opens with Track 1 armed. Press R to record.").font(.caption).foregroundStyle(Theme.dim)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Keys").font(.caption.bold()).foregroundStyle(Theme.dim)
                    ForEach(ProjectBrowser.keys, id: \.0) { k in
                        HStack {
                            Text(k.0).font(.system(.caption, design: .monospaced)).frame(width: 70, alignment: .leading)
                            Text(k.1).font(.caption).foregroundStyle(Theme.dim)
                        }
                    }
                }
                Spacer()
                Text(ProjectStore.root.path).font(.caption2).foregroundStyle(Theme.dim)
            }
            .padding(40)
            .frame(width: 400)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panel)

            VStack(alignment: .leading) {
                Text("Songs").font(.headline).padding([.top, .horizontal], 20)
                if model.projects.isEmpty {
                    Text("No songs yet.").foregroundStyle(Theme.dim).padding(20)
                    Spacer()
                } else {
                    List(model.projects) { p in
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(p.name).font(.body.weight(.medium))
                                Text(p.modified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            Button("Open") { model.open(p) }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(p) }
                        .contextMenu {
                            Button("Open") { model.open(p) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.refresh() }
    }

    static let keys: [(String, String)] = [
        ("Space", "Play / stop"), ("R", "Record (again to stop)"), ("Return", "Go to start"),
        ("← →", "Move a bar"), ("⌥← ⌥→", "Previous / next section"), ("1–9", "Jump to section"),
        ("L / ⇧L", "Loop on/off / loop selection"), ("P / ⇧P", "Punch on/off / punch selection"),
        ("C", "Click on/off"), ("⇧M", "Add section marker"), ("A M S", "Arm / mute / solo track"),
        ("T / ⇧T", "New audio / MIDI track"), ("X", "Mixer"), ("⌘E", "Export mixdown"),
    ]
}
