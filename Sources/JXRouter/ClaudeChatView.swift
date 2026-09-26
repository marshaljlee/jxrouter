import SwiftUI

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var thinking: String?
    var toolCalls: [ToolCallInfo]?
    var routeProvider: String?
    var timestamp: Date

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        thinking: String? = nil,
        toolCalls: [ToolCallInfo]? = nil,
        routeProvider: String? = nil,
        timestamp: Date = .init()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.routeProvider = routeProvider
        self.timestamp = timestamp
    }

    init(persisted: PersistedChatMessage) {
        self.id = UUID(uuidString: persisted.id) ?? UUID()
        self.role = persisted.role == "user" ? .user : .assistant
        self.content = persisted.content
        self.thinking = persisted.thinking
        self.toolCalls = persisted.toolCalls?.map {
            let status: ToolCallInfo.Status = $0.status == "running" ? .running : ($0.status == "denied" ? .denied : .completed)
            return ToolCallInfo(name: $0.name, status: status, filePath: $0.filePath)
        }
        self.routeProvider = persisted.routeProvider
        self.timestamp = persisted.timestamp
    }

    func toPersisted() -> PersistedChatMessage {
        PersistedChatMessage(
            id: id.uuidString,
            role: role == .user ? "user" : "assistant",
            content: content,
            thinking: thinking,
            toolCalls: toolCalls?.map {
                let st = $0.status == .running ? "running" : ($0.status == .denied ? "denied" : "completed")
                return PersistedToolCall(name: $0.name, status: st, filePath: $0.filePath)
            },
            routeProvider: routeProvider,
            timestamp: timestamp
        )
    }

    enum Role { case user, assistant }
}

struct ToolCallInfo: Identifiable {
    let id: UUID
    let name: String
    let status: Status
    var filePath: String?
    var arguments: String?

    init(id: UUID = UUID(), name: String, status: Status, filePath: String? = nil, arguments: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.filePath = filePath
        self.arguments = arguments
    }

    enum Status { case running, completed, denied }
}

// MARK: - Chat View

struct ClaudeChatView: View {
    @Bindable var manager: ProxyManager
    var agentSystemPrompt: String? = nil
    @State private var messages: [ChatMessage] = []

    private var welcomeMessage: ChatMessage {
        let content = agentSystemPrompt != nil
            ? "Agent session started. System prompt loaded. How can I help?"
            : "Welcome to **Vault**. I'm your Claude Code assistant, routed through JXRouter.\n\nChoose a vault or start chatting directly."
        return ChatMessage(
            role: .assistant,
            content: content,
            routeProvider: manager.activeProviderName
        )
    }
    @State private var inputText = ""
    @State private var isStreaming = false
    @State private var selectedSession: String? = nil
    @State private var showSessions = false

    private func currentSessionId() -> String {
        selectedSession ?? "default"
    }

    private func loadSessionMessages() {
        let sid = currentSessionId()
        let persisted = DataStore.shared.loadMessages(sessionId: sid)
        if !persisted.isEmpty {
            messages = persisted.map { ChatMessage(persisted: $0) }
        } else {
            messages = [welcomeMessage]
        }
    }

