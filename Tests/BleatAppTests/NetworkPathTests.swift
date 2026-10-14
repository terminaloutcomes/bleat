import BleatCore
import Network
import SwiftData
import Synchronization
import XCTest

@testable import Bleat

@MainActor
final class NetworkPathTests: XCTestCase {
    func testClassificationIgnoresQualityButDetectsRoutingWithIdenticalFlags() {
        let wifi = state()
        XCTAssertEqual(wifi.change(from: wifi), .duplicatePath)
        XCTAssertEqual(
            state(quality: .moderate).change(from: wifi), .qualityOnly)
        XCTAssertEqual(
            state(gateway: "192.0.2.2").change(from: wifi), .routingChanged)
        XCTAssertEqual(
            state(type: .cellular).change(from: wifi), .routingChanged)
        XCTAssertEqual(state(used: false).change(from: wifi), .routingChanged)
        XCTAssertEqual(
            state(address: "192.0.2.20").change(from: wifi), .routingChanged)
        XCTAssertEqual(
            state(constrained: true).change(from: wifi), .lowDataModeEntered)
        XCTAssertEqual(
            wifi.change(from: state(constrained: true)), .lowDataModeExited)
        XCTAssertEqual(
            state(availability: .unavailable).change(from: wifi),
            .connectivityLost)
        XCTAssertEqual(
            wifi.change(from: state(availability: .unavailable)),
            .connectivityRecovered)
    }

