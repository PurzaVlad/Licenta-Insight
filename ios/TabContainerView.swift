import SwiftUI
import UIKit
import LocalAuthentication

extension NSNotification.Name {
    static let globalOperationLoading = NSNotification.Name("GlobalOperationLoading")
}

enum GlobalLoadingBridge {
    static func setOperationLoading(_ isActive: Bool) {
        NotificationCenter.default.post(
            name: .globalOperationLoading,
            object: nil,
            userInfo: ["isActive": isActive]
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

// ViewModifier for navigation bar transparency with iOS 15 compatibility
struct NavBarBlurModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.none, for: .navigationBar)
        } else {
            content
        }
    }
}

// ViewModifier for tab bar transparency with iOS 15 compatibility
struct TabBarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}

// ViewModifier for hiding scroll content background with iOS 15 compatibility
struct HideScrollBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

extension View {
    func hideScrollBackground() -> some View {
        self.modifier(HideScrollBackgroundModifier())
    }
}

struct TabContainerView: View {
    // Tab bar and navigation bar appearance is configured in AppDelegate

    @StateObject private var documentManager = DocumentManager()
    @State private var summaryRequestsInFlight: Set<UUID> = []
    @State private var summaryQueue: [SummaryJob] = []
    @State private var isSummarizing = false
    @State private var currentSummaryDocId: UUID? = nil
    @State private var canceledSummaryIds: Set<UUID> = []
    @State private var selectedTab: AppTab = .documents
    @State private var lastNonSearchTab: AppTab = .documents
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage("modelReady") private var modelReady = false
    @AppStorage("useFaceID") private var useFaceID = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLocked = false
    @State private var isUnlocking = false
    @State private var showingPasscodeEntry = false
    @State private var passcodeEntry = ""
    @State private var unlockErrorMessage = ""
    @State private var lastBackgroundDate: Date?
    @State private var previewItem: PreviewItem?
    @State private var summaryDocument: Document?
    @AppStorage("pendingToolsDeepLink") private var pendingToolsDeepLink = ""
    @AppStorage("pendingConvertDeepLink") private var pendingConvertDeepLink = ""
    @AppStorage("hasShownInitialStartupLoading") private var hasShownInitialStartupLoading = false
    @State private var didStartInitialBootstrap = false
    @State private var isInitialStartupLoading = false
    @State private var isInitialStartupLoadingVisible = false
    @State private var operationLoadingCount = 0
    @State private var isOperationLoadingVisible = false
    @State private var operationLoadingVisibilityToken: Int = 0

    private struct SummaryJob: Equatable {
        let documentId: UUID
        let prompt: String
    }
    
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

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            tabRoot
        .fullScreenCover(item: $previewItem) { item in
            let shouldShowSummary = item.document.type != .image
            DocumentPreviewContainerView(
                url: item.url,
                document: item.document,
                onAISummary: shouldShowSummary ? {
                    previewItem = nil
                    summaryDocument = item.document
                } : nil
            )
        }
        .sheet(item: $summaryDocument) { document in
            DocumentSummaryView(document: document)
                .environmentObject(documentManager)
        }

            if isLocked {
                lockOverlay
            }

