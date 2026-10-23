#if os(iOS)
    import BleatCore
    import MediaPlayer
    import SwiftUI
    import UIKit
    import XCTest

    @testable import Bleat

    @MainActor
    final class IPadKeyboardTests: XCTestCase {
        func testAllShortcutsAreAvailableInActiveIPadPlayback() {
            let availability = availability()

            for action in IPadKeyboardAction.allCases {
                XCTAssertTrue(availability.allows(action), "\(action)")
            }
        }

        func testTextEntryPreservesSearchAndBlocksPlaybackShortcuts() {
            let availability = availability(isEditingText: true)

            XCTAssertTrue(availability.allows(.search))
            for action in transportActions {
                XCTAssertFalse(availability.allows(action), "\(action)")
            }
        }

        func
            testShortcutsDoNotCrossDeviceAuthenticationSceneOrPresentationBoundaries()
        {
            let unavailableContexts: [(String, IPadKeyboardAvailability)] = [
                ("iPhone", availability(isPad: false)),
                ("signed out", availability(isSignedIn: false)),
                ("inactive scene", availability(isSceneActive: false)),
                (
                    "another presentation",
                    availability(isPresentationAllowed: false)
                ),
            ]

            for (context, availability) in unavailableContexts {
                for action in IPadKeyboardAction.allCases {
                    XCTAssertFalse(
                        availability.allows(action), "\(context): \(action)")
                }
            }
        }

        func testSearchRemainsAvailableWithoutPlayableMedia() {
            let availability = availability(isPlaybackAvailable: false)

            XCTAssertTrue(availability.allows(.search))
            for action in transportActions {
                XCTAssertFalse(availability.allows(action), "\(action)")
            }
        }

        func
            testRestoredSelectionCanToggleWithoutEnablingPreparedMediaCommands()
            throws
        {
            let suite = "IPadKeyboardTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            let playback = PlaybackModel(
                service: UnavailableAppService(),
                positionStore: PlaybackPositionStore(defaults: defaults),
                localSessionStore: LocalPlaybackSessionStore(
                    defaults: defaults),
                bookmarkMutationStore: BookmarkMutationStore(
                    defaults: defaults),
                preferencesStore: PlaybackPreferencesStore(defaults: defaults),
                nowPlayingCoordinator: NowPlayingCoordinator(
                    infoCenter: KeyboardNowPlayingInfoPublisher(),
                    registersRemoteCommands: false),
                audioSessionActivation: {
                    XCTFail("Restoring a selection must not activate audio")
                })
            addTeardownBlock { @MainActor in await playback.stop() }
            XCTAssertFalse(playback.isPlaybackToggleAvailable)
            XCTAssertFalse(playback.isPlaybackControlAvailable)
            let book = LibraryBookSummary(
                id: LibraryItemID(rawValue: "restored-book"),
                libraryID: LibraryID(rawValue: "test-library"),
                title: "Restored selection", subtitle: nil,
                authorName: nil, narratorName: nil, seriesName: nil,
                genres: [], publisher: nil, publishedYear: nil,
                duration: 120, trackCount: 1, chapterCount: 1,
                addedAtMilliseconds: 0, updatedAtMilliseconds: 0,
                isExplicit: false, isAbridged: false)

            playback.restoreSelection(
                LastPlayingRecord(
                    accountID: AccountID(rawValue: "test-account"), book: book))

            XCTAssertEqual(playback.state, .paused)
            XCTAssertFalse(playback.isPlaybackToggleAvailable)
            var resumeCalls = 0
            playback.resumeSelectionHandler = {
                resumeCalls += 1
                return .accepted
            }
            XCTAssertTrue(playback.isPlaybackToggleAvailable)
            XCTAssertFalse(playback.isPlaybackControlAvailable)
            let restoredAvailability = availability(
                isPlaybackAvailable: playback.isPlaybackControlAvailable,
                isToggleAvailable: playback.isPlaybackToggleAvailable)
            XCTAssertTrue(restoredAvailability.allows(.togglePlayback))
            XCTAssertTrue(restoredAvailability.allows(.search))
            for action in [
                IPadKeyboardAction.skipBackward, .skipForward, .slower, .faster,
            ] {
                XCTAssertFalse(restoredAvailability.allows(action), "\(action)")
            }

            XCTAssertEqual(playback.handleRemoteCommand(.toggle), .accepted)

            XCTAssertEqual(resumeCalls, 1)
            XCTAssertFalse(playback.isPlaybackControlAvailable)
            playback.resumeSelectionHandler = nil
            XCTAssertFalse(playback.isPlaybackToggleAvailable)
        }

        func
            testKeyboardSearchRevealsRootAndRequestsFocusWithoutDiscardingQuery()
        {
            let navigation = AppNavigationCoordinator()
            navigation.selectedTab = .library
            navigation.searchQuery = "a retained search"
            navigation.searchPath.append("book-detail")
            navigation.libraryPath.append("library-detail")
            let initialFocusRequest = navigation.keyboardSearchFocusRequest

            navigation.requestKeyboardSearch()

            XCTAssertEqual(navigation.selectedTab, .search)
            XCTAssertTrue(navigation.searchPath.isEmpty)
            XCTAssertEqual(navigation.searchQuery, "a retained search")
            XCTAssertEqual(navigation.libraryPath.count, 1)
            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest, initialFocusRequest + 1)

            navigation.requestKeyboardSearch()

            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest, initialFocusRequest + 2)
            XCTAssertEqual(navigation.searchQuery, "a retained search")
        }

        func testPlayerSearchWaitsForDismissalAndRequestsFocusExactlyOnce() {
            let navigation = AppNavigationCoordinator()
            navigation.showsPlayer = true
            navigation.searchQuery = "still searching"
            navigation.searchPath.append("book-detail")
            let initialFocusRequest = navigation.keyboardSearchFocusRequest

            navigation.requestKeyboardSearch()

            XCTAssertFalse(navigation.showsPlayer)
            XCTAssertEqual(navigation.selectedTab, .search)
            XCTAssertTrue(navigation.searchPath.isEmpty)
            XCTAssertEqual(navigation.searchQuery, "still searching")
            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest, initialFocusRequest)

            navigation.requestKeyboardSearch()
            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest, initialFocusRequest)

            navigation.keyboardPlayerDidDismiss()

            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest, initialFocusRequest + 1)

            navigation.keyboardPlayerDidDismiss()

            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest, initialFocusRequest + 1)
        }

        func testHostedScopeExposesPublicShortcutRegistrationAndGuardedSearch()
            async throws
        {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive },
                "The app-host probe requires its normal foreground scene")
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let suite = "IPadKeyboardHostingTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let service = UITestAppService(scenario: .signedIn)
            let serviceRoot = await service.downloadsStorageRootURL
            let model = AppModel(
                service: service,
                cloudStorageNoticeDefaults: defaults,
                downloadsStorageRootURL: root.appendingPathComponent(
                    "Downloads"),
                downloadsBackgroundSessionIdentifier: suite,
                remoteTelemetryConsentStore: RemoteTelemetryConsentStore(
                    defaults: defaults),
                localSessionStore: LocalPlaybackSessionStore(
                    defaults: defaults),
                playbackPositionStore: PlaybackPositionStore(
                    defaults: defaults),
                nowPlayingCoordinator: NowPlayingCoordinator(
                    infoCenter: KeyboardNowPlayingInfoPublisher(),
                    registersRemoteCommands: false))
            let window = UIWindow(windowScene: scene)
            addTeardownBlock { @MainActor in
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
                model.setLiveUpdatesActive(false)
                model.stopStatisticsLiveUpdates()
                await model.cancelPrivateCloudSynchronization()
                await model.playback.stop()
                if let account = model.account {
                    await service.stopLiveUpdates(for: account.id)
                    await model.downloads.removeAll(for: account.id)
                }
                defaults.removePersistentDomain(forName: suite)
                do {
                    try FileManager.default.removeItem(at: root)
                    if let serviceRoot,
                        FileManager.default.fileExists(atPath: serviceRoot.path)
                    {
                        try FileManager.default.removeItem(at: serviceRoot)
                    }
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: root.path))
                    if let serviceRoot {
                        XCTAssertFalse(
                            FileManager.default.fileExists(
                                atPath: serviceRoot.path))
                    }
                } catch {
                    XCTFail("Owned keyboard fixture cleanup failed: \(error)")
                }
            }
            await model.start()
            XCTAssertEqual(model.phase, .signedIn)
            XCTAssertFalse(model.playback.isPlaybackControlAvailable)
            let navigation = AppNavigationCoordinator()
            navigation.selectedTab = .library
            navigation.searchQuery = "retained synthetic query"
            navigation.searchPath.append("synthetic-detail")
            let ready = expectation(
                description: "owned keyboard scope appeared")
            var captured: IPadKeyboardScene?
            let content = KeyboardSceneCaptureView { keyboardScene in
                guard captured == nil,
                    keyboardScene.window === window,
                    window.isKeyWindow,
                    scene.activationState == .foregroundActive
                else { return }
                captured = keyboardScene
                ready.fulfill()
            }
            .modifier(IPadKeyboardScope(model: model, navigation: navigation))
            let host = UIHostingController(rootView: content)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            await fulfillment(of: [ready], timeout: 3)
            let keyboardScene = try XCTUnwrap(captured)
            let context = IPadKeyboardContext(
                model: model, navigation: navigation, scene: keyboardScene)

            let commands = publicKeyboardCommands(in: window)
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            // UIKit may omit disabled media bindings from keyCommands. Only
            // Search is eligible in this deliberately unprepared fixture.
            let expectedInputs = isPad ? ["f"] : []
            let metadata = commands.map { _, command in
                "\(command.input ?? "nil"):\(command.modifierFlags.rawValue)"
            }.sorted().joined(separator: ", ")
            for input in expectedInputs {
                XCTAssertTrue(
                    commands.contains {
                        $0.1.input == input && $0.1.modifierFlags == .command
                    },
                    "Missing public Cmd-\(input) registration; \(commands.count) public commands: \(metadata). SwiftUI bridge registrations may not be publicly exposed."
                )
            }
            let searchCommands = commands.filter {
                $0.1.input == "f" && $0.1.modifierFlags == .command
            }
            let targetMetadata = searchCommands.map { responder, command in
                guard let action = command.action else { return "selector=nil" }
                let target = responder.target(
                    forAction: action, withSender: command)
                return
                    "selector=\(NSStringFromSelector(action)) target=\(target.map { String(reflecting: type(of: $0)) } ?? "nil")"
            }.joined(separator: "; ")
            let hasSearchTarget = searchCommands.contains {
                responder, command in
                guard let action = command.action,
                    let target = responder.target(
                        forAction: action, withSender: command)
                else { return false }
                if let target = target as? UIResponder {
                    return target.canPerformAction(action, withSender: command)
                }
                return (target as? NSObject)?.responds(to: action) == true
            }
            XCTAssertEqual(context.allows(.search), isPad)
            if isPad {
                XCTAssertTrue(
                    hasSearchTarget,
                    "Public Search command has no accepting responder target: \(targetMetadata)"
                )
            }
            let initialFocus = navigation.keyboardSearchFocusRequest

            context.perform(.search)

            XCTAssertEqual(navigation.searchQuery, "retained synthetic query")
            XCTAssertEqual(navigation.selectedTab, isPad ? .search : .library)
            XCTAssertEqual(navigation.searchPath.count, isPad ? 0 : 1)
            XCTAssertEqual(
                navigation.keyboardSearchFocusRequest,
                initialFocus + (isPad ? 1 : 0))
        }

        private func publicKeyboardCommands(in window: UIWindow)
            -> [(UIResponder, UIKeyCommand)]
        {
            var pending: [UIResponder] = [window]
            var visited: Set<ObjectIdentifier> = []
            var commands: [(UIResponder, UIKeyCommand)] = []
            while let responder = pending.popLast() {
                guard visited.insert(ObjectIdentifier(responder)).inserted
                else { continue }
                commands.append(
                    contentsOf: (responder.keyCommands ?? []).map {
                        (responder, $0)
                    })
                if let next = responder.next { pending.append(next) }
                if let view = responder as? UIView {
                    pending.append(contentsOf: view.subviews)
                }
                if let controller = responder as? UIViewController {
                    pending.append(contentsOf: controller.children)
                    if let view = controller.viewIfLoaded {
                        pending.append(view)
                    }
                    if let presented = controller.presentedViewController {
                        pending.append(presented)
                    }
                }
                if let window = responder as? UIWindow,
                    let controller = window.rootViewController
                {
                    pending.append(controller)
                }
            }
            return commands
        }

        private var transportActions: [IPadKeyboardAction] {
            [.togglePlayback, .skipBackward, .skipForward, .slower, .faster]
        }

        private func availability(
            isPad: Bool = true,
            isSignedIn: Bool = true,
            isSceneActive: Bool = true,
            isEditingText: Bool = false,
            isPresentationAllowed: Bool = true,
            isPlaybackAvailable: Bool = true,
            isToggleAvailable: Bool? = nil
        ) -> IPadKeyboardAvailability {
            IPadKeyboardAvailability(
                isPad: isPad,
                isSignedIn: isSignedIn,
                isSceneActive: isSceneActive,
                isEditingText: isEditingText,
                isPresentationAllowed: isPresentationAllowed,
                isPlaybackAvailable: isPlaybackAvailable,
                isToggleAvailable: isToggleAvailable ?? isPlaybackAvailable)
        }
    }

    @MainActor
    private struct KeyboardSceneCaptureView: View {
        @Environment(\.ipadKeyboardScene) private var scene
        let capture: @MainActor (IPadKeyboardScene) -> Void

        var body: some View {
            Color.clear
                .onAppear { captureScene() }
                .onChange(of: scene?.focusRevision) { _, _ in
                    captureScene()
                }
        }

        private func captureScene() {
            if let scene { capture(scene) }
        }
    }

    @MainActor
    private final class KeyboardNowPlayingInfoPublisher:
        NowPlayingInfoPublishing
    {
        var nowPlayingInfo: [String: Any]?
        var playbackState: MPNowPlayingPlaybackState = .unknown
    }
#endif
