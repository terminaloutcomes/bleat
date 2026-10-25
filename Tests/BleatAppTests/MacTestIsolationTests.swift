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
            let fields = AccountEditorCredentialFields(
                username: .constant("synthetic-reader"), password: .constant("")
            )
            if #available(macOS 27, *) {
                try await exerciseCredentialSheet(
                    fields, expectedUsernameType: nil, expectedPasswordType: nil
                )
            } else {
                try await exerciseCredentialSheet(
                    fields, expectedUsernameType: .username,
                    expectedPasswordType: .password)
            }
        }

        func testNativeCredentialAutoFillControlUsesSemanticContentTypes()
            async throws
        {
            // The original registrations use exactly the same native fixture,
            // values, focus sequence and ordinary sheet dismissal as the fix.
            try await exerciseCredentialSheet(
                Group {
                    TextField("Username", text: .constant("synthetic-reader"))
                        .textContentType(.username)
                        .iOSNoAutocapitalization()
                        .accessibilityIdentifier("accountEditor.username")
                    SecureField("Password", text: .constant(""))
                        .textContentType(.password)
                        .accessibilityIdentifier("accountEditor.password")
                }, expectedUsernameType: .username,
                expectedPasswordType: .password)
        }

        private func exerciseCredentialSheet<Fields: View>(
            _ fields: Fields, expectedUsernameType: NSTextContentType?,
            expectedPasswordType: NSTextContentType?
        ) async throws {
            // AppKit's first synchronous responder flush otherwise waits for
            // data-detector initialization. Use the native background API to
            // finish that unrelated fixture preparation before changing focus.
            let checker = NSSpellChecker.shared
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            let prepared = expectation(
                description: "native background text services prepared")
            checker.requestChecking(
                of: "synthetic-reader", range: NSRange(location: 0, length: 16),
                types: NSTextCheckingResult.CheckingType.link.rawValue,
                options: nil,
                inSpellDocumentWithTag: tag
            ) { @Sendable _, _, _, _ in prepared.fulfill() }
            await fulfillment(of: [prepared], timeout: 5)
            checker.closeSpellDocument(withTag: tag)

            let host = NSHostingView(
                rootView: VStack { fields }.frame(width: 500, height: 140))
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
            func inputs(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] }
                    ?? view.subviews.flatMap { inputs(in: $0) }
            }
            let fields = inputs(in: host).filter(\.isEditable)
            let password = try XCTUnwrap(
                fields.compactMap { $0 as? NSSecureTextField }.first)
            let username = try XCTUnwrap(
                fields.first { !($0 is NSSecureTextField) })
            XCTAssertEqual(username.contentType, expectedUsernameType)
            XCTAssertEqual(password.contentType, expectedPasswordType)
            XCTAssertTrue(parent.attachedSheet === sheet)
            XCTAssertTrue(sheet.makeFirstResponder(username))
            XCTAssertTrue(sheet.makeFirstResponder(password))
            XCTAssertTrue(sheet.makeFirstResponder(nil))
            parent.endSheet(sheet)
            await fulfillment(of: [dismissed], timeout: 5)
            XCTAssertNil(parent.attachedSheet)
            XCTAssertNil(sheet.sheetParent)
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
