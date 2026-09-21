import Foundation

public enum StatisticsHistoryImportError: Error, Equatable, Sendable {
    case remote(AudiobookshelfAPIError)
    case persistence(StatisticsRepositoryError)
    case changedDuringImport
    case cancelled
}

public enum StatisticsHistoryImporter {
    /// A resumed run deliberately starts at page zero: page numbers are not
    /// stable cursors. Previously persisted snapshots are upserted, not added.
    public static func run(
        accountID: AccountID, force: Bool, repository: StatisticsRepository,
        loadPage:
            @Sendable (Int) async throws(AudiobookshelfAPIError) ->
            ListeningSessionsPage
    ) async throws(StatisticsHistoryImportError) -> StatisticsHistoryProgress {
        let previous: StatisticsHistoryProgress
        do {
            previous = try await repository.historyProgress(
                accountID: accountID
            )
        } catch let error {
            throw .persistence(error)
        }
        if !force,
            let last = [
                previous.lastCompletedAt, previous.startedAt,
            ].compactMap({ $0 }).max(),
            Date().timeIntervalSince(last) < 86_400
        {
            return previous
        }
        do {
            try await repository.updateHistoryProgress(
                accountID: accountID,
                completedPages: 0,
                totalPages: 0,
                completed: false
            )
            for attempt in 0..<2 {
                let first = try await loadPage(0)
                try await repository.updateHistoryProgress(
                    accountID: accountID,
                    completedPages: 0,
                    totalPages: first.numPages,
                    completed: false
                )
                var fingerprints: [ListeningSessionsFingerprint] = []
                for page in 0..<first.numPages {
                    try Task.checkCancellation()
                    let batch =
                        page == 0
                        ? first
                        : try await loadPage(page)
                    fingerprints.append(batch.fingerprint)
                    try await repository.upsertRemoteSessions(
                        batch.sessions
                    )
                    try await repository.updateHistoryProgress(
                        accountID: accountID,
                        completedPages: page + 1,
                        totalPages: first.numPages,
                        completed: false
                    )
                }
                var stable = true
                if first.numPages == 0 {
                    let check = try await loadPage(0)
                    stable = check.total == 0 && check.numPages == 0
                }
                for page in 0..<first.numPages {
                    let check = try await loadPage(page)
                    if check.total != first.total
                        || check.numPages != first.numPages
                        || check.fingerprint != fingerprints[page]
                    {
                        stable = false
                        break
                    }
                }
                if stable {
                    try await repository.updateHistoryProgress(
                        accountID: accountID,
                        completedPages: first.numPages,
                        totalPages: first.numPages,
                        completed: true
                    )
                    return try await repository.historyProgress(
                        accountID: accountID
                    )
                }
                if attempt == 1 {
                    throw StatisticsHistoryImportError.changedDuringImport
                }
            }
            throw StatisticsHistoryImportError.changedDuringImport
        } catch let error as StatisticsHistoryImportError {
            throw error
        } catch let error as AudiobookshelfAPIError {
            throw .remote(error)
        } catch let error as StatisticsRepositoryError {
            throw .persistence(error)
        } catch {
            throw .cancelled
        }
    }
}
