import Foundation
import Observation

/// The amp's round switches (they replace the old sidebar).
enum RackSection: String, CaseIterable, Identifiable {
    case albums, artists, genres, tracks, playlists, folders

    var id: Self { self }
    /// Printed on the panel above the switch.
    var label: String { rawValue.uppercased() }
    var title: String { rawValue.capitalized }
}

/// What the big screen shows: a section's pages, or one of the HAP's own screens.
enum ScreenMode: Equatable {
    case section, home, nowPlaying, playerInfo
}

/// The Drive page's folder browsing, as far as BACK and the FOLDERS switch need it.
@MainActor
protocol DriveNavigation: AnyObject {
    /// How many folders down from the drive's top (0 = at the top).
    var folderDepth: Int { get }
    func goUpFolder()
    func goToTopFolder()
}

/// Where the user is in the rack: which switch is lit, what the screen shows, and what the
/// HAP's BACK and ENTER buttons do right now.
@MainActor @Observable
final class RackState {
    private(set) var section: RackSection
    private(set) var mode: ScreenMode = .section
    /// Pages opened inside the section (album, artist, genre), newest last.
    var path: [Page] = []
    var search = ""
    /// Goes up by one for ⌘F / "Search"; the screen's search field takes focus when it changes.
    private(set) var searchFocusRequests = 0
    /// A name a page adds to the screen's title (e.g. the chosen playlist).
    var pageName: String?
    /// Where the screen is in the window (SwiftUI coordinates), for the VOLUME knob.
    @ObservationIgnored var screenFrame: CGRect = .zero
    /// The Drive page, so BACK can go up a folder there.
    @ObservationIgnored weak var folders: (any DriveNavigation)?
    /// Track skips from the HAP dial and ⌘→/⌘←, sent one at a time through one queue.
    @ObservationIgnored let skipper = DialSkipper()

    /// What ENTER does: the newest page on screen wins. Each page adds its own when it appears
    /// and removes it by id when it goes away, so a page leaving late can't remove its
    /// successor's, and closing a page gives ENTER back to the page underneath.
    @ObservationIgnored private var enterStack: [(id: UUID, action: @MainActor () -> Void)] = []
    @ObservationIgnored private let defaults: UserDefaults
    static let sectionKey = "rackSection"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        section = defaults.string(forKey: Self.sectionKey).flatMap(RackSection.init(rawValue:)) ?? .albums
    }

    /// A round switch: shows that section's start page (also when it's already lit; for
    /// FOLDERS that means the drive's top folder).
    func select(_ newSection: RackSection) {
        if newSection == .folders, section == .folders, mode == .section, search.isEmpty, folderDepth > 0 {
            folders?.goToTopFolder()
        }
        path = []
        search = ""
        mode = .section
        section = newSection
        defaults.set(newSection.rawValue, forKey: Self.sectionKey)
    }

    /// HOME, Now Playing, Playlists, Player info. The section underneath is kept for BACK.
    func show(_ newMode: ScreenMode) { mode = newMode }

    /// Opens a page (e.g. the playing album) in the current section.
    func open(_ page: Page) {
        mode = .section
        path = [page]
    }

    func requestSearch() {
        mode = .section
        searchFocusRequests += 1
    }

    /// BACK: first leaves HOME and the other HAP screens, then goes back one page, then
    /// clears the search (so from an album found by searching you return to the results),
    /// then, in FOLDERS, goes up one folder.
    func back() {
        if mode != .section {
            mode = .section
        } else if !path.isEmpty {
            path.removeLast()
        } else if !search.isEmpty {
            search = ""
        } else if folderDepth > 0 {
            folders?.goUpFolder()
        }
    }

    var canGoBack: Bool { mode != .section || !path.isEmpty || !search.isEmpty || folderDepth > 0 }

    /// Folders below the drive's top, counted only while the FOLDERS page is showing.
    private var folderDepth: Int {
        section == .folders && mode == .section ? (folders?.folderDepth ?? 0) : 0
    }

    func setEnter(_ id: UUID, _ action: @escaping @MainActor () -> Void) {
        enterStack.removeAll { $0.id == id }  // a page appearing again moves to the top
        enterStack.append((id, action))
    }

    func clearEnter(_ id: UUID) { enterStack.removeAll { $0.id == id } }

    func pressEnter() { enterStack.last?.action() }

    var hasEnter: Bool { !enterStack.isEmpty }
}

/// Holds a page's newest ENTER action. The page registers `run` once and refreshes `action`
/// each time it's drawn, so ENTER always uses the list the page shows now.
@MainActor
final class EnterActionBox {
    var action: @MainActor () -> Void = {}
    func run() { action() }
}
