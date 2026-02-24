import SwiftUI

struct ConversationHistorySheet: View {
    let conversations: [PersistedConversation]
    let onSelect: (PersistedConversation) -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private var sorted: [PersistedConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sorted.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.counterclockwise")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No past conversations")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Start a conversation in the Chat tab and it will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sorted) { conversation in
                            Button {
                                onSelect(conversation)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                    Text(relativeDate(conversation.updatedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDelete(conversation.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