            if isOperationLoadingVisible && !isInitialStartupLoadingVisible {
                LoadingScreenView2()
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
            startInitialBootstrapIfNeeded()
            applyUserInterfaceStyle()
            for doc in documentManager.documents
            where isSummaryPlaceholder(doc.summary) && shouldAutoSummarize(doc) {
                documentManager.generateSummary(for: doc)
            }
            if modelReady {
                generateMissingTagsIfNeeded()
            }
            lockIfNeeded(force: true)
        }
        .onChange(of: modelReady) { ready in
            if ready {
                generateMissingTagsIfNeeded()
            }
        }
        .onChange(of: appThemeRaw) { _ in
            applyUserInterfaceStyle()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                lastBackgroundDate = Date()
            } else if phase == .active {
                lockIfNeeded(force: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CancelDocumentSummary"))) { notification in
            guard let idString = notification.userInfo?["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }

            // Remove from queue if it hasn't started.
            if let idx = summaryQueue.firstIndex(where: { $0.documentId == docId }) {
                summaryQueue.remove(at: idx)
            }

            // Mark in-flight summaries as canceled so results are ignored.
            if currentSummaryDocId == docId {
                canceledSummaryIds.insert(docId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GenerateDocumentSummary"))) { notification in
            guard let userInfo = notification.userInfo,
                  let idString = userInfo["documentId"] as? String,
                  let prompt = userInfo["prompt"] as? String,
                  let docId = UUID(uuidString: idString) else {
                return
            }
            let force = (userInfo["force"] as? Bool) ?? false

            // Skip if we already generated (or are generating) a summary.
            if !force && summaryRequestsInFlight.contains(docId) {
                return
            }
            if !force, let doc = documentManager.getDocument(by: docId),
               (!isSummaryPlaceholder(doc.summary) || !shouldAutoSummarize(doc)) {
                return
            }

            // Ensure we re-queue for regenerate.
            summaryQueue.removeAll { $0.documentId == docId }
            let job = SummaryJob(documentId: docId, prompt: prompt)
            summaryQueue.append(job)
            processNextSummaryIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .globalOperationLoading)) { notification in
            guard let isActive = notification.userInfo?["isActive"] as? Bool else { return }
            if isActive {
                operationLoadingCount += 1
            } else {
                operationLoadingCount = max(0, operationLoadingCount - 1)
            }
            updateOperationLoadingVisibility()
        }
    }

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

    private func isSummaryPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary..."
    }

    private func shouldAutoSummarize(_ doc: Document) -> Bool {
        if doc.type == .zip { return false }
        if let sourceId = doc.sourceDocumentId,
           documentManager.getDocument(by: sourceId) != nil {
            return false
        }
        return true
    }

    private func processNextSummaryIfNeeded() {
        guard !isSummarizing else { return }
        guard let next = summaryQueue.first else { return }
        guard let doc = documentManager.getDocument(by: next.documentId),
              isSummaryPlaceholder(doc.summary),
              shouldAutoSummarize(doc) else {
            summaryQueue.removeFirst()
            processNextSummaryIfNeeded()
            return
        }

        isSummarizing = true
        currentSummaryDocId = next.documentId
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": true, "documentId": next.documentId.uuidString]
        )
        summaryRequestsInFlight.insert(next.documentId)

        EdgeAI.shared?.generate(next.prompt, resolver: { result in
            DispatchQueue.main.async {
                self.summaryRequestsInFlight.remove(next.documentId)
                if !self.canceledSummaryIds.contains(next.documentId),
                   let summary = result as? String, !summary.isEmpty {
                    self.documentManager.updateSummary(for: next.documentId, to: summary)
                }
                self.finishSummary(for: next.documentId)
            }
        }, rejecter: { _, _, _ in
            DispatchQueue.main.async {
                self.summaryRequestsInFlight.remove(next.documentId)
                self.finishSummary(for: next.documentId)
            }
        })
    }

    private func generateMissingTagsIfNeeded() {
        for doc in documentManager.documents {
            if !doc.tags.isEmpty { continue }
            if !shouldAutoTag(doc) { continue }
            documentManager.generateTags(for: doc)
        }
    }

    private func shouldAutoTag(_ doc: Document) -> Bool {
        if let sourceId = doc.sourceDocumentId,
           documentManager.getDocument(by: sourceId) != nil {
            return false
        }
        if doc.type == .zip {
            return false
        }
        return true
    }