    private func saveSessionMessages() {
        let sid = currentSessionId()
        let toSave = messages.map { $0.toPersisted() }
        DataStore.shared.saveMessages(sessionId: sid, messages: toSave)
        if let sId = selectedSession {
            DataStore.shared.updateSession(id: sId, messageCount: toSave.count)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Session sidebar (collapsible)
            if showSessions {
                SessionSidebar(selectedSession: $selectedSession)
                    .frame(width: 220)
                Divider().overlay(Color.dsBorder)
            }

            // Main chat area
            VStack(spacing: 0) {
                // Top bar
                ChatTopBar(
                    showSessions: $showSessions,
                    sessionTitle: selectedSession ?? "New Session",
                    model: manager.currentModel.isEmpty ? "claude-sonnet-4" : manager.currentModel
                )

                Divider().overlay(Color.dsBorder)

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }

                            if isStreaming {
                                StreamingIndicator()
                                    .id("streaming")
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                    }
                }

                Divider().overlay(Color.dsBorder)

                // Route badge + input
                VStack(spacing: 0) {
                    RouteBadge(provider: manager.activeProviderName)
                    ChatInput(
                        text: $inputText,
                        isStreaming: $isStreaming,
                        onSend: sendMessage
                    )
                }
            }
        }
        .background(Color.dsBackground)
        .onAppear {
            loadSessionMessages()
        }
        .onChange(of: selectedSession) { _, _ in
            loadSessionMessages()
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        saveSessionMessages()
        inputText = ""
        isStreaming = true

        // Route through the real ProviderRouter
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let model = manager.currentModel.isEmpty ? "big-pickle" : manager.currentModel
                var apiMessages: [[String: Any]] = []
                if let prompt = agentSystemPrompt, !prompt.isEmpty {
                    apiMessages.append(["role": "system", "content": prompt])
                }
                for msg in messages where msg.role == .user || msg.role == .assistant {
                    let roleStr = msg.role == .user ? "user" : "assistant"
                    apiMessages.append(["role": roleStr, "content": msg.content])
                }
                let body: [String: Any] = [
                    "model": model,
                    "messages": apiMessages,
                    "max_tokens": 4096,
                    "stream": false,
                ]
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                let response = try await manager.providerRouter.route(
                    method: "POST",
                    path: "/v1/chat/completions",
                    headers: [:],
                    body: bodyData
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

                var finalContent = ""
                var extractedThinking: String? = nil
                var extractedTools: [ToolCallInfo] = []

                if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let delta = first["message"] as? [String: Any] {

                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        extractedThinking = reasoning
                    }

                    if var rawContent = delta["content"] as? String {
                        if rawContent.contains("<think>") {
                            let thinkRegex = try? NSRegularExpression(pattern: #"<think>\s*([\s\S]*?)\s*</think>"#, options: [])
                            while let match = thinkRegex?.firstMatch(in: rawContent, options: [], range: NSRange(location: 0, length: rawContent.utf16.count)),
                                  let thinkRange = Range(match.range(at: 1), in: rawContent),
                                  let fullRange = Range(match.range(at: 0), in: rawContent) {
                                let inline = String(rawContent[thinkRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if extractedThinking == nil && !inline.isEmpty {
                                    extractedThinking = inline
                                }
                                rawContent.removeSubrange(fullRange)
                            }
                            if let startRange = rawContent.range(of: "<think>") {
                                let unclosed = String(rawContent[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if extractedThinking == nil && !unclosed.isEmpty {
                                    extractedThinking = unclosed
                                }
                                rawContent.removeSubrange(startRange.lowerBound..<rawContent.endIndex)
                            }
                        }
                        finalContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            let fn = tc["function"] as? [String: Any]
                            let name = (tc["name"] as? String) ?? (fn?["name"] as? String) ?? "tool"
                            let args = fn?["arguments"] as? String
                            extractedTools.append(ToolCallInfo(name: name, status: .completed, arguments: args))
                        }
                    }
                } else if response.statusCode >= 400 {
                    let errorBody = String(data: response.body, encoding: .utf8) ?? "(empty)"
                    finalContent = "**Error \(response.statusCode)**: \(errorBody)"
                } else {
                    finalContent = String(data: response.body, encoding: .utf8) ?? "(empty response)"
                }

                isStreaming = false
                messages.append(ChatMessage(
                    role: .assistant,
                    content: finalContent.isEmpty ? "(empty response)" : finalContent,
                    thinking: extractedThinking,
                    toolCalls: extractedTools.isEmpty ? nil : extractedTools,
                    routeProvider: manager.activeProviderName
                ))
                saveSessionMessages()
                _ = elapsed
            } catch {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                isStreaming = false
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "**Error**: \(error.localizedDescription)\n\nRoute: \(manager.activeProviderName)\nTime: \(Int(elapsed))ms",
                    routeProvider: manager.activeProviderName
                ))
                saveSessionMessages()
                _ = elapsed
            }
        }
    }
}

// MARK: - Chat Top Bar

