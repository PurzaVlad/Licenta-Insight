import SwiftUI
import UIKit

extension NSNotification.Name {
    static let globalOperationLoading = NSNotification.Name("GlobalOperationLoading")
    static let globalOperationLoadingSuccess = NSNotification.Name("GlobalOperationLoadingSuccess")
}

enum GlobalLoadingBridge {
    static func setOperationLoading(_ isActive: Bool) {
        NotificationCenter.default.post(
            name: .globalOperationLoading,
            object: nil,
            userInfo: ["isActive": isActive]
        )
    }

    static func showOperationSuccess() {
        NotificationCenter.default.post(
            name: .globalOperationLoadingSuccess,
            object: nil
        )
    }
}

extension View {
    func bindGlobalOperationLoading(_ isActive: Bool) -> some View {
        self
            .onAppear {
                if isActive {
                    GlobalLoadingBridge.setOperationLoading(true)
                }
            }
            .onChange(of: isActive) { active in
                GlobalLoadingBridge.setOperationLoading(active)
            }
            .onDisappear {
                if isActive {
                    GlobalLoadingBridge.setOperationLoading(false)
                }
            }
    }
}

// ViewModifier for navigation bar transparency
struct NavBarBlurModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.none, for: .navigationBar)
    }
}

// ViewModifier for tab bar transparency
struct TabBarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(.hidden, for: .tabBar)
    }
}

// ViewModifier for hiding scroll content background
struct HideScrollBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func hideScrollBackground() -> some View {
        self.modifier(HideScrollBackgroundModifier())
    }

    @ViewBuilder
    func scrollDismissesKeyboardIfAvailable() -> some View {
        scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
    }
}

struct SharedSettingsSheetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.presentationBackground(.regularMaterial)
    }
}

struct TabContainerView: View {
    // Tab bar and navigation bar appearance is configured in AppDelegate

    @StateObject private var documentManager: DocumentManager
    @StateObject private var lockManager: LockManager
    @StateObject private var summaryCoordinator: SummaryCoordinator

    @State private var selectedTab: AppTab = .documents
    @State private var lastNonSearchTab: AppTab = .documents
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage("modelReady") private var modelReady = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewItem: PreviewItem?
    @State private var summaryDocument: Document?
    @AppStorage("pendingToolsDeepLink") private var pendingToolsDeepLink = ""
    @AppStorage("pendingConvertDeepLink") private var pendingConvertDeepLink = ""
    @State private var isInitialStartupLoadingVisible = true
    @State private var hasPassedStartupGate = false
    @State private var startupLoadingReadyPollToken: Int = 0
    @State private var operationLoadingCount = 0
    @State private var isOperationLoadingVisible = false
    @State private var operationLoadingVisibilityToken: Int = 0
    @State private var isOperationLoadingShowingSuccess = false
    @State private var operationLoadingSuccessToken: Int = 0

    private struct PreviewItem: Identifiable {
        let id: UUID
        let url: URL
        let document: Document
    }

    private enum AppTab: Hashable {
        case documents
        case chat
        case tools
        case convert
        case search
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .system
    }

