import AppKit

@MainActor
final class ChatModel: ObservableObject {
    private static let maxAgentIterations = 12
    private static let systemPrompt = """
        You are a sidebar assistant on the user's Mac. Each user message starts with a <context> line naming the app and \
        window the user is looking at. You don't see the window's contents until you ask for them.

        Reading the screen: when the question is about what's on screen ("this", "here", "explain this page", anything \
        referring to the window), call read_screen first. It returns the window's accessibility tree: lines indented by \
        nesting with role plus quoted text, and "<- FOCUSED" on the focused element. Skip it for questions that don't \
        need the screen (general knowledge, memory, web, follow-ups you can already answer). Ground on-screen answers in \
        what it returned and quote exact text when useful. Call it again if the user says the screen changed. Be concise: this is a narrow sidebar, so prefer short paragraphs and lists.

        The user can attach their own screenshots or images to a message; they arrive as images before the text. \
        Treat them as what the user wants you to look at.

        Web: use web_search to search the web and open pages. Use them for anything current, \
        factual, or outside what's on screen, and cite the pages you used with their URLs. Don't search for things the \
        screen already answers.

        Explaining visually: when the user asks you to explain, teach, compare, or walk through something, show it on \
        their screen without waiting to be asked. The sidebar is narrow, so the screen is where explanations belong:
        - draw_on_screen is the default: point at the things on screen and annotate them, or draw a standalone visual \
          for general concepts. Keep it to a few large, short labels; a picture with too many words can't be read.
        - show_3d_model for physical or spatial things: machines, molecules, anatomy, flows around objects.
        - scratchpad for working through steps, math, or a plan the user may want to keep or edit.
        - make_diagram renders a small Mermaid image inside the sidebar. Use it only when the user explicitly asks for a \
          diagram in the chat.
        After drawing, keep the chat reply to a sentence or two. Never draw ASCII diagrams; the sidebar's font isn't \
        monospaced.

        Screenshots: read_screen is cheaper and usually enough. Call take_screenshot only when answering genuinely \
        depends on visual information it lacks: images, charts, canvas or design apps, visual layout or styling, or a \
        read_screen result that is empty or clearly missing the content the user is asking about.

        Acting on the computer: when the user asks you to do something in their apps (send a message, fill in a form, \
        navigate somewhere, organize files) and use_computer is available, call it with one complete, self-contained \
        task. It runs in the background through Codex, which can't see this conversation, so include every detail it \
        needs: app names, exact text, recipients, and when to stop. The user approves each task first. Never use it just \
        to look at the screen, and report its result plainly, including anything it couldn't do.

        Memory: you have a persistent memory of the user, a folder of markdown files. The <memory> block holds me.md \
        (their profile) and the list of files. Treat it as your own background knowledge:
        - Before answering anything that may depend on the user's people, projects, preferences, or history, search it \
          with search_memory (for example `rg -n -i "acme" .`).
        - When you learn something durable about the user (who they work with, what they're working on, how they like \
          things written, stable preferences), save it with write_memory without asking. Put people in \
          people/<name>.md, projects in projects/<name>.md, the user's own profile in me.md, and small facts in notes.md. \
          Update existing files rather than duplicating.
        - Don't save transient details, secrets, or anything the user asks you not to keep.
        - Use memory silently. Don't announce searches or saves, and don't mention memory unless the user asks about it.
        """

    let id: UUID
    private let createdAt: Date
    @Published private(set) var title = "New chat"
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published var input = ""
    @Published private(set) var attachments: [Attachment] = []
    @Published private(set) var turnStartedAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var isStreamingText = false
    /// True while a tool call is streaming in or running. Its row shows its own loader, so the Thinking row hides.
    @Published private(set) var isToolActive = false
    @Published private(set) var queue: [QueuedMessage] = []
    @Published private(set) var isQueuePaused = false
    @Published private(set) var usage = ChatUsage()
    @Published var focusRequest = 0
    /// Commands that act on tabs rather than this chat (/new, /history) go to the store.
    var onStoreCommand: ((SlashCommand) -> Void)?
    var onReply: ((_ text: String, _ entryID: UUID) -> Void)?

