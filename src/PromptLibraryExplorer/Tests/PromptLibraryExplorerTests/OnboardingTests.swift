import XCTest
@testable import PromptLibraryExplorer

// MARK: - Tip scheduling rules

final class TipSchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let calm = TipConditions()

    func testTipShowsOnceOnly() {
        var scheduler = TipScheduler()
        XCTAssertTrue(scheduler.request(.lightboxOpened, now: t0))
        XCTAssertEqual(scheduler.nextTip(now: t0, conditions: calm), .lightboxOpened)
        XCTAssertEqual(scheduler.activeTip, .lightboxOpened)
        scheduler.dismissActive()

        // Much later, the same moment again: never shown twice.
        let later = t0.addingTimeInterval(3600)
        XCTAssertFalse(scheduler.request(.lightboxOpened, now: later))
        XCTAssertNil(scheduler.nextTip(now: later, conditions: calm))
        XCTAssertEqual(scheduler.blockReason(for: .lightboxOpened, now: later, conditions: calm), .alreadyShown)
    }

    func testAtMostOneTipPerMinute() {
        var scheduler = TipScheduler()
        scheduler.request(.promptSelected, now: t0)
        XCTAssertEqual(scheduler.nextTip(now: t0, conditions: calm), .promptSelected)
        scheduler.dismissActive()

        let soon = t0.addingTimeInterval(10)
        scheduler.request(.compareSelection, now: soon)
        XCTAssertNil(scheduler.nextTip(now: soon, conditions: calm))
        XCTAssertEqual(scheduler.blockReason(for: .compareSelection, now: soon, conditions: calm), .rateLimited)

        // Still waiting a minute after the first tip: shows then.
        let afterMinute = t0.addingTimeInterval(TipScheduler.minimumInterval + 1)
        XCTAssertEqual(scheduler.nextTip(now: afterMinute, conditions: calm), .compareSelection)
    }

    func testOnlyOneTipAtATime() {
        var scheduler = TipScheduler()
        scheduler.request(.largeFolder, now: t0)
        scheduler.request(.firstCollection, now: t0)
        XCTAssertEqual(scheduler.nextTip(now: t0, conditions: calm), .largeFolder)
        let muchLater = t0.addingTimeInterval(90)
        scheduler.request(.firstCollection, now: muchLater)
        XCTAssertNil(scheduler.nextTip(now: muchLater, conditions: calm), "an active tip blocks the next one")
        XCTAssertEqual(scheduler.blockReason(for: .firstCollection, now: muchLater, conditions: calm), .anotherTipShowing)
        scheduler.dismissActive()
        XCTAssertEqual(scheduler.nextTip(now: muchLater, conditions: calm), .firstCollection)
    }

    func testSuppressedWhileModalOpenThenShows() {
        var scheduler = TipScheduler()
        scheduler.request(.indexingFinished, now: t0)
        let modal = TipConditions(isModalOpen: true, isTyping: false)
        XCTAssertNil(scheduler.nextTip(now: t0, conditions: modal))
        XCTAssertEqual(scheduler.blockReason(for: .indexingFinished, now: t0, conditions: modal), .modalOpen)
        XCTAssertEqual(scheduler.pending.map(\.tip), [.indexingFinished], "it waits for the sheet to close")
        XCTAssertEqual(scheduler.nextTip(now: t0.addingTimeInterval(5), conditions: calm), .indexingFinished)
    }

    func testSuppressedWhileTyping() {
        var scheduler = TipScheduler()
        scheduler.request(.videoSelected, now: t0)
        let typing = TipConditions(isModalOpen: false, isTyping: true)
        XCTAssertNil(scheduler.nextTip(now: t0, conditions: typing))
        XCTAssertEqual(scheduler.blockReason(for: .videoSelected, now: t0, conditions: typing), .typing)
        XCTAssertEqual(scheduler.nextTip(now: t0.addingTimeInterval(2), conditions: calm), .videoSelected)
    }

    func testGlobalOffSwitch() {
        var scheduler = TipScheduler(tipsEnabled: false)
        XCTAssertFalse(scheduler.request(.firstExport, now: t0))
        XCTAssertNil(scheduler.nextTip(now: t0, conditions: calm))
        XCTAssertEqual(scheduler.blockReason(for: .firstExport, now: t0, conditions: calm), .tipsDisabled)

        // "Don't Show Tips" from an active tip: it goes, and nothing waits.
        var on = TipScheduler()
        on.request(.firstExport, now: t0)
        on.request(.largeFolder, now: t0)
        XCTAssertEqual(on.nextTip(now: t0, conditions: calm), .firstExport)
        on.disableAll()
        XCTAssertNil(on.activeTip)
        XCTAssertTrue(on.pending.isEmpty)
        XCTAssertNil(on.nextTip(now: t0.addingTimeInterval(120), conditions: calm))
    }

    func testPendingRequestExpires() {
        var scheduler = TipScheduler()
        scheduler.request(.largeFolder, now: t0)
        let modal = TipConditions(isModalOpen: true)
        XCTAssertNil(scheduler.nextTip(now: t0, conditions: modal))
        let expired = t0.addingTimeInterval(TipScheduler.pendingLifetime + 1)
        XCTAssertNil(scheduler.nextTip(now: expired, conditions: calm))
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertFalse(scheduler.shown.contains(.largeFolder), "an expired tip can come back at its next moment")
    }

    func testWithdrawAndRelevance() {
        var scheduler = TipScheduler()
        scheduler.request(.lightboxOpened, now: t0)
        scheduler.withdraw(.lightboxOpened)
        XCTAssertNil(scheduler.nextTip(now: t0, conditions: calm))

        scheduler.request(.compareSelection, now: t0)
        XCTAssertNil(scheduler.nextTip(now: t0, conditions: calm, isRelevant: { _ in false }))
        XCTAssertEqual(scheduler.pending.map(\.tip), [.compareSelection])
        XCTAssertEqual(scheduler.nextTip(now: t0, conditions: calm, isRelevant: { _ in true }), .compareSelection)
    }

    func testResetAllowsEveryTipAgain() {
        var scheduler = TipScheduler(tipsEnabled: false, shown: Set(OnboardingTip.allCases))
        scheduler.reset()
        XCTAssertTrue(scheduler.tipsEnabled)
        XCTAssertTrue(scheduler.shown.isEmpty)
        XCTAssertTrue(scheduler.request(.promptSelected, now: t0))
        XCTAssertEqual(scheduler.nextTip(now: t0, conditions: calm), .promptSelected)
    }

    func testEveryTipHasContent() {
        XCTAssertEqual(OnboardingTip.allCases.count, 8)
        let entryIDs = Set(HelpContent.referenceEntries.map(\.id))
        for tip in OnboardingTip.allCases {
            XCTAssertFalse(tip.title.isEmpty)
            XCTAssertFalse(tip.message.isEmpty)
            XCTAssertLessThan(tip.message.count, 220, "\(tip) should stay two or three lines")
            XCTAssertTrue(entryIDs.contains(tip.helpEntryID), "\(tip) points at a missing Help entry")
        }
    }
}

