import Foundation

/// Pure argument-parsing logic for the `findfast` CLI, split out from
/// `FindFastCLI.main()` so it's unit-testable without exercising `main()`'s
/// real `exit(1)` process-lifecycle side effect on missing input.
public struct CLIArguments: Equatable {
    public var searchTerm: String?
    public var rootPath: String

    public static func parse(_ arguments: [String], defaultRoot: String) -> CLIArguments {
        var searchTerm: String?
        var rootPath = defaultRoot
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "-s", "--search":
                i += 1
                if i < arguments.count { searchTerm = arguments[i] }
            case "-p", "--path":
                i += 1
                if i < arguments.count { rootPath = arguments[i] }
            default:
                break
            }
            i += 1
        }
        return CLIArguments(searchTerm: searchTerm, rootPath: rootPath)
    }
}