    let tracker: AppTracker
    let scroll = ScrollSignal()

    private let tools: ToolRegistry
    private var apiMessages: [JSON] = []
    private var runTask: Task<Void, Never>?
    /// Every tool call in flight, including hidden ones that never get a transcript row.
    private var toolCalls: [String: ToolCallEntry] = [:]
    private var callsThisTurn: [String: Int] = [:]
    private var pendingTakeover: QueuedMessage?

    init(tracker: AppTracker, restoring saved: SavedChat? = nil) {
        self.tracker = tracker
        id = saved?.id ?? UUID()
        createdAt = saved?.createdAt ?? Date()
        if let saved {
            title = saved.title
            entries = saved.entries.map { Self.transcriptEntry(from: $0, chat: saved.id) }
            apiMessages = ChatArchive.apiMessages(for: saved)
        }
        var available: [Tool] = [
            ReadScreenTool(tracker: tracker), ScreenshotTool(tracker: tracker), MemorySearchTool(), MemoryWriteTool(),
            DiagramTool(), ScratchpadTool(), OverlayTool(tracker: tracker), ModelTool(),
        ]
        if let codexPath = ComputerUseTool.locateCodex() {
            available.append(ComputerUseTool(codexPath: codexPath))
        }
        tools = ToolRegistry(tools: available)
    }

    func toggleDictation() {
        let dictation = DictationController.shared
        switch dictation.phase {
        case .idle:
            SpeechController.shared.stop()
            dictation.start(chatID: id) { [weak self] text, shouldSend in
                guard let self else { return }
                input += input.isEmpty || input.last?.isWhitespace == true ? text : " " + text
                if shouldSend { send() } else { focusRequest += 1 }
            }
        case .recording:
            dictation.finish()
        case .authorizing, .transcribing:
            dictation.cancel()
        }
    }

    /// Return: sends now when idle, otherwise queues behind the running turn.
    func send() {
        guard let message = takeInput() else { return }
        if handleCommand(message) { return }
        isQueuePaused = false
        if isRunning {
            queue.append(message)
        } else {
            start(message)
        }
    }

    /// Cmd+Return: skips the queue, interrupting the running turn if there is one.
    func sendNow() {
        guard let message = takeInput() else { return }
        if handleCommand(message) { return }
        takeOver(with: message)
    }

    func sendQueuedNow(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        takeOver(with: queue.remove(at: index))
    }

