# Architecture

D-Shift is a single SwiftPM executable built on AppKit with SwiftUI views inside. It has no third-party dependencies.

## Components

| Area | Files | Responsibility |
|---|---|---|
| App | `App/AppDelegate.swift`, `App/SidebarController.swift`, `App/DoubleShiftMonitor.swift`, `App/ResizeHandle.swift`, `App/Config.swift` | Lifecycle, menu bar item, the panel window, the double-Shift trigger, edge resizing, settings |
| Context | `Context/AXSnapshot.swift`, `Context/AppTracker.swift` | Serializing the focused window's accessibility tree, following the frontmost app and window title live |
| Chat | `Chat/ChatModel.swift`, `Chat/ChatStore.swift`, `Chat/OpenAIClient.swift`, `Chat/Transcript.swift`, `Chat/Usage.swift` | One agent loop per tab, tab management, the streaming HTTP client, transcript entries, token accounting |
| Tools | `Tools/*.swift` | The `Tool` protocol, registry and validation, built-in tools, the shell policy |
| Memory | `Memory/Memory.swift` | Memory folder layout and seeding, the overview sent each turn, the JSONL chat log |
| UI | `UI/ChatView.swift` | Tabs, app header, transcript, tool cards, usage bar, input |

## The panel

`SidebarPanel` is a borderless `NSPanel` with `.nonactivatingPanel`. It can become key, so you can type into it, without activating D-Shift. The app you're asking about stays frontmost, so its accessibility tree and window title remain the "current" context. Other settings:

- `level = .floating` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, so it follows you across Spaces and over fullscreen apps.
- Visible in user screenshots and recordings; its own `take_screenshot` tool excludes the sidebar windows.
- A `NSVisualEffectView` backdrop at reduced opacity under a sibling `NSHostingView`. Only the backdrop is translucent, and the text stays fully opaque.
- Continuous-curve corners (`cornerCurve = .continuous`) to match macOS.

The window docks to the right edge. `ResizeHandle` views on the left, top, and bottom edges and the two left corners resize it with the opposite edges pinned, clamped to the screen. Size and distance from the top of the screen are saved to `UserDefaults`. Handles use always-active tracking areas for their cursors, because cursor rects only apply in the active app.

## Double-Shift detection

`DoubleShiftMonitor` listens to global and local `flagsChanged` and `keyDown` events. A tap is a Shift press and release under 250 ms with no other modifier. Two taps within 400 ms trigger it. Any other key resets the state, so typing capital letters never triggers it.

## Screen context

`AXSnapshot.capture(app:)` walks the focused window's accessibility tree (falling back to the main window), up to 3,000 nodes, depth 40, and 60k characters. Each node becomes one indented line: role, de-duplicated title, value, description, and placeholder text. The focused element is marked. Empty structural containers (`AXGroup` and similar) are skipped without adding indentation, to save tokens. Selected text is appended.

It sets `AXManualAccessibility` on the app element first, because Chrome and Electron only build a full tree once an assistive client asks for one.

`AppTracker` follows `NSWorkspace.didActivateApplicationNotification` for app switches, and an `AXObserver` for focused-window and title changes, so the header updates in real time.

## Agent loop

Each tab owns a `ChatModel` and a local history of Responses API items.

The user message contains the active app/window name and a memory overview. Screen content is read only when a tool needs it. `OpenAIClient` streams text to the transcript and preserves completed response items, including encrypted reasoning and message phases, for follow-up requests. Requests use `store: false`; the client supplies the conversation history.

Function calls pass through the existing registry, validation, per-turn limits, and approval flow. Each result refers to its `call_id` and can include text and images. OpenAI hosts web search; its progress appears in the transcript and URL annotations become clickable citations. Graphics use the same client and key as chat. Model and request settings live in `Chat/OpenAIClient.swift`.

Only a completed response can enter the tool loop. Failed or truncated streams roll back the current turn's API history. On cancellation, the question and visible partial answer survive as ordinary messages, with pending tool calls removed. This keeps later messages usable without retrying interrupted actions.

## Streaming smoothness

`TextEntry` buffers incoming text and reveals it on a 60 Hz timer. Each frame reveals `max(1, backlog / 8)` characters, so output flows evenly and stays within roughly 130 ms of the network. Each entry is its own `ObservableObject`, so only the streaming row re-renders. A `ScrollSignal` tick keeps the transcript pinned to the bottom unless you've scrolled up.

## Usage accounting

OpenAI input totals include cache reads and writes; those tokens must not be counted twice. `Chat/Usage.swift` owns token pricing and records cost per request so crossing a long-context threshold later does not reprice earlier requests. The sidebar's estimate covers chat tokens; it excludes hosted-tool fees and separate graphics requests.
