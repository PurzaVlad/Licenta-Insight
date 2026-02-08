import SwiftUI

@available(iOS 18.0, *)
struct DocumentsView: View {
    @State private var editMode: EditMode = .inactive
    @State private var isGridView = false
    @State private var sortOption: SortOption = .recent
    @State private var selection = Set<DocumentItem.ID>()
    @State private var isLoadingScreenPresented = false
    @State private var isLoadingScreenPresented2 = false
    @State private var items: [DocumentItem] = [
        .init(icon: "folder.fill", iconColor: Color("Primary"), title: "NumeFolder...", date: "28 Jan 2026", type: "PDF...", isFolder: true),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "folder.fill", iconColor: Color("Primary"), title: "NumeFolder...", date: "28 Jan 2026", type: "PDF...", isFolder: true),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false),
        .init(icon: "doc.text", iconColor: .gray, title: "NumeDocument...", date: "28 Jan 2026", type: "PDF...", isFolder: false)
    ]

    var body: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                DocumentRow(
                    icon: item.icon,
                    iconColor: item.iconColor,
                    title: item.title,
                    date: item.date,
                    type: item.type,
                    hasCheckeredBackground: !item.isFolder
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
                .listRowSeparator(.hidden)
                .tag(item.id)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 90)
        }

        // ✅ Apple-standard collapsing title
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.large)
    
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("LoadingInitial") {
                    isLoadingScreenPresented = true
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("LoadingBlur") {
                    isLoadingScreenPresented2 = true
                }
            }
            if editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        editMode = .inactive
                        selection.removeAll()
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Scan Document") { }
                        Button("Import Files") { }
                        Button("New Folder") { }
                        Button("Create Zip") { }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            editMode = editMode.isEditing ? .inactive : .active
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }

                        Button { } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }

                        Divider()

                        Text("View")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            isGridView = false
                        } label: {
                            Label("List", systemImage: "list.bullet")
                        }

                        Button {
                            isGridView = true
                        } label: {
                            Label("Grid", systemImage: "square.grid.2x2")
                        }

                        Divider()

                        Text("Sort")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            sortOption = .name
                        } label: {
                            Label("Name", systemImage: "textformat")
                        }

                        Button {
                            sortOption = .date
                        } label: {
                            Label("Date", systemImage: "calendar")
                        }

                        Button {
                            sortOption = .recent
                        } label: {
                            Label("Recent", systemImage: "clock")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $isLoadingScreenPresented) {
            LoadingScreenView(isPresented: $isLoadingScreenPresented)
        }
        .overlay {
            if isLoadingScreenPresented2 {
                LoadingScreenView2(isPresented2: $isLoadingScreenPresented2)
                    .transition(.opacity)
                    .ignoresSafeArea()
                    .zIndex(1)
            }
        }
    }
}

enum SortOption {
    case name
    case date
    case recent
}

struct DocumentItem: Identifiable, Hashable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let date: String
    let type: String
    let isFolder: Bool
}
struct DocumentRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let date: String
    let type: String
    var hasCheckeredBackground: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    if hasCheckeredBackground {
                        // Checkered pattern background for documents
                        CheckeredPatternView()
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        // Solid color background for folders
                        RoundedRectangle(cornerRadius: 8)
                            .fill(iconColor)
                            .frame(width: 50, height: 50)
                    }

                    Image(systemName: icon)
                        .foregroundColor(hasCheckeredBackground ? .gray : .white)
                        .font(.system(size: 20))
                }

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Text(date)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)

                        Text("•")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)

                        Text(type)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)

            Divider()
            
        }
    }
}

struct CheckeredPatternView: View {
    var body: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 4
            let rows = Int(ceil(size.height / tileSize))
            let cols = Int(ceil(size.width / tileSize))
            
            for row in 0..<rows {
                for col in 0..<cols {
                    let isEven = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * tileSize,
                        y: CGFloat(row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    
                    context.fill(
                        Path(rect),
                        with: .color(isEven ? .gray.opacity(0.3) : .gray.opacity(0.1))
                    )
                }
            }
        }
    }
}

struct LoadingScreenView: View {
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var circleOffset: CGFloat = -60

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    Image("LogoComplet")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .accessibilityLabel("LogoComplet")

                    Rectangle()
                        .fill(.background)
                        .frame(width: 220, height: 220)
                        .mask {
                            Rectangle()
                                .overlay {
                                     Circle()
                                         .frame(width: 64.4, height: 64.4)
                                         .offset(y: circleOffset)
                                         .blendMode(.destinationOut)
                                        }
                        }
                        .compositingGroup()
                    
                    
                }
            }
        }
        .onAppear {
            Task {
                while true {
                    // Stay down for 1 second
                    circleOffset = 16.3

                    // Animate up
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = -16.3
                    }
                    // Stay up for 1 second
                    try? await Task.sleep(nanoseconds:1_500_000_000)

                    // Animate back down
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = 16.3
                    }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Close") {
                isPresented = false
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
    }
}

struct LoadingScreenView2: View {
    @Binding var isPresented2: Bool
    @State private var circleOffset: CGFloat = -60

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.gray.opacity(0.06))
                .ignoresSafeArea()

            Image("LogoComplet")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .mask {
                    Circle()
                        .frame(width: 64.4, height: 64.4)
                        .offset(y: circleOffset)
                }
                .accessibilityLabel("LogoComplet")

            Rectangle()
                .fill(Color.gray.opacity(0.14))
                .ignoresSafeArea()
                .mask {
                    Rectangle()
                        .ignoresSafeArea()
                        .overlay {
                            Circle()
                                .frame(width: 64.4, height: 64.4)
                                .offset(y: circleOffset)
                                .blendMode(.destinationOut)
                        }
                }
                .compositingGroup()
        }
        .background(Color.clear)
        .onAppear {
            Task {
                while true {
                    // Stay down for 1 second
                    circleOffset = 16.3

                    // Animate up
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = -16.3
                    }
                    // Stay up for 1 second
                    try? await Task.sleep(nanoseconds:1_500_000_000)

                    // Animate back down
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = 16.3
                    }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Close") {
                isPresented2 = false
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
    }
}

#Preview {
    if #available(iOS 18.0, *) {
        ContentView()
    } else {
        Text("Requires iOS 18+ (Tab API)")
    }
}
