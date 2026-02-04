import SwiftUI

/// iOS 18+ (uses the new `Tab {}` API)
@available(iOS 18.0, *)
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Documents", systemImage: "folder") {
                NavigationStack {
                    DocumentsView()
                }
            }

            Tab("Chat", systemImage: "bubble.left") {
                NavigationStack {
                    ChatView()
                }
            }

            Tab("Tools", systemImage: "wand.and.stars") {
                NavigationStack {
                    ToolsView()
                }
            }

            Tab("Convert", systemImage: "arrow.triangle.2.circlepath") {
                NavigationStack {
                    ConvertView()
                }
            }

            // Special floating Search tab (liquid glass, native)
            Tab(role: .search) {
                NavigationStack {
                    SearchView()
                }
            }
        }
        .tint(Color("Primary"))
    }
}

#Preview {
    if #available(iOS 18.0, *) {
        ContentView()
    } else {
        Text("Requires iOS 18+ (Tab API)")
    }
}
