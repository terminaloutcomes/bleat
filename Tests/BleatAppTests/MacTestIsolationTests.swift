#if BLEAT_MACOS_TESTING
    import AppKit
    import SwiftUI
    import BleatCore
    import XCTest

    @testable import Bleat

    @MainActor
    final class MacTestIsolationTests: XCTestCase {
        func
            testAccountEditorCredentialFieldsAvoidBrokenAutoFillSheetLifecycle()
            async throws
        {
            let host = NSHostingView(
                rootView: VStack {
                    AccountEditorCredentialFields(
                        username: .constant("synthetic-reader"),
                        password: .constant(""))
                }.frame(width: 500, height: 140))
            let parent = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 140),
                styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            sheet.isReleasedWhenClosed = false
            sheet.contentView = host
            defer {
                if parent.attachedSheet != nil { parent.endSheet(sheet) }
                sheet.close()
                parent.close()
            }
            let dismissed = expectation(
                description: "native account sheet completes ordinary dismissal"
            )
            parent.beginSheet(sheet) { @Sendable _ in dismissed.fulfill() }
            host.layoutSubtreeIfNeeded()
            func fields(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] }
                    ?? view.subviews.flatMap { fields(in: $0) }
            }
            let inputs = fields(in: host).filter(\.isEditable)
            let password = try XCTUnwrap(
                inputs.compactMap { $0 as? NSSecureTextField }.first)
            let username = try XCTUnwrap(
                inputs.first { !($0 is NSSecureTextField) })
            if #available(macOS 27, *) {
                XCTAssertNil(username.contentType)
                XCTAssertNil(password.contentType)
            } else {
                XCTAssertEqual(username.contentType, .username)
                XCTAssertEqual(password.contentType, .password)
            }
            XCTAssertTrue(parent.attachedSheet === sheet)
            // Rapid programmatic focus changes otherwise synchronously flush
            // AppKit's unrelated prose/data-detector startup. The retained
            // warning stack identifies NSSpellChecker, not AutoFill teardown.
            // Keep this synthetic credential fixture free of prose services;
            // native responder changes and ordinary sheet dismissal still run.
            let editor = try XCTUnwrap(
                sheet.fieldEditor(true, for: username) as? NSTextView)
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            XCTAssertTrue(sheet.makeFirstResponder(username))
            XCTAssertTrue(sheet.makeFirstResponder(password))
            XCTAssertTrue(sheet.makeFirstResponder(nil))
            parent.endSheet(sheet)
            await fulfillment(of: [dismissed], timeout: 5)
            XCTAssertNil(parent.attachedSheet)
            XCTAssertNil(sheet.sheetParent)
        }

        func testNativeCredentialAutoFillControlUsesSemanticContentTypes()
            throws
        {
            // Control: these are the original editor's explicit registrations.
            // This does not claim to reproduce the user's OS-managed AutoFill
            // session; its exception was captured from the live process.
            let host = NSHostingView(
                rootView: VStack {
                    TextField("Username", text: .constant("synthetic-reader"))
                        .textContentType(.username)
                    SecureField("Password", text: .constant(""))
                        .textContentType(.password)
                }.frame(width: 500, height: 140))
            host.layoutSubtreeIfNeeded()
            func fields(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] }
                    ?? view.subviews.flatMap { fields(in: $0) }
            }
            let inputs = fields(in: host).filter(\.isEditable)
            let password = try XCTUnwrap(
                inputs.compactMap { $0 as? NSSecureTextField }.first)
            let username = try XCTUnwrap(
                inputs.first { !($0 is NSSecureTextField) })
            XCTAssertEqual(username.contentType, .username)
            XCTAssertEqual(password.contentType, .password)
        }

        func testStartupDiagnosticsHasVisibleBodyWithoutParentSize() {
            let model = AppModel(
                service: UnavailableAppService(),
                bootstrapError: .storedDataMigrationFailed)
            let host = NSHostingView(rootView: DiagnosticsView(model: model))
            let size = host.fittingSize
            XCTAssertGreaterThanOrEqual(size.width, 480)
            XCTAssertGreaterThanOrEqual(size.height, 420)
        }

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
