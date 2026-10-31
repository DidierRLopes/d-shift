import Testing

@testable import DShift

struct SpeechTextTests {
    @Test func speaksExplanationsWithoutReadingMarkdownOrCode() {
        let reply = """
            ## How it works

            **Interest** grows over time. See [this example](https://example.com).

            ```swift
            print("do not narrate source code")
            ```

            - You earn interest on your interest.
            """
        #expect(
            SpeechText.chunks(reply).joined(separator: " ")
                == "How it works Interest grows over time. See this example. You earn interest on your interest.")
    }
}
