import Testing

@testable import DShift

@MainActor
struct ToolCallRepairTests {
    @Test func fillsOnlyMissingParallelResultsBeforeTheNextUserMessage() {
        var messages: [JSON] = [
            ["type": "reasoning", "encrypted_content": "opaque"],
            ["type": "function_call", "call_id": "one", "name": "read_screen", "arguments": "{}"],
            ["type": "function_call", "call_id": "two", "name": "search_memory", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "one", "output": "Screen content"],
            OpenAIClient.userMessage("Stop searching"),
        ]
        ChatModel.repairDanglingToolCalls(&messages)
        #expect(messages[0]["encrypted_content"] as? String == "opaque")
        #expect(messages[3]["output"] as? String == "Screen content")
        #expect(messages[4]["call_id"] as? String == "two")
        #expect(messages[4]["output"] as? String == "Cancelled before it ran.")
        #expect(messages[5]["role"] as? String == "user")
        ChatModel.repairDanglingToolCalls(&messages)
        #expect(messages.count == 6)
        #expect(messages[4]["call_id"] as? String == "two")
    }

    @Test func completesCallsAtTheEndOfHistory() {
        var messages: [JSON] = [["type": "function_call", "call_id": "one", "name": "read_screen", "arguments": "{}"]]
        ChatModel.repairDanglingToolCalls(&messages)
        #expect(messages[1]["type"] as? String == "function_call_output")
        #expect(messages[1]["call_id"] as? String == "one")
        #expect(messages[1]["output"] as? String == "Cancelled before it ran.")
    }
}
