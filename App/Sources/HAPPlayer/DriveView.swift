import HAPKit
import SwiftUI

/// The player's music drive: browse folders, see sizes and whether originals are still on
/// this Mac, and delete what you select, after confirming.
struct DriveView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(DriveModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.drive != nil {
                browser
            } else if let error = model.connectError {
                ContentUnavailableView {
                    Label("Drive not connected", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await connect() } }
                }
            } else {
                ProgressView("Connecting to the player's drive…")
            }
        }
        .navigationTitle("Drive")
        .task { await connect() }
    }

    private func connect() async {
        model.player = player
        guard let device = player.device else { return }
        // By name first (the SMB1 setting for the player is keyed on it), address as fallback.
        await model.connect(hosts: [device.friendlyName, device.host])
    }

    private var browser: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            pathBar
            Divider()
            if model.isUploading {
                HStack(spacing: 12) {
                    ProgressView(value: Double(model.uploadProgress.bytesDone), total: Double(max(model.uploadTotalBytes, 1)))
                        .frame(maxWidth: 260)
                    VStack(alignment: .leading) {
                        Text("Copying… \(model.uploadProgress.filesDone) of \(model.uploadTotalFiles) files · "
                             + "\(DriveModel.bytes(model.uploadProgress.bytesDone)) of \(DriveModel.bytes(model.uploadTotalBytes))")
                            .monospacedDigit()
                        Text(model.uploadProgress.currentName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("Tip: play music from other folders until copying has finished; the player can get stuck reading files that are being copied.")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Stop") { model.stopUploading() }
                        .help("Stop copying. Files already copied stay; the half-copied one is removed.")
                }
                .padding(10)
                .background(.quaternary)
            }
            if model.isDeleting {
                HStack(spacing: 12) {
                    ProgressView(value: Double(model.deletedFiles), total: Double(max(model.filesToDelete, 1)))
                        .frame(maxWidth: 260)
                    Text("Deleting… \(model.deletedFiles) of \(model.filesToDelete) files")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Stop") { model.stopDeleting() }
                        .help("Stop after the current file. What's already deleted stays deleted.")
                }
                .padding(10)
                .background(.quaternary)
            }
            if let result = model.lastResult {
                HStack {
                    Image(systemName: "info.circle")
                    Text(result).frame(maxWidth: .infinity, alignment: .leading)
                    Button("OK") { model.dismissResult() }
                }
                .padding(10)
                .background(.quaternary)
            }
            HSplitView {
                List(model.items, selection: $model.selection) { item in
                    HStack {
                        Button {
                            model.toggle(item.url)
                        } label: {
                            Image(systemName: model.selection.contains(item.url) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(model.selection.contains(item.url) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Tick to select several items")
                        Image(systemName: item.isFolder ? "folder.fill" : "music.note")
                            .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        if !item.isFolder, model.folderTracks != nil, model.track(for: item) == nil {
                            Image(systemName: "clock.badge.questionmark")
                                .foregroundStyle(.orange)
                                .help("The player hasn't added this file to its library yet, so it can't be played from here. "
                                      + "It usually does within a few minutes; this page checks by itself. If the clock stays, "
                                      + "the player may be ignoring this file (it saw it while it was still being copied): "
                                      + "copy it again under a slightly different name, then delete this one.")
                        }
                        if let size = item.size {
                            Text(DriveModel.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tag(item.url)
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    if urls.count == 1, let url = urls.first, let item = model.items.first(where: { $0.url == url }), !item.isFolder {
                        Button("Play") { Task { await model.play(item) } }
                    }
                    // Only files the player has in its library can go into a playlist.
                    let songs = model.items.filter { urls.contains($0.url) && !$0.isFolder }.compactMap { model.track(for: $0) }
                    if !songs.isEmpty {
                        AddToPlaylistMenu { songs }
                    }
                } primaryAction: { urls in
                    guard urls.count == 1, let url = urls.first, let item = model.items.first(where: { $0.url == url }) else { return }
                    if item.isFolder {
                        model.open(url)
                    } else {
                        Task { await model.play(item) }  // double-click a music file: play it
                    }
                }
                .onChange(of: model.selection) { model.selectionChanged() }
                .overlay {
                    if let error = model.listError {
                        ContentUnavailableView {
                            Label("Can't read this folder", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Reconnect") { Task { await model.reconnect() } }
                        }
                    } else if model.isLoadingFolder {
                        ProgressView("Opening folder…")
                    } else if model.items.isEmpty {
                        ContentUnavailableView("Empty folder", systemImage: "folder")
                    }
                }
                .frame(minWidth: 320, idealWidth: 460)

                DriveDetails()
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard model.dropBlocker == nil, !model.isUploading else { return false }
                Task { await model.prepareUpload(urls, extensions: await player.supportedExtensions()) }
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(model.dropBlocker == nil ? Color.accentColor : .red, lineWidth: 3)
                        .background(.background.opacity(0.85))
                        .overlay {
                            Label(model.dropBlocker ?? "Drop to copy into “\(model.breadcrumbs.last?.name ?? "")”",
                                  systemImage: model.dropBlocker == nil ? "square.and.arrow.down.on.square" : "nosign")
                                .font(.title2)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                } else if model.isPlanningUpload {
                    ProgressView("Looking at what you dropped…").padding().background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
        }
        .confirmationDialog(
            "Tidy up Mac leftovers?",
            isPresented: Binding(get: { model.pendingTidy != nil }, set: { if !$0 { model.cancelTidy() } }),
            titleVisibility: .visible,
            presenting: model.pendingTidy
        ) { pending in
            Button("Remove \(pending.urls.count) Leftover File\(pending.urls.count == 1 ? "" : "s")", role: .destructive) {
                Task { await model.confirmTidy(pending) }
            }
            Button("Cancel", role: .cancel) { model.cancelTidy() }
        } message: { pending in
            Text("Found \(pending.urls.count) hidden Mac leftover files in “\(pending.folderName)” and its subfolders: "
                 + "“._” companion files, “.DS_Store” folder settings and unfinished upload copies. "
                 + "The player never uses them. Music files are not touched. This can't be undone, "
                 + "but nothing of value is lost. At about 1 file per second this can take a while; you can stop it at any time.")
        }
        .confirmationDialog(
            "Copy to the player?",
            isPresented: Binding(get: { model.pendingUpload != nil }, set: { if !$0 { model.cancelUpload() } }),
            titleVisibility: .visible,
            presenting: model.pendingUpload
        ) { plan in
            Button("Copy \(plan.items.count) File\(plan.items.count == 1 ? "" : "s")") {
                Task { await model.confirmUpload(plan) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.cancelUpload() }
        } message: { plan in
            Text(uploadText(plan))
        }
        .confirmationDialog(
            "Delete from the player?",
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible,
            presenting: model.pendingDeletion
        ) { pending in
            Button("Delete \(pending.names.count == 1 ? "“\(pending.names[0])”" : "\(pending.names.count) Items")",
                   role: .destructive) {
                Task { await model.confirmDelete(pending) }
            }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: { pending in
            Text(confirmationText(pending))
        }
    }

    private func uploadText(_ plan: UploadPlan) -> String {
        let folder = model.breadcrumbs.map(\.name).joined(separator: " › ")
        let shown = plan.items.prefix(5).map { "• \($0.source.lastPathComponent)" }.joined(separator: "\n")
        let more = plan.items.count > 5 ? "\n…and \(plan.items.count - 5) more" : ""
        return "\(plan.items.count) music file\(plan.items.count == 1 ? "" : "s"), \(DriveModel.bytes(plan.totalBytes)), into:\n\(folder)\n\n"
            + "\(shown)\(more)\n\nNothing on the player is overwritten; folders keep their structure."
            + DriveModel.skipSummary(plan.skipped)
    }

    private func confirmationText(_ pending: DriveModel.PendingDeletion) -> String {
        let shown = pending.names.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        let more = pending.names.count > 5 ? "\n…and \(pending.names.count - 5) more" : ""
        let size = pending.size.map { ", \(DriveModel.bytes($0))," } ?? " (size still being counted)"
        return "\(shown)\(more)\n\n\(pending.summary.files) files\(size) "
            + "will be permanently deleted from the player's drive. This can't be undone: the player has no Trash. "
            + "Nothing on this Mac is touched."
            + (pending.onlyCopyWarning.map { "\n\n⚠️ \($0)" } ?? "")
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button {
                if let parent = model.breadcrumbs.dropLast().last { model.open(parent.url) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.breadcrumbs.count < 2)
            .help("Up one folder")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        Button(crumb.name) { model.open(crumb.url) }
                            .buttonStyle(.borderless)
                            .fontWeight(index == model.breadcrumbs.count - 1 ? .semibold : .regular)
                    }
                }
            }
            Spacer()
            if let free = model.drive?.freeBytes, let total = model.drive?.totalBytes {
                Text("\(DriveModel.bytes(free)) free of \(DriveModel.bytes(total))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.requestTidy() }
            } label: {
                if model.isScanningLeftovers {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Tidy Up…", systemImage: "sparkles")
                }
            }
            .disabled(model.isUploading || model.isDeleting || model.isScanningLeftovers)
            .help("Remove hidden Mac leftovers (._ files, .DS_Store) from this folder and everything inside it. Music is never touched.")
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload this folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Right-hand panel: what's selected, and the Delete button.
struct DriveDetails: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        let selected = model.items.filter { model.selection.contains($0.url) }
        Form {
            if selected.isEmpty {
                Text("Select a folder or file to see its size, and whether the original is still on this Mac. "
                     + "Tick the boxes to select several. Double-click a folder to open it. "
                     + "Double-click a music file to play it. Drag music from Finder onto the list to copy it into this folder.")
                    .foregroundStyle(.secondary)
            } else {
                Section(selected.count == 1 ? selected[0].name : "\(selected.count) items selected") {
                    if selected.count == 1 {
                        LabeledContent("On the player") {
                            Text(model.relativePath(selected[0].url)).textSelection(.enabled)
                        }
                        LabeledContent("Kind", value: selected[0].isFolder ? "Folder" : "File")
                    }
                    LabeledContent("Contains") {
                        if let summary = model.selectionSummary {
                            VStack(alignment: .trailing) {
                                Text("\(summary.files) files"
                                     + (summary.junkFiles > 0 ? " (\(summary.junkFiles) of them Mac leftovers)" : ""))
                                if let size = model.selectionSize {
                                    Text(DriveModel.bytes(size))
                                } else {
                                    Text("counting size…").foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if selected.count == 1 {
                        LabeledContent("Original") { originalText(model.originalStatus(selected[0].url)) }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        Task { await model.requestDelete() }
                    } label: {
                        Label(model.isDeleting ? "Deleting…" : "Delete from Player…", systemImage: "trash")
                    }
                    .disabled(model.deleteBlocker != nil || model.isDeleting)
                    if let blocker = model.deleteBlocker, blocker != "Nothing selected" {
                        Text(blocker).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Deleting from the player is permanent. You'll see exactly what will be removed and confirm first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func originalText(_ status: OriginalLocator.Status) -> some View {
        switch status {
        case .onThisMac(let url):
            Label("Still on this Mac: \(url.path)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing(let url):
            Label("Not found on this Mac (\(url.path))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .otherComputer(let name):
            Label("From \(name): the player may have the only copy!", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unknown:
            Text("Unknown").foregroundStyle(.secondary)
        }
    }
}
