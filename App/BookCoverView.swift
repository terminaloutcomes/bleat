import BleatCore
import CryptoKit
import SwiftUI

enum BookCoverURL {
    static func make(
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int
    ) -> URL? {
        guard let server,
            width > 0,
            height > 0
        else {
            return nil
        }
        return try? AudiobookshelfRouteBuilder(server: server).url(
            for: .cover(itemID),
            queryItems: [
                URLQueryItem(name: "width", value: String(width)),
                URLQueryItem(name: "height", value: String(height)),
                URLQueryItem(name: "format", value: "jpeg"),
                URLQueryItem(
                    name: "ts",
                    value: String(updatedAtMilliseconds)
                ),
            ]
        )
    }
}

enum BookCoverLoadPolicy: Equatable, Sendable {
    case allowNetwork
    case cacheOnly
}

private struct BookCoverCacheKey: Hashable, Sendable {
    let accountID: AccountID
    let url: URL

    var memoryKey: NSString {
        "\(accountID.rawValue)\u{0}\(url.absoluteString)" as NSString
    }
}

private struct LoadedBookCover: @unchecked Sendable {
    let data: Data
    let image: PlatformImage
}

actor BookCoverImageLoader {
    typealias Fetch =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = BookCoverImageLoader()

    private static let maximumResponseBytes = 5 * 1_024 * 1_024
    private static let memoryCapacity = 32 * 1_024 * 1_024
    private static let diskCapacity = 128 * 1_024 * 1_024

    private let fetch: Fetch
    private let diskCapacity: Int
    private let cacheRoot: URL?
    private let memory = NSCache<NSString, PlatformImage>()
    private var endpointRouter: ServerEndpointRouter?
    private var memoryKeys: [AccountID: Set<String>] = [:]
    private var inFlight:
        [BookCoverCacheKey: Task<LoadedBookCover?, Never>] = [:]

    init(
        diskCapacity: Int = BookCoverImageLoader.diskCapacity,
        cacheRoot: URL? = nil,
        fetch: @escaping Fetch = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.diskCapacity = max(0, diskCapacity)
        self.cacheRoot = cacheRoot
        self.fetch = fetch
        memory.totalCostLimit = Self.memoryCapacity
        memory.countLimit = 256
    }

    func image(
        for url: URL,
        accountID: AccountID?,
        policy: BookCoverLoadPolicy = .allowNetwork
    ) async -> PlatformImage? {
        guard let accountID else {
            guard policy == .allowNetwork else {
                return nil
            }
            return await Self.fetchImage(
                URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData
                ),
                using: fetch,
                endpointRouter: endpointRouter
            )?.image
        }
        let key = BookCoverCacheKey(accountID: accountID, url: url)
        if let image = memory.object(forKey: key.memoryKey) {
            return image
        }

        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        if let image = loadFromDisk(for: key) {
            storeInMemory(image, for: key)
            return image
        }

        guard policy == .allowNetwork else {
            return nil
        }

        if let task = inFlight[key] {
            return await task.value?.image
        }

        let endpointRouter = endpointRouter
        let task = Task { [fetch] in
            await Self.fetchImage(
                request,
                using: fetch,
                endpointRouter: endpointRouter
            )
        }
        inFlight[key] = task
        let loaded = await task.value
        inFlight[key] = nil
        guard let loaded else {
            return nil
        }
        storeOnDisk(loaded.data, for: key)
        storeInMemory(loaded.image, for: key)
        return loaded.image
    }

    func removeAll(for accountID: AccountID) {
        for key in memoryKeys.removeValue(forKey: accountID) ?? [] {
            memory.removeObject(forKey: key as NSString)
        }
        let inFlightKeys = inFlight.keys.filter {
            $0.accountID == accountID
        }
        for key in inFlightKeys {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        if let directory = accountCacheDirectory(for: accountID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func clearMemoryCache() {
        memory.removeAllObjects()
        memoryKeys = [:]
    }

    func setEndpointRouter(_ endpointRouter: ServerEndpointRouter?) {
        self.endpointRouter = endpointRouter
    }

    private func storeInMemory(
        _ image: PlatformImage,
        for key: BookCoverCacheKey
    ) {
        let size = PlatformImageSupport.pixelSize(of: image)
        let width = Double(size.width)
        let height = Double(size.height)
        let maximumPixels = Double(Self.memoryCapacity / 4)
        let pixelCount =
            width.isFinite && height.isFinite && width > 0 && height > 0
            ? min(width * height, maximumPixels)
            : maximumPixels
        memory.setObject(
            image,
            forKey: key.memoryKey,
            cost: max(1, Int(pixelCount) * 4)
        )
        memoryKeys[key.accountID, default: []].insert(
            key.memoryKey as String
        )
    }

    private static func fetchImage(
        _ request: URLRequest,
        using fetch: Fetch,
        endpointRouter: ServerEndpointRouter?
    ) async -> LoadedBookCover? {
        let candidates: [ServerEndpointCandidate]
        if let endpointRouter, let url = request.url {
            candidates = await endpointRouter.candidates(for: url)
        } else if let url = request.url {
            candidates = [
                ServerEndpointCandidate(
                    url: url,
                    primary: nil,
                    isLocal: false
                )
            ]
        } else {
            candidates = []
        }
        for candidate in candidates {
            do {
                var routedRequest = request
                routedRequest.url = candidate.url
                let (data, response) = try await fetch(routedRequest)
                guard
                    let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode),
                    data.count <= maximumResponseBytes,
                    let image = PlatformImageSupport.image(from: data)
                else {
                    if candidate.isLocal {
                        await endpointRouter?.markLocalUnavailable(candidate)
                        continue
                    }
                    return nil
                }
                await endpointRouter?.recordConnection(
                    candidate,
                    purpose: .cover
                )
                return LoadedBookCover(
                    data: data,
                    image: image
                )
            } catch {
                if candidate.isLocal {
                    await endpointRouter?.markLocalUnavailable(candidate)
                    continue
                }
                return nil
            }
        }
        return nil
    }

    private func loadFromDisk(for key: BookCoverCacheKey) -> PlatformImage? {
        guard let url = diskURL(for: key),
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            (0...Self.maximumResponseBytes).contains(fileSize),
            let data = try? Data(contentsOf: url),
            let image = PlatformImageSupport.image(from: data)
        else {
            return nil
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return image
    }

    private func storeOnDisk(
        _ data: Data,
        for key: BookCoverCacheKey
    ) {
        guard data.count <= Self.maximumResponseBytes,
            let url = diskURL(for: key)
        else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            pruneDiskCache()
        } catch {
            return
        }
    }

    private func diskURL(for key: BookCoverCacheKey) -> URL? {
        guard diskCapacity > 0,
            let directory = accountCacheDirectory(
                for: key.accountID
            )
        else {
            return nil
        }
        return directory.appendingPathComponent(
            Self.hash(key.url.absoluteString),
            isDirectory: false
        )
    }

    private func accountCacheDirectory(
        for accountID: AccountID
    ) -> URL? {
        cacheDirectory?.appendingPathComponent(
            Self.hash(accountID.rawValue),
            isDirectory: true
        )
    }

    private var cacheDirectory: URL? {
        let root =
            cacheRoot
            ?? FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first
        guard let root else {
            return nil
        }
        return cacheRoot == nil
            ? root.appendingPathComponent("BookCovers", isDirectory: true)
            : root
    }

    private func pruneDiskCache() {
        guard diskCapacity > 0,
            let cacheDirectory,
            let enumerator = FileManager.default.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        var files: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var totalSize: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]
            ), values.isRegularFile == true
            else {
                continue
            }
            let size = Int64(max(0, values.fileSize ?? 0))
            let (newTotal, overflowed) =
                totalSize.addingReportingOverflow(size)
            totalSize = overflowed ? .max : newTotal
            files.append(
                (
                    url: url,
                    size: size,
                    modifiedAt: values.contentModificationDate
                        ?? .distantPast
                )
            )
        }
        guard totalSize > Int64(diskCapacity) else {
            return
        }
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? FileManager.default.removeItem(at: file.url)
            totalSize -= min(file.size, totalSize)
            if totalSize <= Int64(diskCapacity) {
                break
            }
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private enum BookCoverLoadState {
    case idle
    case loading
    case loaded(PlatformImage)
    case failed
}