struct ChatTopBar: View {
    @Binding var showSessions: Bool
    let sessionTitle: String
    let model: String
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: { showSessions.toggle() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Toggle sessions")
            
            VStack(alignment: .leading, spacing: 1) {
                Text(sessionTitle)
                    .font(.vaultUI(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(model)
                    .font(.vaultMono(size: 10))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            
            Spacer()
            
            // Model selector
            Menu {
                ForEach(["claude-opus-4", "claude-sonnet-4", "claude-haiku-3.5"], id: \.self) { m in
                    Button(m) { }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model)
                        .font(.vaultMono(size: 10))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(Color.dsTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.dsBorder, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Markdown & Code Block Parsing

enum MessageContentPart: Identifiable {
    case text(id: String, content: String)
    case code(id: String, language: String, code: String)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .code(let id, _, _): return id
        }
    }
}

func parseMessageContent(_ raw: String) -> [MessageContentPart] {
    var parts: [MessageContentPart] = []
    let fence = "```"
    var remaining = raw
    var partIndex = 0

    while let startRange = remaining.range(of: fence) {
        let prefix = String(remaining[..<startRange.lowerBound])
        if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(.text(id: "part_\(partIndex)", content: prefix))
            partIndex += 1
        }

        let afterStart = remaining[startRange.upperBound...]
        if let newlineRange = afterStart.range(of: "\n") {
            let language = String(afterStart[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let afterHeader = afterStart[newlineRange.upperBound...]

            if let endRange = afterHeader.range(of: fence) {
                let code = String(afterHeader[..<endRange.lowerBound])
                parts.append(.code(id: "part_\(partIndex)", language: language.isEmpty ? "code" : language, code: code))
                partIndex += 1
                remaining = String(afterHeader[endRange.upperBound...])
            } else {
                parts.append(.code(id: "part_\(partIndex)", language: language.isEmpty ? "code" : language, code: String(afterHeader)))
                partIndex += 1
                remaining = ""
                break
            }
        } else {
            remaining = String(afterStart)
        }
    }

    if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(.text(id: "part_\(partIndex)", content: remaining))
    }

    return parts.isEmpty ? [.text(id: "part_0", content: raw)] : parts
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text(language.lowercased())
                    .font(.vaultMono(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dsTextTertiary)
                Spacer()
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copied" : "Copy")
                            .font(.vaultUI(size: 10))
                    }
                    .foregroundStyle(copied ? Color.dsGreen : Color.dsTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.15))

            Divider().overlay(Color.dsBorder)

            // Code container with horizontal scroll
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.vaultMono(size: 11))
                    .foregroundStyle(Color.dsTextPrimary)
                    .lineSpacing(3)
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.dsBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 4)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - Thinking Disclosure View

struct ThinkingDisclosureView: View {
    let thinking: String
    @State private var isExpanded = false

    var wordCount: Int {
        thinking.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vaultAccent)
                    Text(isExpanded ? "Thinking process" : "Thinking process (\(wordCount) words)")
                        .font(.vaultUI(size: 11, weight: .medium))
                        .foregroundStyle(Color.dsTextSecondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.vaultAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.vaultAccent.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(thinking)
                        .font(.vaultMono(size: 10))
                        .foregroundStyle(Color.dsTextSecondary)
                        .lineSpacing(2)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.dsBorder, lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if message.role == .assistant {
                    Circle()
                        .fill(Color.vaultAccent)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                        )
                }

                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    // Thinking Block if present
                    if let thinking = message.thinking, !thinking.isEmpty {
                        ThinkingDisclosureView(thinking: thinking)
                            .frame(maxWidth: 520)
                    }

                    // Content with code block support
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(parseMessageContent(message.content)) { part in
                            switch part {
                            case .text(_, let text):
                                Text(LocalizedStringKey(text))
                                    .font(.vaultUI(size: 13))
                                    .foregroundStyle(Color.dsTextPrimary)
                                    .textSelection(.enabled)
                            case .code(_, let language, let code):
                                CodeBlockView(language: language, code: code)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user
                            ? Color.vaultAccent.opacity(0.15)
                            : Color.dsSurface,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                message.role == .user
                                    ? Color.vaultAccent.opacity(0.3)
                                    : Color.dsBorder,
                                lineWidth: 1
                            )
                    )

                    // Tool calls
                    if let tools = message.toolCalls {
                        ForEach(tools) { tool in
                            ToolCallChip(tool: tool)
                        }
                    }

                    // Route info
                    if let provider = message.routeProvider {
                        Text("via \(provider)")
                            .font(.vaultMono(size: 9))
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }

                if message.role == .user {
                    Circle()
                        .fill(Color.dsAccent)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                        )
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Tool Call Chip

struct ToolCallChip: View {
    let tool: ToolCallInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                if tool.arguments != nil {
                    withAnimation { isExpanded.toggle() }
                }
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(toolStatusColor)
                        .frame(width: 6, height: 6)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.dsTextTertiary)
                    Text(tool.name)
                        .font(.vaultMono(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dsTextSecondary)
                    if let path = tool.filePath {
                        Text(path)
                            .font(.vaultMono(size: 9))
                            .foregroundStyle(Color.dsTextTertiary)
                            .lineLimit(1)
                    }
                    if tool.arguments != nil {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.dsBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if isExpanded, let args = tool.arguments {
                Text(args)
                    .font(.vaultMono(size: 9))
                    .foregroundStyle(Color.dsTextSecondary)
                    .padding(8)
                    .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
        }
    }

    private var toolStatusColor: Color {
        switch tool.status {
        case .running: return Color.vaultAccent
        case .completed: return .dsGreen
        case .denied: return .dsRed
        }
    }
}

// MARK: - Route Badge

struct RouteBadge: View {
    let provider: String
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.vaultRouteHealthy)
                .frame(width: 5, height: 5)
            Text("served by")
                .font(.vaultMono(size: 9))
                .foregroundStyle(Color.dsTextTertiary)
            Text(provider)
                .font(.vaultMono(size: 9, weight: .semibold))
                .foregroundStyle(Color.vaultAccent)
            Text("· fallback llama.cpp")
                .font(.vaultMono(size: 9))
                .foregroundStyle(Color.dsTextTertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.dsSurface)
    }
}

// MARK: - Chat Input

struct ChatInput: View {
    @Binding var text: String
    @Binding var isStreaming: Bool
    let onSend: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            // Attach
            Button(action: {}) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Attach file")
            
            // Text field
            TextField("Message Claude…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.vaultUI(size: 13))
                .lineLimit(1...5)
                .onSubmit { onSend() }
            
            // Stop or Send
            if isStreaming {
                Button(action: { isStreaming = false }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.dsRed, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(text.isEmpty ? Color.dsTextSecondary : .white)
                        .frame(width: 28, height: 28)
                        .background(
                            text.isEmpty ? Color.dsSurface : Color.vaultAccent,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.dsSurface)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Streaming Indicator

struct StreamingIndicator: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.vaultAccent)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                )
            
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i < dotCount ? Color.vaultAccent : Color.dsTextTertiary)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Binding var selectedSession: String?
    @State private var sessions: [PersistedSession] = []
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.vaultHeader())
                    .foregroundStyle(Color.dsTextSecondary)
                Spacer()
                Button(action: {
                    let session = DataStore.shared.createSession(name: "New Chat")
                    sessions = DataStore.shared.loadSessions()
                    selectedSession = session.id
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            Divider().overlay(Color.dsBorder)
            
            ScrollView {
                VStack(spacing: 2) {
                    SessionRow(title: "New Chat", subtitle: "Just now", isSelected: selectedSession == nil) {
                        selectedSession = nil
                    }
                    ForEach(sessions) { session in
                        SessionRow(
                            title: session.name,
                            subtitle: sessionRelativeDate(session.lastMessageAt ?? session.createdAt),
                            isSelected: selectedSession == session.id
                        ) {
                            selectedSession = session.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .background(Color.dsSurface)
        .onAppear {
            sessions = DataStore.shared.loadSessions()
        }
    }
    
    private func sessionRelativeDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

struct SessionRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.vaultUI(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.dsTextPrimary : Color.dsTextSecondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.vaultUI(size: 10))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.vaultAccent.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }
}