// MARK: - Tips controller (persistence, conditions)

@MainActor
final class OnboardingTipsControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSince1970: 2_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingTipsControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> OnboardingTipsController {
        OnboardingTipsController(defaults: defaults, clock: { [unowned self] in self.now }, pollsAutomatically: false)
    }

    func testShownStatePersists() {
        let controller = makeController()
        controller.request(.lightboxOpened)
        XCTAssertEqual(controller.activeTip, .lightboxOpened)
        controller.dismissActive()

        let relaunched = makeController()
        XCTAssertTrue(relaunched.hasShown(.lightboxOpened))
        relaunched.request(.lightboxOpened)
        XCTAssertNil(relaunched.activeTip)
    }

    func testGlobalSwitchPersistsAndResetClears() {
        let controller = makeController()
        controller.disableAll()
        XCTAssertFalse(makeController().tipsEnabled)
        controller.request(.promptSelected)
        XCTAssertNil(controller.activeTip)

        controller.reset()
        let relaunched = makeController()
        XCTAssertTrue(relaunched.tipsEnabled)
        relaunched.request(.promptSelected)
        XCTAssertEqual(relaunched.activeTip, .promptSelected)
    }

    func testWaitsForModalThenShowsOnEvaluate() {
        let controller = makeController()
        var modal = true
        controller.conditionsProvider = { TipConditions(isModalOpen: modal) }
        controller.request(.firstExport)
        XCTAssertNil(controller.activeTip)
        modal = false
        now = now.addingTimeInterval(3)
        controller.evaluate()
        XCTAssertEqual(controller.activeTip, .firstExport)
    }

    func testActiveTipRetiredWhenNoLongerRelevant() {
        let controller = makeController()
        var lightboxOpen = true
        controller.relevance = { tip in tip == .lightboxOpened ? lightboxOpen : true }
        controller.request(.lightboxOpened)
        XCTAssertEqual(controller.activeTip, .lightboxOpened)
        lightboxOpen = false
        controller.evaluate()
        XCTAssertNil(controller.activeTip)
        XCTAssertTrue(controller.hasShown(.lightboxOpened))
    }
}

