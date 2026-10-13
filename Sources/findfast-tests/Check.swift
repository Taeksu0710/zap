import Foundation

/// Minimal dependency-free assertion collector, standing in for
/// XCTest/swift-testing in a CommandLineTools-only toolchain where neither
/// is available.
@MainActor
final class Check {
    private(set) var failures: [String] = []
    private var currentSuite = ""

    func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    func suite(_ name: String, _ body: () async throws -> Void) async {
        currentSuite = name
        do {
            try await body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: String = #file, line: Int = #line) {
        if actual != expected {
            failures.append("\(currentSuite)/\(label): expected \(expected), got \(actual) (\(file):\(line))")
        }
    }

    func isTrue(_ condition: Bool, _ label: String, file: String = #file, line: Int = #line) {
        if !condition {
            failures.append("\(currentSuite)/\(label): expected true (\(file):\(line))")
        }
    }

    func isFalse(_ condition: Bool, _ label: String, file: String = #file, line: Int = #line) {
        if condition {
            failures.append("\(currentSuite)/\(label): expected false (\(file):\(line))")
        }
    }

    func report() -> Bool {
        if failures.isEmpty {
            print("all checks passed")
            return true
        }
        print("\(failures.count) check(s) failed:")
        for f in failures {
            print("  - \(f)")
        }
        return false
    }
}
