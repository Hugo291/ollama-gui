import Foundation
import OllamaKit
import Observation

/// State of the Discover section, kept while navigating between sections.
@MainActor
@Observable
final class DiscoverModel {
    var query = ""
    var filter: LibraryFilter = .all
    var sort: LibrarySort = .popular
    var selection: LibraryModel.ID?

    private(set) var results: [LibraryModel] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var error: String?
    private(set) var hasSearched = false

    @ObservationIgnored private var page = 1
    /// Results of an older search are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Whether ollama.com values are shown in French.
    let french = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") ?? false

    /// Searches from the first page; `debounce` waits while the query is being typed.
    func search(debounce: Bool = false) {
        searchTask?.cancel()
        generation += 1
        let generation = self.generation
        let query = self.query.trimmingCharacters(in: .whitespaces)
        let capability = filter.queryValue
        let sort = self.sort
        hasSearched = true
        isLoading = true
        isLoadingMore = false
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            do {
                let found = try await LibraryClient().search(query: query, capability: capability, sort: sort)
                guard let self, generation == self.generation else { return }
                results = found.models
                hasMore = found.hasMore
                page = 1
                error = nil
                if selection == nil || !results.contains(where: { $0.id == self.selection }) {
                    selection = results.first?.id
                }
            } catch {
                guard let self, generation == self.generation, !(error is CancellationError) else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.error = error.localizedDescription
                results = []
                hasMore = false
            }
            if let self, generation == self.generation {
                isLoading = false
            }
        }
    }

    /// The next page, when the list reaches its end. A failure just stops paging.
    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let generation = self.generation
        let next = page + 1
        let query = self.query.trimmingCharacters(in: .whitespaces)
        let capability = filter.queryValue
        let sort = self.sort
        Task { [weak self] in
            let found = try? await LibraryClient().search(query: query, capability: capability, sort: sort, page: next)
            guard let self, generation == self.generation else { return }
            isLoadingMore = false
            guard let found else {
                hasMore = false
                return
            }
            let known = Set(results.map(\.id))
            results += found.models.filter { !known.contains($0.id) }
            page = next
            hasMore = found.hasMore && !found.models.isEmpty
        }
    }
}
