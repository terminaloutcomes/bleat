#if BLEAT_MACOS_TESTING
    import BleatCore
    import XCTest

    @testable import Bleat

    @MainActor
    final class MacTestIsolationTests: XCTestCase {
        func testNativeHostAdmitsOnlyDedicatedIdentityAndRunner() {
            XCTAssertNil(MacTestHostAdmission.rejection())
            XCTAssertEqual(
                MacTestHostAdmission.rejection(
                    bundleID: "com.terminaloutcomes.Bleat", environment: [:]),
                .unexpectedIdentity)
            XCTAssertEqual(
                MacTestHostAdmission.rejection(
                    bundleID: MacTestHostAdmission.bundleID, environment: [:]),
                .missingRunnerAdmission)
        }

        func testConstructorOwnedStateDoesNotInheritAnotherModel() throws {
            let first = ModelLocalState()
            let second = ModelLocalState()
            first.preferencesStore().savePlaybackRate(2)
            let account = AccountID(rawValue: "same-account")
            let item = LibraryItemID(rawValue: "same-item")
            try first.positionStore().save(42, accountID: account, itemID: item)
            XCTAssertEqual(first.preferencesStore().playbackRate(), 2)
            XCTAssertEqual(second.preferencesStore().playbackRate(), 1)
            XCTAssertNil(
                second.positionStore().position(
                    accountID: account, itemID: item))
            XCTAssertNotEqual(first.downloadsRoot, second.downloadsRoot)
            XCTAssertFalse(ModelLocalState.registersRemoteCommands)
        }

        func testPlaybackConstructorDefaultsAreFreshAndExplicitStoreIsRetained()
        {
            let state = ModelLocalState()
            let preferences = state.preferencesStore()
            preferences.savePlaybackRate(2)
            let explicit = PlaybackModel(
                service: UnavailableAppService(), preferencesStore: preferences)
            let fresh = PlaybackModel(service: UnavailableAppService())
            XCTAssertEqual(explicit.rate, 2)
            XCTAssertEqual(fresh.rate, 1)
        }
    }
#endif