    @MainActor
    func
        testActualCallbackAdapterSerializesRapidOffActorUpdatesAndSuppressesWork()
        async throws
    {
        let notifications =
            [state()]
            + (0..<100).map {
                state(quality: $0.isMultiple(of: 2) ? .moderate : .good)
            } + [
                state(gateway: "192.0.2.2"),
                state(gateway: "192.0.2.2", constrained: true),
                state(gateway: "192.0.2.2"),
                state(availability: .unavailable),
                state(),
            ]
        let snapshots = Mutex(notifications)
        let input = AsyncStream<AppNetworkPathState>.makeStream()
        let classified = expectation(description: "Every callback classified")
        classified.expectedFulfillmentCount = notifications.count
        let recorder = NetworkDiagnosticRecorder(classified: classified)
        let schema = Schema(versionedSchema: BleatPersistenceSchemaCurrent.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true,
                cloudKitDatabase: .none))
        let service = try LiveAppService(
            diagnostics: recorder, networkPathUpdates: input.stream,
            modelContainer: container, privateCloudAvailable: false,
            openIDBrowserProvider: { NetworkTestBrowser() })
        let updates = await service.networkPathUpdates()
        let delivered = expectation(
            description: "Only meaningful updates delivered")
        let collect = Task { () -> [AppNetworkPathState] in
            var received: [AppNetworkPathState] = []
            for await state in updates {
                received.append(state)
                if received.count == 7 {
                    delivered.fulfill()
                    break
                }
            }
            return received
        }
        let callback = AppNetworkPathMonitor.makePathUpdateHandler(
            snapshot: { _ in
                snapshots.withLock { $0.isEmpty ? .unknown : $0.removeFirst() }
            },
            onChange: { input.continuation.yield($0) })
        let path = NWPathMonitor().currentPath
        await Task.detached {
            for _ in notifications { callback(path) }
        }.value
        await fulfillment(of: [classified, delivered], timeout: 5)
        input.continuation.finish()
        collect.cancel()
        let received = await collect.value
        // Initial unknown plus six meaningful changes.
        XCTAssertEqual(received.count, 7)
        XCTAssertEqual(received.last?.availability, .satisfied)
        let events = await recorder.events
        XCTAssertEqual(
            events.filter {
                $0.networkReason == .qualityOnly
                    && $0.stage == .pathClassification
            }.count, 100)
        XCTAssertEqual(
            events.filter { $0.stage == .pathClassification }.count,
            notifications.count)
        let optionalRouter = await service.serverEndpointRouter()
        let router = try XCTUnwrap(optionalRouter)
        let server = try NormalizedServerURL("https://example.test/prefix")
        let selection = await router.preferredServer(for: server)
        XCTAssertEqual(selection.server, server)
        XCTAssertEqual(selection.usage, .primary)
    }

    @MainActor
    func testQualityAndDuplicatesDoNotProbeOrInvalidateLocalEndpoint()
        async throws
    {
        let input = AsyncStream<AppNetworkPathState>.makeStream()
        let classified = expectation(
            description: "Stable path callbacks classified")
        classified.expectedFulfillmentCount = 101
        let recorder = NetworkDiagnosticRecorder(classified: classified)
        let probe = NetworkProbeGate()
        let (service, account) = try await serviceFixture(
            input: input.stream, recorder: recorder, probe: probe)
        var entries = probe.entries.makeAsyncIterator()
        input.continuation.yield(state())
        let firstEntry = await entries.next()
        XCTAssertEqual(firstEntry, 1)
        await probe.release(1, success: true)
        let optionalRouter = await service.serverEndpointRouter()
        let router = try XCTUnwrap(optionalRouter)
        try await waitForAvailability(
            .available, router: router, account: account)
        let before = await router.preferredServer(for: account.server)
        for index in 0..<100 {
            input.continuation.yield(
                state(quality: index < 50 ? .moderate : .good))
        }
        await fulfillment(of: [classified], timeout: 5)
        let after = await router.preferredServer(for: account.server)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.server, account.localServer)
        input.continuation.finish()
    }

    @MainActor
    func testStaleProbeCannotPromoteEndpointOrReviveStoppedSubscription()
        async throws
    {
        let input = AsyncStream<AppNetworkPathState>.makeStream()
        let classified = expectation(description: "Routing changes classified")
        classified.expectedFulfillmentCount = 2
        let recorder = NetworkDiagnosticRecorder(classified: classified)
        let probe = NetworkProbeGate()
        let (service, account) = try await serviceFixture(
            input: input.stream, recorder: recorder, probe: probe)
        var entries = probe.entries.makeAsyncIterator()
        input.continuation.yield(state())
        let firstEntry = await entries.next()
        XCTAssertEqual(firstEntry, 1)
        let subscription = Task { await service.liveUpdates(for: account) }
        for _ in 0..<100 {
            if await recorder.events.contains(where: {
                $0.stage == .subscriptionStart
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requested = await recorder.events.contains {
            $0.stage == .subscriptionStart
        }
        XCTAssertTrue(requested)
        input.continuation.yield(state(gateway: "192.0.2.2"))
        let secondEntry = await entries.next()
        XCTAssertEqual(secondEntry, 2)
        await fulfillment(of: [classified], timeout: 5)
        await service.stopLiveUpdates(for: account.id)
        await probe.release(2, success: false)
        let optionalRouter = await service.serverEndpointRouter()
        let router = try XCTUnwrap(optionalRouter)
        try await waitForAvailability(
            .temporarilyUnavailable, router: router, account: account)
        await probe.release(1, success: true)
        let stream = await subscription.value
        var iterator = stream.makeAsyncIterator()
        let update = await iterator.next()
        XCTAssertNil(update)
        let selection = await router.preferredServer(for: account.server)
        XCTAssertEqual(selection.server, account.server)
        let events = await recorder.events
        XCTAssertFalse(events.contains { $0.stage == .subscriptionReconnect })
        input.continuation.finish()
    }

    @MainActor
    private func serviceFixture(
        input: AsyncStream<AppNetworkPathState>,
        recorder: NetworkDiagnosticRecorder,
        probe: NetworkProbeGate
    ) async throws -> (LiveAppService, ServerAccount) {
        let schema = Schema(versionedSchema: BleatPersistenceSchemaCurrent.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true,
                cloudKitDatabase: .none))
        let server = try NormalizedServerURL("https://example.test/primary")
        let user = AuthenticatedUser(
            id: UserID(rawValue: "user"), username: "user", type: .user,
            permissions: UserPermissions(
                download: true, update: false, delete: false, upload: false,
                createEReader: false,
                accessAllLibraries: true, accessAllTags: true,
                accessExplicitContent: true,
                selectedTagsNotAccessible: false), accessibleLibraryIDs: [],
            selectedItemTags: [])
        let account = try ServerAccount(
            id: AccountID.canonical(server: server, userID: user.id),
            server: server,
            localServer: NormalizedServerURL(
                "https://local.example.test/prefix"),
            localServerValidated: true,
            serverVersion: "2.36.0", authenticationMethods: [.local], user: user
        )
        try await AccountStore(modelContainer: container).save(account)
        let service = try LiveAppService(
            diagnostics: recorder, networkPathUpdates: input,
            localEndpointProbe: { _ in try await probe.enter() },
            modelContainer: container, privateCloudAvailable: false,
            openIDBrowserProvider: { NetworkTestBrowser() })
        _ = try await service.accounts()
        return (service, account)
    }

    private func waitForAvailability(
        _ expected: ServerEndpointLocalAvailability,
        router: ServerEndpointRouter, account: ServerAccount
    ) async throws {
        for _ in 0..<100 {
            if await router.localAvailability(for: account.server) == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Endpoint probe did not finish")
    }

    func testNetworkDiagnosticsContainOnlyTypedReasonAndStage() throws {
        let event = DiagnosticEvent.network(
            .qualityOnly, stage: .pathClassification)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(event.networkReason, .qualityOnly)
        XCTAssertEqual(event.stage, .pathClassification)
        XCTAssertTrue(event.text.contains("network_reason=quality_only"))
        XCTAssertTrue(event.text.contains("stage=path_classification"))
        XCTAssertFalse(event.text.contains("192.0.2"))
    }

    private func state(
        gateway: String = "192.0.2.1", type: NWInterface.InterfaceType = .wifi,
        address: String = "192.0.2.10",
        availability: AppNetworkAvailability = .satisfied,
        constrained: Bool = false, quality: AppNetworkLinkQuality = .good,
        used: Bool = true
    ) -> AppNetworkPathState {
        AppNetworkPathState(
            availability: availability, isConstrained: constrained,
            isExpensive: false,
            routing: AppNetworkRoutingState(
                interfaces: [.init(index: 1, type: type, isUsed: used)],
                gateways: [
                    .hostPort(host: NWEndpoint.Host(gateway), port: .any)
                ],
                addresses: [
                    .init(interface: "test", host: NWEndpoint.Host(address))
                ]),
            linkQuality: quality)
    }
}

private actor NetworkDiagnosticRecorder: DiagnosticRecording {
    private let classified: XCTestExpectation
    private(set) var events: [DiagnosticEvent] = []
    init(classified: XCTestExpectation) { self.classified = classified }
    func record(_ event: DiagnosticEvent) {
        events.append(event)
        if event.stage == .pathClassification { classified.fulfill() }
    }
}

private struct NetworkTestBrowser: OpenIDBrowserSession {
    @MainActor
    func authenticate(at authorizationURL: URL, callbackScheme: String)
        async throws -> URL
    {
        throw CancellationError()
    }
}

private actor NetworkProbeGate {
    nonisolated let entries: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var count = 0
    init() {
        let stream = AsyncStream<Int>.makeStream()
        entries = stream.stream
        continuation = stream.continuation
    }
    func enter() async throws {
        count += 1
        let entry = count
        try await withCheckedThrowingContinuation {
            waiters[entry] = $0
            continuation.yield(entry)
        }
    }
    func release(_ entry: Int, success: Bool) {
        if success {
            waiters.removeValue(forKey: entry)?.resume()
        } else {
            waiters.removeValue(forKey: entry)?.resume(
                throwing: URLError(.notConnectedToInternet))
        }
    }
}
