import Foundation

/// Thread-safe mock rules store for the probe.
/// Rules are added via Companion commands from NooberMCP.
final class ProbeMockRules: @unchecked Sendable {
    static let shared = ProbeMockRules()

    struct MockRule {
        let id: UUID
        let name: String
        let urlPattern: String
        let matchMode: String  // "contains", "prefix", "regex"
        let httpMethod: String?
        let statusCode: Int
        let responseBody: String
        let responseHeaders: [String: String]
    }

    private var rules: [MockRule] = []
    private let lock = NSLock()

    func addRule(_ rule: MockRule) {
        lock.lock()
        rules.append(rule)
        lock.unlock()
        fputs("[NooberProbe] Mock rule added: \(rule.httpMethod ?? "ANY") \(rule.urlPattern) → \(rule.statusCode)\n", stderr)
    }

    func removeRule(id: UUID) {
        lock.lock()
        rules.removeAll { $0.id == id }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        rules.removeAll()
        lock.unlock()
    }

    func allRules() -> [MockRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    /// Find a matching mock rule for a request
    func findMatch(for request: URLRequest) -> MockRule? {
        lock.lock()
        defer { lock.unlock() }

        let urlString = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"

        for rule in rules {
            // Check method match
            if let ruleMethod = rule.httpMethod, !ruleMethod.isEmpty {
                if ruleMethod.uppercased() != method.uppercased() { continue }
            }

            // Check URL pattern match
            switch rule.matchMode {
            case "prefix":
                if !urlString.hasPrefix(rule.urlPattern) { continue }
            case "regex":
                guard let regex = try? NSRegularExpression(pattern: rule.urlPattern) else { continue }
                let range = NSRange(urlString.startIndex..., in: urlString)
                if regex.firstMatch(in: urlString, range: range) == nil { continue }
            default: // "contains"
                if !urlString.contains(rule.urlPattern) { continue }
            }

            return rule
        }
        return nil
    }
}