    init() {
        let dm = DocumentManager()
        _documentManager = StateObject(wrappedValue: dm)
        _lockManager = StateObject(wrappedValue: LockManager())
        _summaryCoordinator = StateObject(wrappedValue: SummaryCoordinator(documentManager: dm))
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if !isInitialStartupLoadingVisible {
                tabRoot
                    .fullScreenCover(item: $previewItem) { item in
                        let shouldShowSummary = item.document.type != .image
                        DocumentPreviewContainerView(
                            url: item.url,
                            document: item.document,
                            onAISummary: shouldShowSummary ? {
                                previewItem = nil
                                summaryDocument = item.document
                            } : nil,
                            documentManager: documentManager
                        )
                    }
                    .sheet(item: $summaryDocument) { document in
                        DocumentSummaryView(document: document)
                            .environmentObject(documentManager)
                    }
            }

            if lockManager.isLocked {
                LockOverlayView(lockManager: lockManager)
            }

            if isOperationLoadingVisible && !isInitialStartupLoadingVisible {
                LoadingScreenView2(showsSuccess: isOperationLoadingShowingSuccess)
                    .transition(.opacity)
                    .ignoresSafeArea()
                    .zIndex(5)
            }

            if isInitialStartupLoadingVisible {
                LoadingScreenView()
                    .transition(.opacity)
                    .ignoresSafeArea()
                    .zIndex(10)
            }
        }
        .onAppear {
            documentManager.importSharedInboxIfNeeded()
            let persistedModelReady = UserDefaults.standard.bool(forKey: "modelReady")
            if modelReady != persistedModelReady {
                modelReady = persistedModelReady
            }
            if persistedModelReady {
                finishInitialStartupLoadingIfNeeded()
            } else {
                startInitialStartupLoadingIfNeeded()
            }
            applyUserInterfaceStyle()
            summaryCoordinator.autoSummarizeOnAppear()
            if modelReady {
                summaryCoordinator.generateMissingTagsIfNeeded()
                summaryCoordinator.generateMissingKeywordsIfNeeded()
                lockManager.lockIfNeeded(force: true)
            }
        }
        .onChange(of: modelReady) { ready in
            if ready {
                summaryCoordinator.generateMissingTagsIfNeeded()
                summaryCoordinator.generateMissingKeywordsIfNeeded()
                finishInitialStartupLoadingIfNeeded()
            } else {
                startInitialStartupLoadingIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ModelReadyStatus"))) { notification in
            guard let ready = notification.userInfo?["ready"] as? Bool else { return }
            if modelReady != ready {
                modelReady = ready
            }
            if ready {
                summaryCoordinator.generateMissingTagsIfNeeded()
                summaryCoordinator.generateMissingKeywordsIfNeeded()
                finishInitialStartupLoadingIfNeeded()
            } else {
                startInitialStartupLoadingIfNeeded()
            }
        }
        .onChange(of: appThemeRaw) { _ in
            applyUserInterfaceStyle()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                lockManager.lastBackgroundDate = Date()
            } else if phase == .active {
                documentManager.importSharedInboxIfNeeded()
                guard !isInitialStartupLoadingVisible else { return }
                lockManager.lockIfNeeded(force: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .globalOperationLoading)) { notification in
            guard let isActive = notification.userInfo?["isActive"] as? Bool else { return }
            if isActive {
                isOperationLoadingShowingSuccess = false
                operationLoadingCount += 1
            } else {
                operationLoadingCount = max(0, operationLoadingCount - 1)
            }
            updateOperationLoadingVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .globalOperationLoadingSuccess)) { _ in
            operationLoadingSuccessToken += 1
            let token = operationLoadingSuccessToken

            withAnimation(.easeIn(duration: 0.12)) {
                isOperationLoadingVisible = true
                isOperationLoadingShowingSuccess = true
            }

            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await MainActor.run {
                    guard operationLoadingSuccessToken == token else { return }
                    isOperationLoadingShowingSuccess = false
                    if operationLoadingCount <= 0 {
                        withAnimation(.easeOut(duration: 0.12)) {
                            isOperationLoadingVisible = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab Navigation

    @ViewBuilder
    private var tabRoot: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $selectedTab) {
                    Tab(value: AppTab.documents) {
                        DocumentsView(
                            onOpenPreview: { document, url in
                                previewItem = PreviewItem(id: document.id, url: url, document: document)
                            },
                            onShowSummary: { document in
                                summaryDocument = document
                            }
                        )
                        .environmentObject(documentManager)
                    } label: {
                        Label("Documents", systemImage: "folder")
                    }

                    Tab(value: AppTab.chat) {
                        NativeChatView()
                            .environmentObject(documentManager)
                    } label: {
                        Label("Chat", systemImage: "bubble.left")
                    }

                    Tab(value: AppTab.tools) {
                        ToolsView()
                            .environmentObject(documentManager)
                    } label: {
                        Label("Tools", systemImage: "wand.and.stars")
                    }

                    Tab(value: AppTab.convert) {
                        ConvertView()
                            .environmentObject(documentManager)
                    } label: {
                        Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Tab(value: AppTab.search, role: .search) {
                        SearchView(
                            onOpenPreview: { document, url in
                                previewItem = PreviewItem(id: document.id, url: url, document: document)
                            },
                            onShowSummary: { document in
                                summaryDocument = document
                            },
                            onExit: {
                                selectedTab = lastNonSearchTab
                            },
                            onOpenTools: { toolId in
                                pendingToolsDeepLink = toolId
                                selectedTab = .tools
                            },
                            onOpenConvert: { convertId in
                                pendingConvertDeepLink = convertId
                                selectedTab = .convert
                            }
                        )
                        .environmentObject(documentManager)
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .tint(Color("Primary"))
                .accentColor(Color("Primary"))
                .modifier(TabBarBackgroundModifier())
            } else {
                TabView(selection: $selectedTab) {
                    DocumentsView(
                        onOpenPreview: { document, url in
                            previewItem = PreviewItem(id: document.id, url: url, document: document)
                        },
                        onShowSummary: { document in
                            summaryDocument = document
                        }
                    )
                    .environmentObject(documentManager)
                    .tabItem {
                        Image(systemName: "folder")
                        Text("Documents")
                    }
                    .tag(AppTab.documents)

                    NativeChatView()
                        .environmentObject(documentManager)
                        .tabItem {
                            Image(systemName: "bubble.left")
                            Text("Chat")
                        }
                        .tag(AppTab.chat)

                    ToolsView()
                        .environmentObject(documentManager)
                        .tabItem {
                            Image(systemName: "wand.and.stars")
                            Text("Tools")
                        }
                        .tag(AppTab.tools)

                    ConvertView()
                        .environmentObject(documentManager)
                        .tabItem {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Convert")
                        }
                        .tag(AppTab.convert)

                    SearchView(
                        onOpenPreview: { document, url in
                            previewItem = PreviewItem(id: document.id, url: url, document: document)
                        },
                        onShowSummary: { document in
                            summaryDocument = document
                        },
                        onExit: {
                            selectedTab = lastNonSearchTab
                        },
                        onOpenTools: { toolId in
                            pendingToolsDeepLink = toolId
                            selectedTab = .tools
                        },
                        onOpenConvert: { convertId in
                            pendingConvertDeepLink = convertId
                            selectedTab = .convert
                        }
                    )
                        .environmentObject(documentManager)
                        .tabItem {
                            Image(systemName: "magnifyingglass")
                            Text("Search")
                        }
                        .tag(AppTab.search)
                }
                .tint(Color("Primary"))
                .accentColor(Color("Primary"))
                .modifier(TabBarBackgroundModifier())
            }
        }
        .onChange(of: selectedTab) { newValue in
            if newValue != .search {
                lastNonSearchTab = newValue
            }
        }
    }

    // MARK: - Theme

    private func applyUserInterfaceStyle() {
        let style: UIUserInterfaceStyle
        switch appTheme {
        case .system:
            style = .unspecified
        case .light:
            style = .light
        case .dark:
            style = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    // MARK: - Startup Loading

    private func startInitialStartupLoadingIfNeeded() {
        guard !hasPassedStartupGate else { return }
        if !isInitialStartupLoadingVisible {
            withAnimation(.easeIn(duration: 0.15)) {
                isInitialStartupLoadingVisible = true
            }
        }
        startStartupLoadingReadyPoll()
    }

    private func finishInitialStartupLoadingIfNeeded() {
        hasPassedStartupGate = true
        startupLoadingReadyPollToken += 1
        if isInitialStartupLoadingVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                isInitialStartupLoadingVisible = false
            }
            DispatchQueue.main.async {
                lockManager.lockIfNeeded(force: true)
            }
            return
        }

        lockManager.lockIfNeeded(force: true)
    }

    private func startStartupLoadingReadyPoll() {
        startupLoadingReadyPollToken += 1
        let token = startupLoadingReadyPollToken

        Task {
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    guard startupLoadingReadyPollToken == token else { return }
                    guard !hasPassedStartupGate else { return }
                    guard isInitialStartupLoadingVisible else { return }
                    let persistedModelReady = UserDefaults.standard.bool(forKey: "modelReady")
                    if persistedModelReady {
                        if !modelReady {
                            modelReady = true
                        }
                        finishInitialStartupLoadingIfNeeded()
                    }
                }

                let shouldContinue = await MainActor.run {
                    startupLoadingReadyPollToken == token &&
                    !hasPassedStartupGate &&
                    isInitialStartupLoadingVisible
                }
                if !shouldContinue { break }
            }
        }
    }

    // MARK: - Operation Loading

    private func updateOperationLoadingVisibility() {
        operationLoadingVisibilityToken += 1
        let token = operationLoadingVisibilityToken

        if operationLoadingCount <= 0 {
            if isOperationLoadingShowingSuccess {
                return
            }
            withAnimation(.easeOut(duration: 0.12)) {
                isOperationLoadingVisible = false
            }
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                guard operationLoadingVisibilityToken == token else { return }
                guard operationLoadingCount > 0 else { return }
                withAnimation(.easeIn(duration: 0.15)) {
                    isOperationLoadingVisible = true
                }
            }
        }
    }
}
