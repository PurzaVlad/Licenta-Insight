import SwiftUI

@available(iOS 18.0, *)
struct ToolsView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Organize")
                        ToolRow(icon: "rectangle.portrait.on.rectangle.portrait.fill", title: "Merge PDF")
                        ToolRow(icon: "rectangle.split.2x1.fill", title: "Split PDF")
                        ToolRow(icon: "line.3.horizontal.decrease", title: "Arrange PDF")

                        SectionHeader(title: "Modify")
                        ToolRow(icon: "rectangle.portrait.rotate", title: "Rotate PDF")
                        ToolRow(icon: "arrow.down.right.and.arrow.up.left", title: "Compress PDF")
                        ToolRow(icon: "pencil", title: "Edit PDF")

                        SectionHeader(title: "Protect & Sign")
                        ToolRow(icon: "signature", title: "Sign PDF")
                        ToolRow(icon: "lock.fill", title: "Protect PDF")
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .padding(.horizontal, 16)

                    Spacer()
                }
                .padding(.top, 8)
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Settings") { }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

struct ToolRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color("Primary"))
                .frame(width: 24)

            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("Primary"))
        }
        .padding(.vertical, 6)
        Divider()
        
    }
}

#Preview {
    if #available(iOS 18.0, *) {
        ContentView()
    } else {
        Text("Requires iOS 18+")
    }
}
