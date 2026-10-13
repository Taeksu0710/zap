import Foundation
import FindFastCore

@main
struct FindFastCLI {
    static func main() async {
        // Matches the GUI's default (NSHomeDirectory()) rather than "/" —
        // both share the same persisted index.bin, keyed on scanRoot, so a
        // differing default here would make every alternating CLI/GUI run
        // invalidate the other's cache and force a full rescan.
        let args = CLIArguments.parse(CommandLine.arguments, defaultRoot: NSHomeDirectory())

        guard let term = args.searchTerm else {
            print("usage: findfast -s <term> [-p <root>]")
            exit(1)
        }
        let rootPath = args.rootPath

        let store = IndexStore()

        let buildStart = Date()
        let count = await store.loadOrBuild(root: rootPath)
        let buildDuration = Date().timeIntervalSince(buildStart)
        stderrPrint("indexed \(count) entries from \(rootPath) in \(String(format: "%.2f", buildDuration))s")

        let query = QueryParser.parse(term)
        let queryStart = Date()
        let results = await store.search(query)
        let queryDurationMs = Date().timeIntervalSince(queryStart) * 1000

        for r in results {
            print(r.path)
        }
        stderrPrint("\(results.count) results in \(String(format: "%.3f", queryDurationMs))ms")
    }

    static func stderrPrint(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
