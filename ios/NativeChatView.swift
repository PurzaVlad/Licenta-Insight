import SwiftUI
import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "user" or "assistant"
    let text: String
    let date: Date
}

struct NativeChatView: View {
    @State private var input: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating: Bool = false
    @State private var isThinkingPulseOn: Bool = false
    @State private var activeChatGenerationId: UUID? = nil
    @FocusState private var isFocused: Bool

    // Preprompt (edit this text to change assistant behavior)
    private let chatPreprompt = """
    You are a helpful assistant. You have access to all document titles, summaries and ocrs. You can give that information to the user.
    """

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty {
                                Text("Model Ready.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 24)
                            }

                            ForEach(messages) { msg in
                                MessageRow(msg: msg)
                                    .id(msg.id)
                            }

                            if isGenerating {
                                ThinkingRow(isPulseOn: $isThinkingPulseOn)
                                    .id("thinking")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages) { newValue in
                        if let last = newValue.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Message", text: $input)
                                .focused($isFocused)
                                .disabled(isGenerating)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.33)
                        )

                        Button {
                            send()
                        } label: {
                            Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating ? .secondary : .white)
                                .background(
                                    Circle()
                                        .fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating ? Color(.systemFill) : Color.accentColor)
                                )
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" Chat ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func send() {
        if isGenerating {
            stopGeneration()
            return
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        startGeneration(question: trimmed)
    }

    private func stopGeneration() {
        guard isGenerating else { return }
        isGenerating = false
        activeChatGenerationId = nil
        EdgeAI.shared?.cancelCurrentGeneration()
    }

    private func startGeneration(question: String) {
        let generationId = UUID()
        activeChatGenerationId = generationId
        runLLMAnswer(question: question, generationId: generationId)
    }

    private func runLLMAnswer(question: String, generationId: UUID) {
        isGenerating = true

        Task {
            do {
                guard let edgeAI = EdgeAI.shared else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }

                if self.activeChatGenerationId != generationId { return }
                let reply = try await callChatLLM(edgeAI: edgeAI, question: question)
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    let text = reply.isEmpty ? "(No response)" : reply
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                }
            } catch {
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    if error.localizedDescription != "CANCELLED" {
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: \(error.localizedDescription)", date: Date()))
                    }
                }
            }
        }
    }

    private func buildPrompt(for question: String) -> String {
        """
        SYSTEM:
        \(chatPreprompt)

        USER:
        \(question)
        """
    }

    private func callChatLLM(edgeAI: EdgeAI, question: String) async throws -> String {
        let prompt = buildPrompt(for: question)
        return try await callLLM(edgeAI: edgeAI, prompt: wrapChatPrompt(prompt))
    }

    private func wrapChatPrompt(_ prompt: String) -> String {
        "<<<CHAT_BRIEF>>>" + prompt
    }

    private func callLLM(edgeAI: EdgeAI, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            edgeAI.generate("<<<NO_HISTORY>>>" + prompt, resolver: { result in
                continuation.resume(returning: result as? String ?? "")
            }, rejecter: { _, message, _ in
                continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
            })
        }
    }


    private struct ThinkingRow: View {
        @Binding var isPulseOn: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text("Thinking…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .opacity(isPulseOn ? 0.78 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    isPulseOn = true
                }
            }
            .onDisappear {
                isPulseOn = false
            }
        }
    }
}

private struct MessageRow: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.role == "assistant" {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(formatMarkdownText(msg.text))
            .font(.body)
            .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(msg.role == "user" ? Color.accentColor : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(msg.role == "user" ? Color.clear : Color(.separator), lineWidth: msg.role == "user" ? 0 : 0.5)
            )
    }
}