    private func finishSummary(for documentId: UUID) {
        canceledSummaryIds.remove(documentId)

        if let idx = summaryQueue.firstIndex(where: { $0.documentId == documentId }) {
            summaryQueue.remove(at: idx)
        } else if !summaryQueue.isEmpty {
            summaryQueue.removeFirst()
        }

        isSummarizing = false
        currentSummaryDocId = nil
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": false, "documentId": documentId.uuidString]
        )
        processNextSummaryIfNeeded()
    }

    private var lockOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Unlock VaultAI")
                    .font(.headline)

                if !unlockErrorMessage.isEmpty {
                    Text(unlockErrorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if showingPasscodeEntry {
                    SecureField("Enter 6-digit passcode", text: $passcodeEntry)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .onChange(of: passcodeEntry) { newValue in
                            let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                            if filtered != newValue {
                                passcodeEntry = filtered
                            }
                            if passcodeEntry.count == 6 {
                                validatePasscode()
                            }
                        }
                        .frame(maxWidth: 220)
                }

                HStack(spacing: 12) {
                    if useFaceID {
                        Button(isUnlocking ? "Checking..." : "Use Face ID") {
                            attemptFaceIDUnlock()
                        }
                        .disabled(isUnlocking)
                    }

                    if KeychainService.passcodeExists() {
                        Button(showingPasscodeEntry ? "Hide Passcode" : "Use Passcode") {
                            showingPasscodeEntry.toggle()
                            unlockErrorMessage = ""
                            passcodeEntry = ""
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func lockIfNeeded(force: Bool) {
        guard requiresUnlock else {
            isLocked = false
            return
        }

        if force {
            isLocked = true
        } else if let lastBackgroundDate {
            let interval = Date().timeIntervalSince(lastBackgroundDate)
            if interval >= 300 {
                isLocked = true
            }
        }

        if isLocked {
            unlockErrorMessage = ""
            passcodeEntry = ""
            showingPasscodeEntry = !useFaceID && KeychainService.passcodeExists()
            if useFaceID {
                attemptFaceIDUnlock()
            }
        }
    }

    private var requiresUnlock: Bool {
        useFaceID || KeychainService.passcodeExists()
    }

    private func attemptFaceIDUnlock() {
        guard useFaceID else { return }
        isUnlocking = true
        unlockErrorMessage = ""

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .faceID else {
            isUnlocking = false
            unlockErrorMessage = error?.localizedDescription ?? "Face ID is not available."
            showingPasscodeEntry = KeychainService.passcodeExists()
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock VaultAI.") { success, authError in
            DispatchQueue.main.async {
                self.isUnlocking = false
                if success {
                    self.isLocked = false
                    self.unlockErrorMessage = ""
                    self.passcodeEntry = ""
                } else {
                    self.unlockErrorMessage = authError?.localizedDescription ?? "Face ID failed. Try again or use passcode."
                    self.showingPasscodeEntry = KeychainService.passcodeExists()
                }
            }
        }
    }

    private func validatePasscode() {
        guard let stored = KeychainService.getPasscode() else {
            unlockErrorMessage = "No passcode set."
            passcodeEntry = ""
            return
        }
        if passcodeEntry == stored {
            isLocked = false
            unlockErrorMessage = ""
            passcodeEntry = ""
        } else {
            unlockErrorMessage = "Incorrect passcode."
            passcodeEntry = ""
        }
    }

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

    private func startInitialBootstrapIfNeeded() {
        guard !didStartInitialBootstrap else { return }
        didStartInitialBootstrap = true
        guard !hasShownInitialStartupLoading else { return }

        isInitialStartupLoading = true
        scheduleInitialStartupLoadingVisibility()
        Task {
            async let bootstrap: Void = performInitialBootstrap()
            _ = await bootstrap

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    isInitialStartupLoading = false
                    isInitialStartupLoadingVisible = false
                }
                hasShownInitialStartupLoading = true
            }
        }
    }

    private func updateOperationLoadingVisibility() {
        operationLoadingVisibilityToken += 1
        let token = operationLoadingVisibilityToken

        if operationLoadingCount <= 0 {
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

    private func scheduleInitialStartupLoadingVisibility() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                guard isInitialStartupLoading else { return }
                withAnimation(.easeIn(duration: 0.15)) {
                    isInitialStartupLoadingVisible = true
                }
            }
        }
    }

    private func performInitialBootstrap() async {
        // Give the app one async cycle to finish attaching root views/state restoration.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

struct LoadingScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var circleOffset: CGFloat = 16.3

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()

            Image("LogoComplet")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .accessibilityLabel("LogoComplet")
                .overlay {
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
        .onAppear {
            Task {
                while !Task.isCancelled {
                    circleOffset = 16.3
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = -16.3
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = 16.3
                    }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
        }
    }
}

struct LoadingScreenView2: View {
    @State private var circleOffset: CGFloat = 16.3

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
        .onAppear {
            Task {
                while !Task.isCancelled {
                    circleOffset = 16.3
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = -16.3
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = 16.3
                    }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
        }
    }
}