// MARK: - Welcome tour paging

final class WelcomeTourStateTests: XCTestCase {
    func testTourIsShort() {
        XCTAssertTrue((5...7).contains(WelcomeTourPage.allCases.count))
        for page in WelcomeTourPage.allCases {
            XCTAssertFalse(page.headline.isEmpty)
            XCTAssertLessThan(page.body.count, 260, "\(page) should stay two or three lines")
            XCTAssertFalse(page.symbol.isEmpty)
        }
    }

    func testPagingWithKeys() {
        var state = WelcomeTourState()
        XCTAssertTrue(state.isFirst)
        XCTAssertEqual(state.page, .welcome)
        XCTAssertEqual(state.handle(.left), .ignored, "← on the first page does nothing")
        XCTAssertEqual(state.handle(.right), .moved)
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(state.handle(.returnKey), .moved)
        XCTAssertEqual(state.index, 2)
        XCTAssertEqual(state.handle(.left), .moved)
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(state.handle(.escape), .skip)
        XCTAssertEqual(state.index, 1, "Esc skips without paging")
    }

    func testLastPageFinishes() {
        var state = WelcomeTourState()
        state.go(to: 99)
        XCTAssertTrue(state.isLast)
        XCTAssertEqual(state.index, WelcomeTourPage.allCases.count - 1)
        XCTAssertEqual(state.handle(.right), .ignored)
        XCTAssertEqual(state.handle(.returnKey), .finish)
        state.go(to: -3)
        XCTAssertTrue(state.isFirst)
    }

    @MainActor
    func testFirstLaunchOnlyOnce() {
        let suite = "WelcomeTourStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OnboardingController(defaults: defaults)
        XCTAssertTrue(controller.presentTourIfFirstLaunch())
        XCTAssertTrue(controller.isTourPresented)
        controller.finishTour(running: .dataSettings)
        XCTAssertFalse(controller.isTourPresented)
        XCTAssertEqual(controller.takePendingCommand(), .dataSettings)
        XCTAssertNil(controller.takePendingCommand())

        let relaunched = OnboardingController(defaults: defaults)
        XCTAssertFalse(relaunched.presentTourIfFirstLaunch())
        relaunched.presentTour()
        XCTAssertTrue(relaunched.isTourPresented, "Help ▸ Welcome Tour… always works")
    }
}

// MARK: - Help reference and search

final class HelpSearchTests: XCTestCase {
    private let entries = HelpContent.referenceEntries

    private func ids(_ query: String) -> Set<String> {
        Set(HelpSearch.filter(entries, query: query).map(\.id))
    }

    func testEverySectionHasContentAndIDsAreUnique() {
        let all = entries.map(\.id)
        XCTAssertEqual(all.count, Set(all).count, "duplicate Help entry ids")
        for section in HelpSectionID.allCases where section != .keyboard {
            XCTAssertFalse(entries.filter { $0.section == section }.isEmpty, "\(section) has no entries")
        }
        XCTAssertFalse(HelpContent.shortcutGroups.isEmpty)
        // Every file-type description is part of the reference.
        for fileType in HelpContent.fileTypes {
            XCTAssertNotNil(HelpContent.entry(withID: fileType.id), "\(fileType.id) missing from Help")
        }
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(HelpSearch.filter(entries, query: "   ").count, entries.count)
        XCTAssertEqual(HelpSearch.filter(HelpContent.shortcutGroups, query: "").count, HelpContent.shortcutGroups.count)
    }

    func testFindsFeaturesByNameKeywordAndKey() {
        XCTAssertTrue(ids("similar images").contains("visual-search"))
        XCTAssertTrue(ids("dedupe").contains("visual-search"), "keywords are searched")
        XCTAssertTrue(ids("⌘K").contains("command-palette"), "⌘ is spelled out as cmd")
        XCTAssertTrue(ids("cmd k").contains("command-palette"))
        XCTAssertTrue(ids("STRIP metadata").contains("privacy-export"), "case-insensitive")
    }

