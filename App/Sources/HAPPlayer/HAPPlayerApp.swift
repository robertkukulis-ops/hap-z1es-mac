import AppKit
import SwiftUI

@main
struct HAPPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PlayerModel()
    @State private var drive = DriveModel()
    @State private var covers = CoverArtStore()
    @State private var rack = RackState()
    @State private var playlists = PlaylistStore()

    var body: some Scene {
        // One window: the rack's state (page, search, ENTER) belongs to it.
        Window("HAP", id: "main") {
            RackView()
                .environment(model)
                .environment(drive)
                .environment(covers)
                .environment(rack)
                .environment(playlists)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    drive.covers = covers
                    await model.connect()
                }
                .onChange(of: model.libraryLoads) {
                    guard let library = model.library else { return }
                    covers.libraryLoaded(albums: library.albums, artists: library.artists.map(\.name),
                                         tracks: library.tracks, trackPaths: model.trackPaths)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            // ⌘F goes to the screen's search field (replaces the text-editing Find/Spelling
            // items, which this app doesn't use).
            CommandGroup(replacing: .textEditing) {
                Button("Find") { rack.requestSearch() }
                    .keyboardShortcut("f", modifiers: [.command])
            }
            CommandMenu("Controls") {
                Button("Play / Pause") { Task { await model.send(.playPause) } }
                    .keyboardShortcut(.space, modifiers: [.command])
                // Through the dial's queue, so the player gets one skip at a time.
                Button("Next Track") { rack.skipper.add(1, player: model) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { rack.skipper.add(-1, player: model) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Shuffle") { model.toggleShuffle() }
                Button("Repeat (Off / All / One)") { model.cycleRepeat() }
                Button("Home") { rack.show(.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Library") { Task { await model.refreshLibrary() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Find Missing Covers") {
                    covers.findMissing(albums: model.library?.albums ?? [],
                                       artists: (model.library?.artists ?? []).map(\.name))
                }
                .disabled(covers.isSearching || model.library == nil)
            }
        }
    }
}

/// Started with `swift run` there's no app bundle yet, so tell macOS this is a normal
/// app with a Dock icon and bring its window to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
