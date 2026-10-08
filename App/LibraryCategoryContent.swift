import BleatCore
import SwiftUI

struct LibraryCategoryContent: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            switch model.libraryCategories {
            case .idle, .loading:
                ProgressView().accessibilityIdentifier(
                    "library.categories.loading")
            case .failed(let failure):
                Text(failure.message)
                Button("Retry") { Task { await model.reloadBooks() } }
                    .accessibilityIdentifier("library.categories.retry")
            case .loaded(let categories):
                if case .failed(let failure) = model
                    .libraryCategoriesRefreshState
                {
                    RefreshFailureBanner(
                        failure: failure,
                        accessibilityIdentifier:
                            "library.categories.refreshFailure"
                    ) {
                        Task {
                            await model.reloadBooks(
                                preservingLoadedContent: true)
                        }
                    }
                }
                if categories.isEmpty {
                    ContentUnavailableView(
                        "No categories", systemImage: "books.vertical")
                }
                ForEach(categories) { category in
                    Button {
                        Task { await model.selectLibraryCategory(category) }
                    } label: {
                        HStack {
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(category.bookCount) books").foregroundStyle(
                                .primary)
                            Image(systemName: "chevron.right").foregroundStyle(
                                .secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("library.category.\(category.id)")
                    .accessibilityLabel(
                        "\(category.name), \(category.bookCount) books")
                }
            }
        }
        .refreshable { await model.reloadBooks(preservingLoadedContent: true) }
    }
}
