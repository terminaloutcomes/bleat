import BleatCore
import SwiftUI

struct MetadataEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: LibraryBookDetail
    @State private var draft: BookMetadataDraft
    @State private var authorsText: String
    @State private var narratorsText: String
    @State private var seriesText: String
    @State private var genresText: String
    @State private var tagsText: String

    init(model: AppModel, detail: LibraryBookDetail) {
        self.model = model
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

                if case .failed(let failure) = model.metadataSaveState {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("metadata.error")
                    }
                }
            }
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.resetMetadataSaveState()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(overwrite: false)
                    }
                    .disabled(model.metadataSaveState == .saving)
                    .accessibilityIdentifier("metadata.save")
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
                    model.resetMetadataSaveState()
                }
            } message: {
                Text(
                    "This is a best-effort check. The server does not support atomic metadata preconditions."
                )
            }
            .onChange(of: model.metadataSaveState) { _, newState in
                if newState == .saved {
                    model.resetMetadataSaveState()
                    dismiss()
                }
            }
        }
    }

    private var staleAlertPresented: Binding<Bool> {
        Binding(
            get: {
                if case .stale = model.metadataSaveState {
                    return true
                }
                return false
            },
            set: { presented in
                if !presented,
                    case .stale = model.metadataSaveState
                {
                    model.resetMetadataSaveState()
                }
            }
        )
    }

    private func save(overwrite: Bool) {
        updateDraftArrays()
        let submittedDraft = draft
        let submittedBaseline = baseline
        Task {
            await model.saveMetadata(
                draft: submittedDraft,
                baseline: submittedBaseline,
                overwrite: overwrite
            )
        }
    }

    private func reloadServerVersion() {
        guard case .stale(let latest) = model.metadataSaveState else {
            return
        }
        baseline = latest
        draft = BookMetadataDraft(detail: latest)
        authorsText = draft.authors.joined(separator: ", ")
        narratorsText = draft.narrators.joined(separator: ", ")
        seriesText = Self.seriesText(draft.series)
        genresText = draft.genres.joined(separator: ", ")
        tagsText = draft.tags.joined(separator: ", ")
        model.resetMetadataSaveState()
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