    func testColourAndColorBothMatch() {
        XCTAssertEqual(ids("colour label"), ids("color label"))
        XCTAssertTrue(ids("color label").contains("culling"))
    }

    func testAllWordsMustMatch() {
        let both = ids("trim gif")
        XCTAssertTrue(both.contains("video-audio-tools"))
        XCTAssertFalse(both.contains("culling"))
        XCTAssertTrue(ids("zzqx nothing matches this").isEmpty)
    }

    func testShortcutFilteringKeepsMatchingItems() {
        let zoom = HelpSearch.filter(HelpContent.shortcutGroups, query: "zoom")
        XCTAssertFalse(zoom.isEmpty)
        for group in zoom {
            let groupMatches = HelpSearch.normalized(group.title + group.description).contains("zoom")
            if !groupMatches {
                XCTAssertTrue(group.items.allSatisfy { HelpSearch.normalized($0.description + $0.keys.joined()).contains("zoom") || HelpSearch.normalized(group.title).contains("zoom") })
            }
        }
        let lightbox = HelpSearch.filter(HelpContent.shortcutGroups, query: "lightbox")
        XCTAssertTrue(lightbox.contains { $0.id == "lightbox" })
        XCTAssertTrue(HelpSearch.filter(HelpContent.shortcutGroups, query: "zzqx").isEmpty)
    }

    func testPaletteHelpRowsMatchByNameAndTipTitle() {
        let culling = try? XCTUnwrap(HelpContent.entry(withID: "culling"))
        XCTAssertNotNil(culling)
        if let culling {
            XCTAssertTrue(HelpPaletteMatch.matches("flags", entry: culling))
            XCTAssertTrue(HelpPaletteMatch.matches("cull right here", entry: culling), "a tip's title finds its topic")
            XCTAssertFalse(HelpPaletteMatch.matches("", entry: culling))
        }
        XCTAssertTrue(HelpPaletteMatch.matches("tour", texts: ["Help: Welcome Tour"]))
    }
}

// MARK: - Every "Show Me" is a real command

final class HelpCommandTests: XCTestCase {
    /// Every command reachable from Help, a tip or the tour.
    private var usedCommands: [HelpCommand] {
        HelpContent.showMeCommands
            + OnboardingTip.allCases.compactMap(\.action)
            + WelcomeTourPage.allCases.compactMap(\.tryIt)
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PromptLibraryExplorerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testEveryShowMeMapsToAMenuItemOrSettingsPage() throws {
        let app = try source("PromptLibraryExplorer/App/PromptLibraryExplorerApp.swift")
        let standardMenus: Set<String> = ["File", "Edit", "View", "Help"]
        XCTAssertFalse(HelpContent.showMeCommands.isEmpty)

        // Help's Show Me buttons, tip actions and tour Try it buttons all come from
        // HelpCommand, so checking every case covers each of them.
        XCTAssertTrue(Set(usedCommands).isSubset(of: Set(HelpCommand.allCases)))
        for command in HelpCommand.allCases {
            XCTAssertFalse(command.menuPath == nil && command.settingsPage == nil,
                           "\(command) maps to neither a menu item nor a Settings page")
            if let path = command.menuPath {
                XCTAssertGreaterThanOrEqual(path.count, 2, "\(command)")
                let top = path[0]
                XCTAssertTrue(standardMenus.contains(top) || app.contains("CommandMenu(\"\(top)\")"),
                              "\(command): no \(top) menu")
                for title in path.dropFirst() {
                    XCTAssertTrue(app.contains("\"\(title)\""),
                                  "\(command): the App menus have no item titled \"\(title)\"")
                }
            }
            if let page = command.settingsPage {
                XCTAssertTrue(SettingsPage.allCases.contains(page))
            }
            XCTAssertFalse(command.tryItTitle.isEmpty)
        }
    }

    func testEveryCommandIsCovered() {
        // Every command has a location people can read in Help.
        for command in HelpCommand.allCases {
            XCTAssertFalse(command.locationText.isEmpty, "\(command)")
            XCTAssertFalse(command.locationText.contains("..."), "\(command) shows ASCII dots")
        }
    }
}
