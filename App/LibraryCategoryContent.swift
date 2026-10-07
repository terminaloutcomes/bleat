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
                                .secondary)
                            Image(systemName: "chevron.right").foregroundStyle(
                                .secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("library.category.\(category.id)")
                    .accessibilityLabel(
                        "\(category.name), \(category.bookCount) books")
                }
            }
        }
        .refreshable { await model.reloadBooks() }
    }
}
