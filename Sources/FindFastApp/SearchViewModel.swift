import Foundation
import FindFastCore

@MainActor
final class SearchViewModel: ObservableObject {
    // "findfast" here is a legacy identifier predating the "Zap" rebrand —
    // left as-is deliberately. UserDefaults keys are permanent once written;
    // renaming this would silently lose every existing user's saved root
    // path (falls back to NSHomeDirectory(), triggering a surprise rescan)
    // for a purely cosmetic gain.
    private static let rootPathDefaultsKey = "net.youngsam.findfast.rootPath"

    @Published var rootPath: String
    @Published var queryText: String = ""
    @Published var sortOrder: SearchSortOrder = .modified {
        didSet {
            guard oldValue != sortOrder else { return }
            switch sortOrder {
            case .relevance, .name: sortAscending = true
            case .modified, .created: sortAscending = false
            }
        }
    }
    @Published var sortAscending: Bool = false
    @Published var results: [SearchResult] = []
    @Published var statusText: String = "Not indexed yet"
    @Published var isIndexing: Bool = false

    private let store = IndexStore()
    private var searchTask: Task<Void, Never>?

    init() {
        // Remember the last root across launches — without this, the field
        // resets to the hardcoded default every time, so switching to a new
        // folder "doesn't stick" and looks like it forces a rescan on every
        // single launch even after it's already been indexed once.
        //
        // Default to the whole home directory, not some narrow demo path:
        // the point of this app is "scan once, then it just works" without
        // the user having to think about paths at all.
        self.rootPath = UserDefaults.standard.string(forKey: Self.rootPathDefaultsKey)
            ?? NSHomeDirectory()
    }

    /// Called on first appearance, and whenever the user submits a new root
    /// path: loads a previously persisted index for `rootPath` if one
    /// exists (near-instant), or does a full scan and persists it. Either
    /// way, re-scanning the SAME root later (including across app restarts)
    /// is a cache load, not a full rescan.
    func loadAndWatch() {
        guard !isIndexing else { return }
        UserDefaults.standard.set(rootPath, forKey: Self.rootPathDefaultsKey)
        isIndexing = true
        statusText = "Loading index for \(rootPath)…"
        Task {
            let start = Date()
            let count = await store.loadOrBuild(root: rootPath)
            let duration = Date().timeIntervalSince(start)
            statusText = "Ready: \(count) entries (\(String(format: "%.2f", duration))s)"
            isIndexing = false
            await store.startWatching(root: rootPath)
            runSearch()
        }
    }

    /// Called from the "Scan" button: always does a full re-scan (ignoring
    /// any persisted cache) and re-saves it.
    func rebuildIndex() {
        guard !isIndexing else { return }
        UserDefaults.standard.set(rootPath, forKey: Self.rootPathDefaultsKey)
        isIndexing = true
        statusText = "Indexing \(rootPath)…"
        Task {
            let start = Date()
            let count = await store.build(root: rootPath)
            await store.saveIndex()
            let duration = Date().timeIntervalSince(start)
            statusText = "Indexed \(count) entries in \(String(format: "%.2f", duration))s"
            isIndexing = false
            await store.startWatching(root: rootPath)
            runSearch()
        }
    }

    func queryChanged() {
        runSearch()
    }

    private func runSearch() {
        searchTask?.cancel()
        let text = queryText
        searchTask = Task {
            let parsed = QueryParser.parse(text)
            let start = Date()
            let found = await store.search(parsed, limit: 500, sortOrder: sortOrder, ascending: sortAscending)
            guard !Task.isCancelled else { return }
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            self.results = found
            if !text.isEmpty {
                self.statusText = "\(found.count) results in \(String(format: "%.2f", elapsedMs))ms"
            }
        }
    }
}
