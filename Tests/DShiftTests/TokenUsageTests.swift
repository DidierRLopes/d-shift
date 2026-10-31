import Testing

@testable import DShift

struct TokenUsageTests {
    @Test func cacheCountsStayInsideTotalInput() {
        let usage = TokenUsage([
            "input_tokens": 12000, "output_tokens": 0,
            "input_tokens_details": [
                "cached_tokens": 4000, "cache_write_tokens": 7000,
                "cache_write_tokens_details": ["ttl_30m_tokens": 3000, "ttl_12h_tokens": 4000],
            ],
        ])
        var chat = ChatUsage()
        chat.record(usage)
        #expect(chat.contextTokens == 12000)
        #expect(chat.cacheHitRate == 1.0 / 3.0)
        #expect(abs(chat.estimatedCost - 0.0299) < 0.000001)
    }

    @Test func costsAccumulateAtEachRequestsContextRate() {
        var chat = ChatUsage()
        chat.record(TokenUsage(input: 150_000, output: 1_000))
        chat.record(TokenUsage(input: 150_000, output: 1_000))
        #expect(chat.totals.input == 300_000)
        #expect(chat.contextTokens == 151_000)
        #expect(abs(chat.estimatedCost - 0.62) < 0.000001)
        chat.record(TokenUsage(input: 300_000, output: 1_000))
        #expect(abs(chat.estimatedCost - 1.835) < 0.000001)
    }

    @Test func summarizesGraphicsUsingTheSameTokenPricing() {
        #expect(TokenUsage(input: 1000, output: 2000).costSummary == "1000 in / 2000 out, $0.022")
        #expect(TokenUsage().costSummary == "0 in / 0 out, $0.000")
    }
}
