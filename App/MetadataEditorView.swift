import BleatCore
import PhotosUI
import SwiftUI

private enum PendingCoverState: Equatable {
    case unchanged
    case processing
    case ready(Data)
    case failed(CoverImageProcessingError)
}

struct MetadataEditorView: View {
    @Bindable var model: AppModel
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var baseline: LibraryBookDetail
    @State private var draft: BookMetadataDraft
    @State private var authorsText: String
    @State private var narratorsText: String
    @State private var seriesText: String
    @State private var genresText: String
    @State private var tagsText: String
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var pendingCover: PendingCoverState = .unchanged
    @State private var showDeleteOptions = false
    @State private var showDeletionWarning = false
    @State private var deletionCleanupStatus:
        BookDeletionCleanupStatus?

    init(
        model: AppModel,
        detail: LibraryBookDetail,
        onDeleted: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onDeleted = onDeleted
        _baseline = State(initialValue: detail)
        let initialDraft = BookMetadataDraft(detail: detail)
        _draft = State(initialValue: initialDraft)
        _authorsText = State(
            initialValue: initialDraft.authors.joined(separator: ", ")
        )
        _narratorsText = State(
            initialValue: initialDraft.narrators.joined(separator: ", ")
        )
        _seriesText = State(
            initialValue: Self.seriesText(initialDraft.series)
        )
        _genresText = State(
            initialValue: initialDraft.genres.joined(separator: ", ")
        )
        _tagsText = State(
            initialValue: initialDraft.tags.joined(separator: ", ")
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if canEditCover {
                    coverSection
                }
                if canEditMetadata {
                    metadataSections
                }
                if let failure = editFailure {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("metadata.error")
                        if case .metadataSavedCoverFailed =
                            model.bookEditSaveState
                        {
                            Button("Retry Cover Upload") {
                                Task {
                                    await model.retryBookCoverUpload()
                                }
                            }
                            .disabled(isBusy)
                            .accessibilityIdentifier(
                                "metadata.retryCoverUpload"
                            )
                        }
                    }
                }
                if case .failed(let failure) = model.bookDeletionState {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("book.delete.error")
                    }
                }
                if canDeleteFromServer {
                    Section {
                        Button(
                            "Delete from Server",
                            role: .destructive
                        ) {
                            showDeleteOptions = true
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("book.edit.delete")
                    }
                }
            }
            .navigationTitle("Edit Book")
            .iOSInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.resetBookEditSaveState()
                        model.resetBookDeletionState()
                        dismiss()
                    }
                    .disabled(isBusy)
                }
                if canSave {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save(overwrite: false)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(isBusy || pendingCover == .processing)
                        .accessibilityIdentifier("metadata.save")
                    }
                }
            }
            .alert(
                "Server version changed",
                isPresented: staleAlertPresented
            ) {
                Button("Reload Server Version") {
                    reloadServerVersion()
                }
                Button("Overwrite", role: .destructive) {
                    save(overwrite: true)
                }
                Button("Review My Draft", role: .cancel) {
                    model.resetBookEditSaveState()
                }
            } message: {
                Text(
                    "This is a best-effort check. The server does not support atomic metadata preconditions."
                )
            }
            .confirmationDialog(
                "Delete from Server?",
                isPresented: $showDeleteOptions,
                titleVisibility: .visible
            ) {
                Button("Remove from Library", role: .destructive) {
                    delete(mode: .libraryRecordOnly)
                }
                Button("Delete Files from Server", role: .destructive) {
                    delete(mode: .libraryRecordAndFiles)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deletionConfirmationMessage)
            }
            .alert(
                "Deleted with a Warning",
                isPresented: $showDeletionWarning
            ) {
                Button("OK") {
                    onDeleted()
                }
            } message: {
                Text(deletionWarningMessage)
            }
            .onChange(of: selectedCoverItem) { _, item in
                guard let item else {
                    return
                }
                Task {
                    await prepareCover(item)
                }
            }
            .onChange(of: model.bookEditSaveState) { _, newState in
                switch newState {
                case .saved:
                    model.resetBookEditSaveState()
                    dismiss()
                case .coverSaved(let latest):
                    baseline = latest
                    pendingCover = .unchanged
                    model.resetBookEditSaveState()
                case .metadataSavedCoverFailed(_, let latest, _, _):
                    baseline = latest
                case .idle, .saving, .stale, .failed:
                    break
                }
            }
            .onChange(of: model.bookDeletionState) { _, newState in
                guard case .deleted(let status) = newState else {
                    return
                }
                if status.hasWarning {
                    deletionCleanupStatus = status
                    showDeletionWarning = true
                } else {
                    onDeleted()
                }
            }
        }
    }

    private var actions: Set<BookAction> {
        guard let user = model.account?.user else {
            return []
        }
        return BookActionAvailability(
            user: user,
            detail: baseline
        ).visibleActions
    }

    private var canEditMetadata: Bool {
        actions.contains(.editMetadata)
    }

    private var canEditCover: Bool {
        actions.contains(.editCover)
    }

    private var canDeleteFromServer: Bool {
        actions.contains(.deleteFromServer)
    }

    private var canSave: Bool {
        canEditMetadata || canEditCover
    }

    private var isBusy: Bool {
        model.bookEditSaveState == .saving
            || model.bookDeletionState == .deleting
    }

    private var isActiveBook: Bool {
        guard let account = model.account else {
            return false
        }
        return model.playback.hasActiveBook
            && model.playback.accountID == account.id
            && model.playback.itemID == baseline.id
    }

    private var editFailure: AppFailure? {
        switch model.bookEditSaveState {
        case .failed(let failure),
            .metadataSavedCoverFailed(_, _, _, let failure):
            failure
        case .idle, .saving, .stale, .saved, .coverSaved:
            nil
        }
    }

    @ViewBuilder
    private var coverSection: some View {
        let hasPendingCover = pendingCoverJPEGData != nil
        Section("Cover") {
            Group {
                if case .ready(let data) = pendingCover,
                    let image = PlatformImageSupport.image(from: data)
                {
                    PlatformImageSupport.resizableView(for: image)
                        .scaledToFit()
                } else {
                    BookCoverView(
                        accountID: model.account?.id,
                        server: model.account?.server,
                        itemID: baseline.id,
                        updatedAtMilliseconds:
                            baseline.updatedAtMilliseconds,
                        width: 600,
                        height: 600,
                        cornerRadius: 12
                    )
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity)

            PhotosPicker(
                selection: $selectedCoverItem,
                matching: .images
            ) {
                Label(
                    !hasPendingCover
                        ? "Choose Cover" : "Choose Another Cover",
                    systemImage: "photo"
                )
            }
            .disabled(isBusy || pendingCover == .processing)
            .accessibilityIdentifier("book.edit.cover")

            switch pendingCover {
            case .processing:
                ProgressView("Preparing cover")
            case .failed:
                Text("Choose a valid image and try again.")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("book.edit.coverError")
            case .unchanged, .ready:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var metadataSections: some View {
        Section("Book") {
            TextField("Title", text: $draft.title)
                .accessibilityIdentifier("metadata.title")
            TextField("Subtitle", text: $draft.subtitle)
            TextField("Authors", text: $authorsText)
            TextField("Narrators", text: $narratorsText)
            TextField("Series", text: $seriesText, axis: .vertical)
            TextField("Genres", text: $genresText)
            TextField("Tags", text: $tagsText)
        }

        Section("Publishing") {
            TextField("Published year", text: $draft.publishedYear)
            TextField("Published date", text: $draft.publishedDate)
            TextField("Publisher", text: $draft.publisher)
            TextField("Language", text: $draft.language)
            TextField("ISBN", text: $draft.isbn)
            TextField("ASIN", text: $draft.asin)
        }

        Section("Description") {
            TextEditor(text: $draft.description)
                .frame(minHeight: 140)
        }

        Section {
            Toggle("Explicit", isOn: $draft.isExplicit)
            Toggle("Abridged", isOn: $draft.isAbridged)
        }
    }

    private var staleAlertPresented: Binding<Bool> {
        Binding(
            get: {
                if case .stale = model.bookEditSaveState {
                    return true
                }
                return false
            },
            set: { presented in
                if !presented,
                    case .stale = model.bookEditSaveState
                {
                    model.resetBookEditSaveState()
                }
            }
        )
    }

    private var pendingCoverJPEGData: Data? {
        guard case .ready(let data) = pendingCover else {
            return nil
        }
        return data
    }

    private var deletionConfirmationMessage: String {
        let accountDescription: String
        if let account = model.account {
            let server =
                account.server.url.host
                ?? account.server.url.absoluteString
            accountDescription =
                "This affects \(account.user.username) on \(server). "
        } else {
            accountDescription = ""
        }
        let modeDescription =
            "Removing from the library leaves the server files in place. Deleting files removes the server media permanently."
        let playbackDescription =
            isActiveBook
            ? " Playback will stop and the local copy will also be deleted."
            : ""
        return accountDescription + modeDescription + playbackDescription
    }

    private var deletionWarningMessage: String {
        guard let status = deletionCleanupStatus else {
            return "The audiobook was deleted from the server."
        }
        switch (
            status.cacheCleanupFailed,
            status.localDownloadCleanupFailed
        ) {
        case (true, true):
            return "The server item was deleted, but Bleat could not fully clear its cached library data or local download."
        case (true, false):
            return "The server item was deleted, but Bleat could not fully clear its cached library data."
        case (false, true):
            return "The server item was deleted, but Bleat could not remove its local download."
        case (false, false):
            return "The audiobook was deleted from the server."
        }
    }

    private func prepareCover(_ item: PhotosPickerItem) async {
        pendingCover = .processing
        selectedCoverItem = nil
        model.resetBookEditSaveState()
        do {
            guard
                let sourceData = try await item.loadTransferable(
                    type: Data.self
                )
            else {
                throw CoverImageProcessingError.invalidImage
            }
            let jpegData = try await Task.detached {
                try CoverImageProcessor.jpegData(from: sourceData)
            }.value
            pendingCover = .ready(jpegData)
        } catch let error as CoverImageProcessingError {
            pendingCover = .failed(error)
        } catch {
            pendingCover = .failed(.invalidImage)
        }
    }

    private func save(overwrite: Bool) {
        updateDraftArrays()
        let submittedDraft = draft
        let submittedBaseline = baseline
        let submittedCover = pendingCoverJPEGData
        Task {
            await model.saveBookEdits(
                draft: submittedDraft,
                baseline: submittedBaseline,
                coverJPEGData: submittedCover,
                overwrite: overwrite
            )
        }
    }

    private func delete(mode: BookDeletionMode) {
        Task {
            await model.deleteBook(baseline, mode: mode)
        }
    }

    private func reloadServerVersion() {
        guard case .stale(let latest) = model.bookEditSaveState else {
            return
        }
        baseline = latest
        draft = BookMetadataDraft(detail: latest)
        authorsText = draft.authors.joined(separator: ", ")
        narratorsText = draft.narrators.joined(separator: ", ")
        seriesText = Self.seriesText(draft.series)
        genresText = draft.genres.joined(separator: ", ")
        tagsText = draft.tags.joined(separator: ", ")
        model.resetBookEditSaveState()
    }

    private func updateDraftArrays() {
        draft.authors = Self.list(from: authorsText)
        draft.narrators = Self.list(from: narratorsText)
        draft.series = seriesText.split(
            whereSeparator: \.isNewline
        ).compactMap { line in
            let components = line.split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard
                let name = components.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else {
                return nil
            }
            let sequence =
                components.count == 2
                ? components[1].trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                : ""
            return BookMetadataSeriesDraft(
                name: name,
                sequence: sequence
            )
        }
        draft.genres = Self.list(from: genresText)
        draft.tags = Self.list(from: tagsText)
    }

    private static func list(from text: String) -> [String] {
        text.split(separator: ",").compactMap { value in
            let normalized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func seriesText(
        _ series: [BookMetadataSeriesDraft]
    ) -> String {
        series.map { value in
            if value.sequence.isEmpty {
                return value.name
            }
            return "\(value.name)|\(value.sequence)"
        }.joined(separator: "\n")
    }
}
