import HAPKit
import SwiftUI

/// The window: a hi-fi rack, an HDD player on top of an amplifier.
struct RackView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(CoverArtStore.self) private var covers
    @Environment(DriveModel.self) private var drive
    @Environment(RackState.self) private var rack
    @Environment(PlaylistStore.self) private var playlists

    var body: some View {
        VStack(spacing: 10) {
            HAPFaceplate().frame(maxHeight: .infinity)
            AmpFaceplate().frame(height: 150)
        }
        .padding(14)
        .background(Color(white: 0.12))
        .onAppear { rack.folders = drive }  // BACK and the FOLDERS switch move through folders
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshLibrary() }
                } label: {
                    Label("Refresh Library", systemImage: model.isRefreshingLibrary ? "arrow.clockwise.circle" : "arrow.clockwise")
                }
                .disabled(model.device == nil || model.isRefreshingLibrary)
                .help("Download the library lists from the player again")
            }
        }
        .confirmationDialog(
            "Delete from the player?",
            isPresented: Binding(get: { drive.pendingTrackDeletion != nil }, set: { if !$0 { drive.cancelTrackDeletion() } }),
            titleVisibility: .visible,
            presenting: drive.pendingTrackDeletion
        ) { pending in
            Button("Delete \(countText(pending.tracks.count, "Track"))", role: .destructive) {
                Task { await drive.confirmTrackDeletion(pending) }
            }
            Button("Cancel", role: .cancel) { drive.cancelTrackDeletion() }
        } message: { pending in
            Text(trackDeletionText(pending))
        }
        .overlay(alignment: .top) {
            if !onDrivePage, drive.isDeleting || drive.isPreparingTrackDeletion || (drive.lastResult != nil && drive.pendingTrackDeletion == nil) {
                HStack(spacing: 10) {
                    if drive.isDeleting {
                        ProgressView(value: Double(drive.deletedFiles), total: Double(max(drive.filesToDelete, 1))).frame(width: 120)
                        Text("Deleting… \(drive.deletedFiles) of \(drive.filesToDelete)").monospacedDigit()
                        Button("Stop") { drive.stopDeleting() }
                    } else if drive.isPreparingTrackDeletion {
                        ProgressView().controlSize(.small)
                        Text("Finding the files…")
                    } else if let result = drive.lastResult {
                        Text(result).lineLimit(2)
                        Button("OK") { drive.dismissResult() }
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .top) {
            if let problem = playlists.lastError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).lineLimit(2)
                    Button("OK") { playlists.dismissError() }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
            } else if let message = playlists.lastMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3))
                        if playlists.lastMessage == message { playlists.lastMessage = nil }
                    }
            }
        }
        .overlay(alignment: .top) {
            if let summary = covers.lastSummary {
                Text(summary)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .task(id: summary) {
                        try? await Task.sleep(for: .seconds(8))
                        if covers.lastSummary == summary { covers.clearSummary() }
                    }
            }
        }
    }

    /// The Drive page shows its own progress and results.
    private var onDrivePage: Bool { rack.mode == .section && rack.section == .folders }

    private func trackDeletionText(_ pending: DriveModel.PendingTrackDeletion) -> String {
        let names = pending.tracks.prefix(6).map { "• \($0.name) — \(named($0.artist?.name, "?"))" }.joined(separator: "\n")
        let more = pending.tracks.count > 6 ? "\n…and \(pending.tracks.count - 6) more" : ""
        var text = "\(names)\(more)\n\nTheir files are permanently deleted from the player's drive. This can't be undone: "
            + "the player has no Trash. Nothing on this Mac is touched."
        if !pending.unlocated.isEmpty {
            text += "\n\n\(countText(pending.unlocated.count, "track")) couldn't be found on the drive and will be left alone."
        }
        if let warning = pending.onlyCopyWarning { text += "\n\n⚠️ \(warning)" }
        return text
    }
}
