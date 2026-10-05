import Foundation
import Testing
@testable import HAPPlayer

@MainActor
struct RackStateTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "RackStateTests-\(UUID().uuidString)")!
    }

    @Test func startsOnAlbums() {
        #expect(RackState(defaults: freshDefaults()).section == .albums)
    }

    @Test func remembersTheSection() {
        let defaults = freshDefaults()
        RackState(defaults: defaults).select(.genres)
        #expect(RackState(defaults: defaults).section == .genres)
    }

    @Test func pressingTheCurrentSwitchReturnsToItsStartPage() {
        let rack = RackState(defaults: freshDefaults())
        rack.path = [.album(226)]
        rack.select(.albums)
        #expect(rack.path.isEmpty)
    }

    @Test func switchingSectionLeavesHomeAndClearsSearch() {
        let rack = RackState(defaults: freshDefaults())
        rack.search = "marley"
        rack.show(.home)
        rack.select(.tracks)
        #expect(rack.mode == .section)
        #expect(rack.search.isEmpty)
        #expect(rack.section == .tracks)
    }

    @Test func backLeavesHomeThenPagesThenSearch() {
        let rack = RackState(defaults: freshDefaults())
        rack.search = "marley"
        rack.path = [.album(226)]
        rack.show(.home)
        rack.back()
        #expect(rack.mode == .section)
        #expect(rack.path == [.album(226)])
        rack.back()
        #expect(rack.path.isEmpty)
        #expect(rack.search == "marley")  // back at the search results
        rack.back()
        #expect(rack.search.isEmpty)
        #expect(!rack.canGoBack)
    }

    @Test func searchRequestLeavesHomeAndAsksForFocus() {
        let rack = RackState(defaults: freshDefaults())
        rack.show(.home)
        rack.requestSearch()
        #expect(rack.mode == .section)
        #expect(rack.searchFocusRequests == 1)
    }

    @Test func openingAPageLeavesHome() {
        let rack = RackState(defaults: freshDefaults())
        rack.show(.nowPlaying)
        rack.open(.album(226))
        #expect(rack.mode == .section)
        #expect(rack.path == [.album(226)])
    }

    @Test func enterRunsTheCurrentPagesAction() {
        let rack = RackState(defaults: freshDefaults())
        var ran: [String] = []
        let old = UUID(), new = UUID()
        rack.setEnter(old) { ran.append("old") }
        rack.setEnter(new) { ran.append("new") }
        rack.clearEnter(old)  // the old page disappearing must not remove the new page's action
        rack.pressEnter()
        #expect(ran == ["new"])
    }

    @Test func enterDoesNothingWithoutAPageAction() {
        let rack = RackState(defaults: freshDefaults())
        let id = UUID()
        var ran = false
        rack.setEnter(id) { ran = true }
        rack.clearEnter(id)
        rack.pressEnter()
        #expect(!ran)
        #expect(!rack.hasEnter)
    }
}

@MainActor
struct EnterStackTests {
    private func fresh() -> RackState {
        RackState(defaults: UserDefaults(suiteName: "EnterStackTests-\(UUID().uuidString)")!)
    }

    @Test func leavingAPageGivesEnterBackToThePageUnderneath() {
        // An album opened from search: when it closes, ENTER belongs to the results again,
        // whether or not the results page "appears" again.
        let rack = fresh()
        var ran: [String] = []
        let results = UUID(), album = UUID()
        rack.setEnter(results) { ran.append("results") }
        rack.setEnter(album) { ran.append("album") }
        rack.clearEnter(album)
        rack.pressEnter()
        #expect(ran == ["results"])
    }

    @Test func aPageAppearingAgainIsNotCountedTwice() {
        let rack = fresh()
        var ran = 0
        let page = UUID()
        rack.setEnter(page) { ran += 1 }
        rack.setEnter(page) { ran += 1 }
        rack.clearEnter(page)
        rack.pressEnter()
        #expect(ran == 0)
    }

    @Test func enterUsesThePagesLatestAction() {
        // The page registers once, but its list can change later (more search letters, a
        // deleted track): ENTER must use what the page shows now.
        let box = EnterActionBox()
        var played = ""
        box.action = { played = "old list" }
        let rack = fresh()
        rack.setEnter(UUID(), box.run)
        box.action = { played = "new list" }
        rack.pressEnter()
        #expect(played == "new list")
    }
}

/// Stands in for the Drive page's folder browsing.
@MainActor
final class FakeFolders: DriveNavigation {
    var folderDepth: Int
    var moves: [String] = []
    init(depth: Int) { folderDepth = depth }
    func goUpFolder() { moves.append("up"); folderDepth -= 1 }
    func goToTopFolder() { moves.append("top"); folderDepth = 0 }
}

@MainActor
struct FolderBackTests {
    private func onFolders(depth: Int) -> (RackState, FakeFolders) {
        let rack = RackState(defaults: UserDefaults(suiteName: "FolderBackTests-\(UUID().uuidString)")!)
        let folders = FakeFolders(depth: depth)
        rack.folders = folders
        rack.select(.folders)
        folders.moves = []  // only count what happens after arriving
        return (rack, folders)
    }

    @Test func backGoesUpAFolder() {
        let (rack, folders) = onFolders(depth: 2)
        #expect(rack.canGoBack)
        rack.back()
        #expect(folders.moves == ["up"])
    }

    @Test func atTheDrivesTopBackHasNowhereToGo() {
        let (rack, folders) = onFolders(depth: 0)
        #expect(!rack.canGoBack)
        rack.back()
        #expect(folders.moves.isEmpty)
    }

    @Test func theFoldersSwitchAgainReturnsToTheTop() {
        let (rack, folders) = onFolders(depth: 3)
        rack.select(.folders)
        #expect(folders.moves == ["top"])
    }

    @Test func folderDepthDoesNotCountInOtherSections() {
        let (rack, folders) = onFolders(depth: 2)
        rack.select(.albums)
        #expect(!rack.canGoBack)
        rack.back()
        #expect(folders.moves.isEmpty)
    }

    @Test func homeIsLeftBeforeGoingUpAFolder() {
        let (rack, folders) = onFolders(depth: 2)
        rack.show(.home)
        rack.back()
        #expect(rack.mode == .section)
        #expect(folders.moves.isEmpty)
    }
}

@MainActor
struct SharedSkipperTests {
    @Test func theDialAndTheMenuShareOneQueue() {
        // ⌘→/⌘← and the dial go through the same queue, so the player gets one command at a time.
        let rack = RackState(defaults: UserDefaults(suiteName: "SharedSkipperTests-\(UUID().uuidString)")!)
        #expect(rack.skipper === rack.skipper)
        #expect(rack.skipper.pending == 0)
    }
}

struct PlaylistsSwitchTests {
    @Test func playlistsSwitchSitsBetweenTracksAndFolders() {
        #expect(RackSection.allCases == [.albums, .artists, .genres, .tracks, .playlists, .folders])
        #expect(RackSection.playlists.label == "PLAYLISTS")
    }
}