struct BookCoverView: View {
    let accountID: AccountID?
    let url: URL?
    let cornerRadius: CGFloat
    let loadPolicy: BookCoverLoadPolicy
    @State private var state = BookCoverLoadState.idle

    init(
        accountID: AccountID?,
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int,
        cornerRadius: CGFloat = 8,
        loadPolicy: BookCoverLoadPolicy = .allowNetwork
    ) {
        self.accountID = accountID
        url = BookCoverURL.make(
            server: server,
            itemID: itemID,
            updatedAtMilliseconds: updatedAtMilliseconds,
            width: width,
            height: height
        )
        self.cornerRadius = cornerRadius
        self.loadPolicy = loadPolicy
    }

    init(
        accountID: AccountID?,
        url: URL?,
        cornerRadius: CGFloat = 8,
        loadPolicy: BookCoverLoadPolicy = .allowNetwork
    ) {
        self.accountID = accountID
        self.url = url
        self.cornerRadius = cornerRadius
        self.loadPolicy = loadPolicy
    }

    var body: some View {
        Group {
            switch state {
            case .loaded(let image):
                PlatformImageSupport.resizableView(for: image)
                    .scaledToFill()
            case .idle, .loading:
                placeholder
                    .overlay {
                        ProgressView()
                    }
            case .failed:
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: request) {
            guard let url else {
                state = .failed
                return
            }
            state = .loading
            let image = await BookCoverImageLoader.shared.image(
                for: url,
                accountID: accountID,
                policy: loadPolicy
            )
            guard !Task.isCancelled else {
                return
            }
            state = image.map(BookCoverLoadState.loaded) ?? .failed
        }
    }

    private var request: BookCoverRequest {
        BookCoverRequest(accountID: accountID, url: url)
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "book.closed.fill")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BookCoverRequest: Hashable {
    let accountID: AccountID?
    let url: URL?
}

enum PlayableBookCoverState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused

    static func derive(
        target: PlaybackStartTarget?,
        accountID: AccountID,
        itemID: LibraryItemID,
        playbackAccountID: AccountID?,
        playbackItemID: LibraryItemID?,
        playbackState: PlaybackState,
        isPlaybackRequested: Bool
    ) -> Self {
        if target == PlaybackStartTarget(
            accountID: accountID,
            itemID: itemID
        ) {
            return .preparing
        }
        guard playbackAccountID == accountID,
            playbackItemID == itemID
        else {
            return .idle
        }
        switch playbackState {
        case .preparing:
            return .preparing
        case .ready, .buffering, .playing, .paused:
            return isPlaybackRequested ? .playing : .paused
        case .idle, .ended, .failed:
            return .idle
        }
    }
}

struct PlayableBookCoverView: View {
    let accountID: AccountID
    let server: NormalizedServerURL?
    let itemID: LibraryItemID
    let updatedAtMilliseconds: Int64
    let width: Int
    let height: Int
    let cornerRadius: CGFloat
    let loadPolicy: BookCoverLoadPolicy
    let title: String
    let state: PlayableBookCoverState
    let accessibilityIdentifier: String
    let performPlaybackAction: () async -> BrowsingPlaybackActionOutcome
    let handleOutcome: (PlaybackStartOutcome) -> Void

