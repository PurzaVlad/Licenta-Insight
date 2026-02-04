import SwiftUI

@available(iOS 18.0, *)
struct SearchView: View {
    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40, weight: .regular))
                Text("Search")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Find documents, chats, tools, and more.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

#Preview {
    if #available(iOS 18.0, *) {
        SearchView()
    } else {
        Text("Requires iOS 18+")
    }
}
