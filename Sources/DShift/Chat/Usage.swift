import Foundation

/// Responses API input counts include cached reads and writes. Output includes reasoning tokens.
struct TokenUsage {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var longCacheWrite = 0

    // GPT-6.1 Sol standard prices per million tokens. Requests over 272K input tokens use long-context rates.
    var estimatedCost: Double {
        let inputPrice = input > 272_000 ? 4.0 : 2.0
        let outputPrice = input > 272_000 ? 15.0 : 10.0
        let ordinary = max(0, input - cacheRead - cacheWrite)
        let shortWrites = max(0, cacheWrite - longCacheWrite)
        return
            (Double(ordinary) * inputPrice + Double(cacheRead) * inputPrice * 0.05
            + Double(shortWrites) * inputPrice * 1.25 + Double(longCacheWrite) * inputPrice * 2.5
            + Double(output) * outputPrice) / 1_000_000
    }

    var costSummary: String { "\(input) in / \(output) out, $\(String(format: "%.3f", estimatedCost))" }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            longCacheWrite: lhs.longCacheWrite + rhs.longCacheWrite
        )
    }
}

extension TokenUsage {
    init(_ fields: JSON) {
        input = fields["input_tokens"] as? Int ?? 0
        output = fields["output_tokens"] as? Int ?? 0
        let details = fields["input_tokens_details"] as? JSON ?? [:]
        cacheRead = details["cached_tokens"] as? Int ?? 0
        cacheWrite = details["cache_write_tokens"] as? Int ?? 0
        longCacheWrite = (details["cache_write_tokens_details"] as? JSON)?["ttl_12h_tokens"] as? Int ?? 0
    }
}

/// Costs accumulate per request because long-context rates depend on each request's input size.
struct ChatUsage {
    static let contextWindow = OpenAIClient.contextWindow
    private(set) var totals = TokenUsage()
    private(set) var requests = 0
    private(set) var contextTokens = 0
    private(set) var estimatedCost = 0.0

    mutating func record(_ usage: TokenUsage) {
        totals = totals + usage
        requests += 1
        contextTokens = usage.input + usage.output
        estimatedCost += usage.estimatedCost
    }

    var contextFraction: Double { Double(contextTokens) / Double(Self.contextWindow) }
    var cacheHitRate: Double { totals.input == 0 ? 0 : Double(totals.cacheRead) / Double(totals.input) }
}