    func attach(_ image: NSImage) {
        guard let attachment = Attachment(image: image) else { return }
        attachments.append(attachment)
        focusRequest += 1
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Attaches a screenshot of the window the user was looking at before they clicked into the sidebar.
    /// Appshot: attaches a screenshot of the window the user was looking at, labeled with its app and title.
    func attachWindowScreenshot() async {
        let app = tracker.app
        let windowTitle = tracker.windowTitle
        let output = try? await ScreenshotTool(tracker: tracker).run(["scope": "window"])
        guard let jpeg = output?.jpeg, var attachment = Attachment(jpeg: jpeg) else {
            Log.info("appshot", "capture failed for \(app?.localizedName ?? "no app")")
            return
        }
        attachment.source = Attachment.Source(
            appName: app?.localizedName ?? "Screen", windowTitle: windowTitle, icon: app?.icon)
        attachments.append(attachment)
        focusRequest += 1
    }

    func removeQueued(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    func resumeQueue() {
        isQueuePaused = false
        if !isRunning { advanceQueue() }
    }

    /// Stops the running turn. Queued messages stay but pause until the user sends or resumes.
    func stop() {
        if !queue.isEmpty { isQueuePaused = true }
        interrupt()
    }

    private func takeInput() -> QueuedMessage? {
        DictationController.shared.cancel(for: id)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        let message = QueuedMessage(text: text, attachments: attachments)
        input = ""
        attachments = []
        return message
    }

    private func takeOver(with message: QueuedMessage) {
        isQueuePaused = false
        guard isRunning else { return start(message) }
        pendingTakeover = message
        interrupt()
    }

    private func interrupt() {
        DictationController.shared.cancel(for: id)
        SpeechController.shared.stop(for: id)
        runTask?.cancel()
        for case .tool(let call) in entries where !call.isFinished {
            if call.status == .awaitingApproval { call.resolveApproval(false) }
            if call.accessRequest != nil { call.resolveAccess(.deny) }
            // Calls that were still streaming in never run; don't leave them spinning.
            if call.status == .preparing { call.status = .cancelled }
        }
    }

    private func start(_ message: QueuedMessage) {
        SpeechController.shared.stop(for: id)
        let question = message.text.isEmpty ? "What do you make of this screenshot?" : message.text
        if entries.isEmpty { title = String(question.prefix(28)) }
        entries.append(.text(TextEntry(role: .user, text: message.text, attachments: message.attachments)))
        save()
        let historyNote = message.attachments.isEmpty ? "" : "\n[\(message.attachments.count) image(s) attached]"
        ChatHistory.append(role: "user", text: question + historyNote, app: tracker.app?.localizedName, chat: id)
        isRunning = true
        turnStartedAt = Date()
        runTask = Task {
            await runTurn(question: question, attachments: message.attachments)
            isRunning = false
            isToolActive = false
            turnStartedAt = nil
            save()
            advanceQueue()
        }
    }

    private func advanceQueue() {
        if let takeover = pendingTakeover {
            pendingTakeover = nil
            start(takeover)
        } else if !isQueuePaused, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    // MARK: - Agent loop

    private func runTurn(question: String, attachments: [Attachment]) async {
        let checkpoint = apiMessages.count
        callsThisTurn = [:]
        toolCalls = [:]
        let firstReplyIndex = entries.count
        let content = userContent(for: question)
        let imageBlocks: [JSON] = attachments.flatMap { attachment -> [JSON] in
            let image = OpenAIClient.image(attachment.jpeg)
            guard let source = attachment.source else { return [image] }
            let label =
                source.windowTitle.isEmpty ? source.appName : "\(source.appName), window \"\(source.windowTitle)\""
            return [["type": "input_text", "text": "Appshot of \(label):"], image]
        }
        apiMessages.append([
            "type": "message", "role": "user", "content": imageBlocks + [["type": "input_text", "text": content]],
        ])

        do {
            for _ in 0..<Self.maxAgentIterations {
                let message = try await streamAssistantMessage()
                apiMessages += message.output
                usage.record(message.usage)
                guard !message.functionCalls.isEmpty else {
                    let text = message.output.filter { $0["phase"] as? String != "commentary" }
                        .map { OpenAIResponse.text(in: $0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    if let entry = entries.last(where: {
                        if case .text(let text) = $0 { return text.role == .assistant }
                        return false
                    }), !text.isEmpty {
                        onReply?(text, entry.id)
                    }
                    return
                }
                apiMessages += await runTools(in: message)
                try Task.checkCancellation()
                isToolActive = false
            }
            appendNote("Stopped after \(Self.maxAgentIterations) steps.")
        } catch is CancellationError {
            keepInterruptedTurn(
                since: checkpoint, userContent: imageBlocks + [["type": "input_text", "text": content]],
                firstReplyIndex: firstReplyIndex)
        } catch  where Task.isCancelled {
            keepInterruptedTurn(
                since: checkpoint, userContent: imageBlocks + [["type": "input_text", "text": content]],
                firstReplyIndex: firstReplyIndex)
        } catch {
            if let incomplete = error as? OpenAIIncompleteResponse { usage.record(incomplete.usage) }
            // Roll back to before this turn so the transcript never holds a function call without its result.
            apiMessages.removeSubrange(checkpoint...)
            appendNote("**Error:** \(error.localizedDescription)")
        }
    }

    /// After a stop or takeover, keep the question and whatever was said so far as plain text, so the next message
    /// has context. Tool calls from the interrupted turn are dropped to keep the transcript valid.
    private func keepInterruptedTurn(since checkpoint: Int, userContent: [JSON], firstReplyIndex: Int) {
        let partialReply = entries.dropFirst(firstReplyIndex)
            .compactMap { if case .text(let entry) = $0, entry.role == .assistant { entry.text } else { nil } }
            .joined(separator: "\n\n")
        apiMessages.removeSubrange(checkpoint...)
        apiMessages.append(["type": "message", "role": "user", "content": userContent])
        apiMessages.append([
            "type": "message", "role": "assistant",
            "content": partialReply.isEmpty
                ? "(Interrupted by the user before answering.)"
                : partialReply + "\n\n(Interrupted by the user.)",
        ])
        appendNote("Stopped.")
    }

    private func streamAssistantMessage() async throws -> OpenAIResponse {
        defer { isStreamingText = false }
        var response: OpenAIResponse?
        var textEntries: [Int: TextEntry] = [:]
        var serverCalls: [Int: ToolCallEntry] = [:]
        defer {
            textEntries.values.forEach { $0.flush() }
            if response == nil || Task.isCancelled {
                for entry in Array(toolCalls.values) + Array(serverCalls.values) where !entry.isFinished {
                    entry.status = Task.isCancelled ? .cancelled : .failed
                }
            }
        }

        Self.repairDanglingToolCalls(&apiMessages)
        for try await event in OpenAIClient.stream(
            instructions: Self.systemPrompt, input: apiMessages, tools: tools.definitions + [["type": "web_search"]])
        {
            switch event {
            case .text(let index, let delta):
                if textEntries[index] == nil {
                    let entry = TextEntry(role: .assistant, scroll: scroll)
                    textEntries[index] = entry
                    entries.append(.text(entry))
                }
                textEntries[index]?.enqueue(delta)
                isStreamingText = true
            case .itemAdded(let index, let item):
                switch item["type"] as? String {
                case "function_call":
                    isToolActive = true
                    let entry = ToolCallEntry(
                        toolUseID: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "tool")
                    toolCalls[entry.toolUseID] = entry
                    if (try? tools.tool(named: entry.name))?.isHidden != true { entries.append(.tool(entry)) }
                case "web_search_call":
                    let entry = ToolCallEntry(toolUseID: item["id"] as? String ?? "", name: "web_search")
                    entry.status = .running
                    serverCalls[index] = entry
                    entries.append(.tool(entry))
                default: break
                }
            case .itemDone(let index, let item):
                if let entry = serverCalls[index] {
                    entry.input = item["action"] as? JSON ?? [:]
                    entry.output = entry.inputSummary
                    entry.status = item["status"] as? String == "failed" ? .failed : .succeeded
                }
                if item["type"] as? String == "message" {
                    let text = OpenAIResponse.text(in: item)
                    if let entry = textEntries[index] {
                        entry.replace(with: text)
                    } else if !text.isEmpty {
                        let entry = TextEntry(role: .assistant, text: text, scroll: scroll)
                        textEntries[index] = entry
                        entries.append(.text(entry))
                    }
                }
            case .completed(let completed):
                response = completed
            }
        }
        try Task.checkCancellation()
        guard let response else { throw ToolError.failed("OpenAI stream ended before completion.") }
        for entry in textEntries.sorted(by: { $0.key < $1.key }).map({ $0.value }) {
            entry.flush()
            ChatHistory.append(role: "assistant", text: entry.text, app: tracker.app?.localizedName, chat: id)
        }
        return response
    }

    private func runTools(in message: OpenAIResponse) async -> [JSON] {
        var results: [JSON] = []
        for call in message.functionCalls {
            let id = call["call_id"] as? String ?? ""
            let entry =
                toolCalls.removeValue(forKey: id)
                ?? ToolCallEntry(toolUseID: id, name: call["name"] as? String ?? "tool")
            let arguments = Data((call["arguments"] as? String ?? "").utf8)
            let input = (try? JSONSerialization.jsonObject(with: arguments)) as? JSON
            let (output, isError) = await execute(input, entry: entry)
            var content: [JSON] = [["type": "input_text", "text": isError ? "Error: " + output.text : output.text]]
            if let jpeg = output.jpeg { content.append(OpenAIClient.image(jpeg)) }
            results.append(["type": "function_call_output", "call_id": id, "output": content])
        }
        return results
    }

    private func execute(_ input: JSON?, entry: ToolCallEntry) async -> (ToolOutput, Bool) {
        do {
            guard let input else { throw ToolError.invalidInput("arguments were not valid JSON") }
            try Task.checkCancellation()
            entry.input = input
            let tool = try tools.tool(named: entry.name)
            try tools.validate(input, for: tool)
            callsThisTurn[tool.name, default: 0] += 1
            if let limit = tool.maxCallsPerTurn, callsThisTurn[tool.name, default: 0] > limit {
                throw ToolError.limitReached(tool.name, limit)
            }

            if tool.requiresApproval(for: input), !AutoMode.isOn, !(await entry.requestApproval()) {
                entry.status = .denied
                return (ToolOutput(text: "The user declined this action."), true)
            }
            entry.status = .running
            // Its own task so the row's Stop button can cancel just this tool and let the assistant carry on.
            let work = Task {
                try await tool.run(
                    input,
                    progress: { [weak self] progress in
                        entry.output = progress
                        self?.scroll.tick += 1
                    },
                    requestAccess: { [weak self] app in
                        if AutoMode.isOn {
                            Log.info("auto", "allowed \(app) for this task")
                            return .once
                        }
                        self?.scroll.tick += 1
                        return await entry.requestAccess(app: app)
                    })
            }
            entry.onCancel = {
                work.cancel()
                if entry.accessRequest != nil { entry.resolveAccess(.deny) }
            }
            defer { entry.onCancel = nil }
            let output = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            Log.info("tool", "\(entry.name) ok: \(output.text.prefix(300))")
            entry.output = output.text
            entry.image = output.jpeg.flatMap(NSImage.init(data:))
            entry.status = .succeeded
            scroll.tick += 1
            return (output, false)
        } catch  where error is CancellationError || entry.isCancelRequested {
            Log.info("tool", "\(entry.name) cancelled")
            entry.output = "Cancelled."
            entry.status = .cancelled
            scroll.tick += 1
            return (ToolOutput(text: "The user cancelled this before it finished. Don't retry unless they ask."), true)
        } catch {
            Log.info("tool", "\(entry.name) failed: \(error.localizedDescription)")
            entry.output = error.localizedDescription
            entry.status = .failed
            scroll.tick += 1
            return (ToolOutput(text: error.localizedDescription), true)
        }
    }

    /// Complete any interrupted function calls before the next user message so saved chats remain usable.
    static func repairDanglingToolCalls(_ messages: inout [JSON]) {
        var pending: [String] = []
        var repaired: [JSON] = []
        for message in messages {
            if message["role"] as? String == "user" {
                repaired += pending.map {
                    ["type": "function_call_output", "call_id": $0, "output": "Cancelled before it ran."]
                }
                pending = []
            }
            if message["type"] as? String == "function_call", let id = message["call_id"] as? String {
                pending.append(id)
            }
            if message["type"] as? String == "function_call_output", let id = message["call_id"] as? String {
                pending.removeAll { $0 == id }
            }
            repaired.append(message)
        }
        repaired += pending.map {
            ["type": "function_call_output", "call_id": $0, "output": "Cancelled before it ran."]
        }
        messages = repaired
    }

    // MARK: - Context

    /// Only names the app and window. The contents are read on demand with read_screen, like screenshots,
    /// so questions that don't need the screen don't pay for it.
    private func userContent(for question: String) -> String {
        let app = tracker.app?.localizedName ?? "none"
        return [
            "<context app=\"\(app)\" window=\"\(tracker.windowTitle)\" />",
            "<memory>\n\(Memory.overview())\n</memory>",
            question,
        ].joined(separator: "\n\n")
    }

    private func appendNote(_ text: String) {
        entries.append(.text(TextEntry(role: .assistant, text: "_\(text)_")))
    }

    /// Runs a bare `/command`. Returns false for ordinary messages, which are sent to OpenAI.
    private func handleCommand(_ message: QueuedMessage) -> Bool {
        guard message.attachments.isEmpty, message.text.hasPrefix("/") else { return false }
        guard let command = SlashCommand.exact(message.text) else {
            appendNote("Unknown command \(message.text). Type /help for the list.")
            return true
        }
        switch command {
        case .clear:
            clear()
        case .auto:
            AutoMode.isOn.toggle()
            autoModeChanged += 1
            appendNote(
                AutoMode.isOn
                    ? "Auto mode on: computer use runs without asking. Shift+Tab or /auto to turn it off."
                    : "Auto mode off: computer use asks first.")
        case .copy:
            let lastReply = entries.reversed().lazy.compactMap { entry -> String? in
                if case .text(let text) = entry, text.role == .assistant, !text.text.hasPrefix("_") { return text.text }
                return nil
            }.first
            if let lastReply {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lastReply, forType: .string)
            }
            appendNote(lastReply == nil ? "Nothing to copy yet." : "Copied the last reply.")
        case .memory:
            NSWorkspace.shared.open(Storage.memoryDir)
        case .help:
            appendNote(SlashCommand.allCases.map { "\($0.name): \($0.summary)" }.joined(separator: "\n"))
        case .new, .history:
            onStoreCommand?(command)
        }
        return true
    }

    func toggleAutoMode() {
        AutoMode.isOn.toggle()
        autoModeChanged += 1
    }

    /// Bumped when auto mode flips so views re-read it.
    @Published private(set) var autoModeChanged = 0

    private func clear() {
        queue = []
        pendingTakeover = nil
        isQueuePaused = false
        interrupt()
        entries = []
        attachments = []
        apiMessages = []
        usage = ChatUsage()
        title = "New chat"
        ChatArchive.delete(id)
    }

    // MARK: - Persistence

    private func save() {
        guard !entries.isEmpty else { return }
        var savedEntries: [SavedChat.Entry] = []
        var allAttachments: [Attachment] = []
        for entry in entries {
            switch entry {
            case .text(let text):
                allAttachments += text.attachments
                savedEntries.append(
                    SavedChat.Entry(
                        kind: text.role == .user ? .user : .assistant,
                        text: text.text,
                        attachmentIDs: text.attachments.map(\.id)
                    ))
            case .tool(let call):
                savedEntries.append(
                    SavedChat.Entry(
                        kind: .tool,
                        text: call.output,
                        toolName: call.name,
                        toolInput: call.inputSummary,
                        toolFailed: [.failed, .denied, .cancelled].contains(call.status)
                    ))
            }
        }
        let chat = SavedChat(
            id: id, title: title, createdAt: createdAt, updatedAt: Date(),
            app: tracker.app?.localizedName, entries: savedEntries
        )
        ChatArchive.save(chat, apiMessages: apiMessages, attachments: allAttachments)
    }

    private static func transcriptEntry(from saved: SavedChat.Entry, chat: UUID) -> TranscriptEntry {
        switch saved.kind {
        case .user, .assistant:
            let attachments = saved.attachmentIDs.compactMap { ChatArchive.attachment($0, in: chat) }
            return .text(
                TextEntry(role: saved.kind == .user ? .user : .assistant, text: saved.text, attachments: attachments))
        case .tool:
            let call = ToolCallEntry(toolUseID: "", name: saved.toolName ?? "tool")
            let inputData = Data((saved.toolInput ?? "").utf8)
            call.input = (try? JSONSerialization.jsonObject(with: inputData)) as? JSON ?? [:]
            call.output = saved.text
            call.status = saved.toolFailed == true ? .failed : .succeeded
            return .tool(call)
        }
    }
}
