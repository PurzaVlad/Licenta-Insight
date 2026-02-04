import SwiftUI

@available(iOS 18.0, *)
struct ChatView: View {
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = [
        .init(text: "Hey! How can I help you today?", isUser: false),
        .init(text: "I need to organize my PDFs into folders.", isUser: true),
        .init(text: "Got it. I can suggest a folder structure and naming scheme. Want me to?", isUser: false)
    ]
    private let inputLineHeight: CGFloat = 22
    private let inputMinLines = 1
    private let inputMaxLines = 6
    @State private var inputHeight: CGFloat = 22
    private let inputMaxCornerRadius: CGFloat = 25
    private let inputMinCornerRadius: CGFloat = 12

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            HStack {
                                if message.isUser {
                                    Spacer(minLength: 40)
                                    ChatBubble(text: message.text, isUser: true)
                                } else {
                                    ChatBubble(text: message.text, isUser: false)
                                    Spacer(minLength: 40)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { } label: {
                        Image(systemName: "scope")
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(
                                Circle().stroke(Color(.systemGray4).opacity(0.35), lineWidth: 1)
                            )
                    }

                    HStack(spacing: 4) {
                        AutoGrowingTextView(
                            text: $messageText,
                            height: $inputHeight,
                            minHeight: inputLineHeight * CGFloat(inputMinLines),
                            maxHeight: inputLineHeight * CGFloat(inputMaxLines),
                            font: UIFont.systemFont(ofSize: 17)
                        )
                        .frame(height: inputHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            if messageText.isEmpty {
                                Text("Ask anything")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 17))
                                    .padding(.top, 2)
                            }
                        }

                        if messageText.isEmpty {
                            Button { } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.gray)
                            }
                        } else {
                            Button {
                                let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                messages.append(.init(text: trimmed, isUser: true))
                                messageText = ""
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(Color("Primary"))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: inputCornerRadius, style: .continuous)
                            .fill(Color(.systemGroupedBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: inputCornerRadius, style: .continuous)
                                    .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 1)
                            )
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var inputCornerRadius: CGFloat {
        let lines = max(inputMinLines, min(inputMaxLines, Int(round(inputHeight / inputLineHeight))))
        let t = CGFloat(lines - 1) / CGFloat(max(inputMaxLines - 1, 1))
        return inputMaxCornerRadius - (inputMaxCornerRadius - inputMinCornerRadius) * t
    }
}

struct AutoGrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let font: UIFont

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.font = font
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = font
        recalcHeight(view: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func recalcHeight(view: UITextView) {
        let size = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        let clamped = min(maxHeight, max(minHeight, size.height))
        if height != clamped {
            DispatchQueue.main.async {
                height = clamped
                view.isScrollEnabled = size.height > maxHeight
            }
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        let parent: AutoGrowingTextView

        init(parent: AutoGrowingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.recalcHeight(view: textView)
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct ChatBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 18))
            .foregroundStyle(isUser ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isUser ? Color("Primary") : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isUser ? Color.clear : Color(.systemGray4).opacity(0.35), lineWidth: 1)
            )
    }
}

#Preview {
    if #available(iOS 18.0, *) {
        ContentView()
    } else {
        Text("Requires iOS 18+")
    }
}
