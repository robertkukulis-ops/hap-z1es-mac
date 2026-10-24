import AppKit
import HAPKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An item on the player's drive dragged inside the app (declared in the app's Info.plist).
    static let hapDriveItem = UTType(exportedAs: "local.hap-player.drive-item")
}

/// What's dragged when you drag a file or folder in the Folders list: only this app accepts
/// it, so dragging inside the list never looks like a drop from Finder.
struct DriveDragItem: Codable, Transferable {
    let path: String
    var url: URL { URL(fileURLWithPath: path) }
    init(url: URL) { path = url.path }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .hapDriveItem)
    }
}

/// Moves (or copies, with ⌥ held) dragged items into `target` on drop; highlights while over it.
struct DriveDropTarget: ViewModifier {
    @Environment(DriveModel.self) private var model
    let target: URL
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: DriveDragItem.self) { items, _ in
                model.drop(items.map(\.url), into: target, copy: NSEvent.modifierFlags.contains(.option))
                return true
            } isTargeted: { targeted = $0 }
            .background(targeted ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 4))
    }
}

extension View {
    func driveDropTarget(_ target: URL) -> some View { modifier(DriveDropTarget(target: target)) }
}

/// Choosing a folder on the player to move or copy into: browse the folders (double-click to
/// open), make a new one, then "Move Here" / "Copy Here". Nothing changes until the next step
/// is confirmed.
struct FolderPicker: View {
    @Environment(DriveModel.self) private var model
    let request: DriveModel.OrganizeRequest
    let drive: HAPDrive
    @State private var current: URL
    @State private var folders: [DriveItem] = []
    @State private var selected: URL?
    @State private var newName = ""
    @State private var showingNewFolder = false
    @State private var problem: String?

    init(request: DriveModel.OrganizeRequest, drive: HAPDrive, start: URL) {
        self.request = request
        self.drive = drive
        _current = State(initialValue: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(request.kind.verb) \(request.urls.count == 1 ? "“\(request.urls[0].lastPathComponent)”" : "\(request.urls.count) items") to…")
                .font(.headline)
            HStack(spacing: 6) {
                Button {
                    current = current.deletingLastPathComponent()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(drive.relativePath(of: current).isEmpty)
                .help("Up one folder")
                Text(pathText).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            }
            List(folders, selection: $selected) { folder in
                Label(folder.name, systemImage: "folder.fill").tag(folder.url)
            }
            .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                if let url = urls.first { current = url }  // double-click: open the folder
            }
            .overlay { if folders.isEmpty { Text("No folders inside").foregroundStyle(.secondary) } }
            .frame(minHeight: 260)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("New Folder…") { newName = ""; showingNewFolder = true }
                Spacer()
                Button("Cancel", role: .cancel) { model.organizeRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("\(request.kind.verb) Here") {
                    let target = selected ?? current
                    Task { await model.prepareOrganize(request, into: target) }
                }
                .keyboardShortcut(.defaultAction)
                .help(selected == nil ? "Into the folder shown above" : "Into the selected folder")
            }
            Text("\(request.kind.verb)s into \(selected.map { "“\($0.lastPathComponent)”" } ?? "the folder shown above"). You'll see exactly what will happen and confirm first.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460, height: 460)
        .task(id: current) { await load() }
        .alert("New folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Inside “\(current.lastPathComponent)”.")
        }
    }

    private var pathText: String {
        let relative = drive.relativePath(of: current)
        return relative.isEmpty ? "HAP_Internal" : "HAP_Internal › " + relative.replacingOccurrences(of: "/", with: " › ")
    }

    private func load() async {
        selected = nil
        let drive = drive, folder = current
        let items = await Task.detached { (try? drive.items(in: folder)) ?? [] }.value
        folders = items.filter { $0.isFolder && $0.name.lowercased() != "lost+found" && !$0.name.hasPrefix(".") }
    }

    private func createFolder() {
        do {
            current = try drive.createFolder(named: newName, in: current)  // and open it
            problem = nil
        } catch {
            problem = PlayerModel.message(for: error)
        }
    }
}

/// Text for the Move / Copy confirmation.
@MainActor
enum OrganizeText {
    static func message(_ pending: DriveModel.PendingOrganize) -> String {
        let names = pending.kind == .move
            ? pending.moves.moves.map(\.source.lastPathComponent)
            : pending.copies.items.map(\.source.lastPathComponent)
        let shown = names.prefix(6).map { "• \($0)" }.joined(separator: "\n")
        let more = names.count > 6 ? "\n…and \(names.count - 6) more" : ""
        let into = "Into: \(pending.destinationName.replacingOccurrences(of: "/", with: " › "))\n\n"
        switch pending.kind {
        case .move:
            return into + shown + more + "\n\n"
                + "The player will treat moved songs as new: their play counts and favourites, and their place in the "
                + "player's own playlists, are lost. Your playlists in this app keep them. Where they came from on your "
                + "computer (shown under Original) is no longer known after a move. Nothing is overwritten."
                + DriveModel.skipSummary(pending.skipped)
        case .copy:
            return into + "\(names.count) file\(names.count == 1 ? "" : "s"), \(DriveModel.bytes(pending.copies.totalBytes)):\n"
                + shown + more + "\n\n"
                + "Each copy is checked against the original. The originals stay where they are. Nothing is overwritten."
                + DriveModel.skipSummary(pending.skipped)
        }
    }
}
