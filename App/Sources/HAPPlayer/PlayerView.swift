import HAPKit
import SwiftUI

/// The player's status: what's loaded, the device, the library.
struct PlayerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Group {
            switch model.connection {
            case .searching:
                ProgressView("Looking for the player on the network…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Player not found", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.connect() } }
                }
            case .connected:
                connected
            }
        }
        .navigationTitle("Status")
    }

    private var connected: some View {
        Form {
            Section("Now Playing") {
                if let content = model.content, content.title != nil {
                    HStack(alignment: .top, spacing: 16) {
                        Group {
                            if let track = model.currentTrack, let album = model.album(of: track) {
                                ArtworkView(album: album, cornerRadius: 8)
                            } else {
                                GeneratedArt(title: content.albumName ?? "", subtitle: content.artist ?? "")
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .frame(width: 120, height: 120)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(content.title ?? "").font(.title2.weight(.semibold))
                            Text(named(content.artist, "Unknown artist")).font(.title3)
                            Text(named(content.albumName, "Unknown album")).foregroundStyle(.secondary)
                            Text([content.state?.capitalized, content.formatDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("Nothing loaded").foregroundStyle(.secondary)
                }
            }
            Section("Player") {
                LabeledContent("Name", value: model.device?.friendlyName ?? "?")
                LabeledContent("Model", value: model.device?.modelName ?? "?")
                LabeledContent("Address", value: model.device?.host ?? "?")
                LabeledContent("Firmware", value: model.device?.firmwareVersion ?? "?")
                LabeledContent("Power", value: model.power?.status ?? "?")
            }
            if let library = model.library {
                Section("Library") {
                    LabeledContent("Albums", value: "\(library.albums.count)")
                    LabeledContent("Artists", value: "\(library.artists.count)")
                    LabeledContent("Tracks", value: "\(library.tracks.count)")
                    LabeledContent("Genres", value: "\(library.genres.count)")
                    LabeledContent("Updated", value: library.fetchedAt.formatted(.relative(presentation: .named)))
                }
            }
        }
        .formStyle(.grouped)
    }
}
