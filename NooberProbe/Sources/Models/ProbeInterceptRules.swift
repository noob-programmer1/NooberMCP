import Foundation

/// Intercept rules hold matching requests until released.
/// When a request matches, the URLProtocol pauses it and logs it.
final class ProbeInterceptRules: @unchecked Sendable {
    static let shared = ProbeInterceptRules()

    struct InterceptRule {
        let id: UUID
        let name: String
        let urlPattern: String
        let matchMode: String
        let httpMethod: String?
    }

    private var rules: [InterceptRule] = []
    private let lock = NSLock()

    func addRule(_ rule: InterceptRule) {
        lock.lock()
        rules.append(rule)
        lock.unlock()
        fputs("[NooberProbe] Intercept rule added: \(rule.httpMethod ?? "ANY") \(rule.urlPattern)\n", stderr)
    }

    func removeRule(id: UUID) {
        lock.lock()
        rules.removeAll { $0.id == id }
        lock.unlock()
    }

    func allRules() -> [InterceptRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    /// Check if a request matches any intercept rule. Returns the rule if matched.
    func findMatch(for request: URLRequest) -> InterceptRule? {
        lock.lock()
        defer { lock.unlock() }

        let urlString = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"

        for rule in rules {
            if let ruleMethod = rule.httpMethod, !ruleMethod.isEmpty {
                if ruleMethod.uppercased() != method.uppercased() { continue }
            }
            switch rule.matchMode {
            case "prefix":
                if !urlString.hasPrefix(rule.urlPattern) { continue }
            case "regex":
                guard let regex = try? NSRegularExpression(pattern: rule.urlPattern) else { continue }
                let range = NSRange(urlString.startIndex..., in: urlString)
                if regex.firstMatch(in: urlString, range: range) == nil { continue }
            default:
                if !urlString.contains(rule.urlPattern) { continue }
            }
            return rule
        }
        return nil
    }
}