    init(
        accountID: AccountID,
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int,
        cornerRadius: CGFloat = 8,
        loadPolicy: BookCoverLoadPolicy = .allowNetwork,
        title: String,
        state: PlayableBookCoverState,
        accessibilityIdentifier: String,
        performPlaybackAction:
            @escaping () async -> BrowsingPlaybackActionOutcome,
        handleOutcome: @escaping (PlaybackStartOutcome) -> Void
    ) {
        self.accountID = accountID
        self.server = server
        self.itemID = itemID
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.loadPolicy = loadPolicy
        self.title = title
        self.state = state
        self.accessibilityIdentifier = accessibilityIdentifier
        self.performPlaybackAction = performPlaybackAction
        self.handleOutcome = handleOutcome
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BookCoverView(
                accountID: accountID,
                server: server,
                itemID: itemID,
                updatedAtMilliseconds: updatedAtMilliseconds,
                width: width,
                height: height,
                cornerRadius: cornerRadius,
                loadPolicy: loadPolicy
            )
            .allowsHitTesting(false)

            Button(action: performAction) {
                Group {
                    if state == .preparing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: controlSystemImage)
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.68), in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(state != .preparing)
            .disabled(state == .preparing)
            .padding(4)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var controlSystemImage: String {
        state == .playing ? "pause.circle.fill" : "play.circle.fill"
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle, .paused:
            "Play \(title)"
        case .preparing:
            "Preparing \(title)"
        case .playing:
            "Pause \(title)"
        }
    }

    private func performAction() {
        guard state != .preparing else { return }
        Task {
            let outcome = await performPlaybackAction()
            if case .start(let startOutcome) = outcome {
                handleOutcome(startOutcome)
            }
        }
    }
}
