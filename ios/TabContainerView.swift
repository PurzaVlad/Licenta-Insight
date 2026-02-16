import SwiftUI
import UIKit
import LocalAuthentication

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
    @State private var isInitialStartupLoadingVisible = true
    @State private var hasPassedStartupGate = false
    @State private var startupLoadingReadyPollToken: Int = 0
    @State private var operationLoadingCount = 0
    @State private var isOperationLoadingVisible = false
    @State private var operationLoadingVisibilityToken: Int = 0
    @State private var isOperationLoadingShowingSuccess = false
    @State private var operationLoadingSuccessToken: Int = 0

    private struct SummaryJob: Equatable {
        let documentId: UUID
        let prompt: String
        let force: Bool
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

            if isLocked {
                lockOverlay
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
            for doc in documentManager.documents
            where isSummaryPlaceholder(doc.summary) && shouldAutoSummarize(doc) {
                documentManager.generateSummary(for: doc)
            }
            if modelReady {
                generateMissingTagsIfNeeded()
                lockIfNeeded(force: true)
            }
        }
        .onChange(of: modelReady) { ready in
            if ready {
                generateMissingTagsIfNeeded()
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
                generateMissingTagsIfNeeded()
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
                lastBackgroundDate = Date()
            } else if phase == .active {
                documentManager.importSharedInboxIfNeeded()
                guard !isInitialStartupLoadingVisible else { return }
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
            print("🤖 TabContainer: Received GenerateDocumentSummary for \(docId), force=\(force), promptLength=\(prompt.count)")

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
            let job = SummaryJob(documentId: docId, prompt: prompt, force: force)
            summaryQueue.append(job)
            processNextSummaryIfNeeded()
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
        return trimmed.isEmpty ||
            trimmed == "Processing..." ||
            trimmed == "Processing summary..." ||
            trimmed.contains("Processing summary")
    }

    private func shouldAutoSummarize(_ doc: Document) -> Bool {
        if doc.type == .zip { return false }
        let summaryText = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSummaryPlaceholder(summaryText) {
            return true
        }
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
              (next.force || (isSummaryPlaceholder(doc.summary) && shouldAutoSummarize(doc))) else {
            summaryQueue.removeFirst()
            processNextSummaryIfNeeded()
            return
        }
        print("🤖 TabContainer: Starting summary generation for \(next.documentId), force=\(next.force)")

        isSummarizing = true
        currentSummaryDocId = next.documentId
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": true, "documentId": next.documentId.uuidString]
        )
        summaryRequestsInFlight.insert(next.documentId)

        guard let edgeAI = EdgeAI.shared else {
            summaryRequestsInFlight.remove(next.documentId)
            finishSummary(for: next.documentId)
            return
        }

        edgeAI.generate(next.prompt, resolver: { result in
            DispatchQueue.main.async {
                let raw = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if self.canceledSummaryIds.contains(next.documentId) {
                    self.summaryRequestsInFlight.remove(next.documentId)
                    self.finishSummary(for: next.documentId)
                    return
                }

                if raw.isEmpty {
                    self.summaryRequestsInFlight.remove(next.documentId)
                    self.finishSummary(for: next.documentId)
                    return
                }

                if self.isChattySummaryOutput(raw) {
                    let strictPrompt = self.makeStrictRewritePrompt(from: next.prompt)
                    edgeAI.generate(strictPrompt, resolver: { retryResult in
                        DispatchQueue.main.async {
                            let retryText = (retryResult as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let final = self.cleanedSummaryText(retryText.isEmpty ? raw : retryText)
                            if !self.canceledSummaryIds.contains(next.documentId), !final.isEmpty {
                                self.documentManager.updateSummary(for: next.documentId, to: final)
                            }
                            self.summaryRequestsInFlight.remove(next.documentId)
                            self.finishSummary(for: next.documentId)
                        }
                    }, rejecter: { _, _, _ in
                        DispatchQueue.main.async {
                            let final = self.cleanedSummaryText(raw)
                            if !self.canceledSummaryIds.contains(next.documentId), !final.isEmpty {
                                self.documentManager.updateSummary(for: next.documentId, to: final)
                            }
                            self.summaryRequestsInFlight.remove(next.documentId)
                            self.finishSummary(for: next.documentId)
                        }
                    })
                    return
                }

                let final = self.cleanedSummaryText(raw)
                if !final.isEmpty {
                    self.documentManager.updateSummary(for: next.documentId, to: final)
                }
                self.summaryRequestsInFlight.remove(next.documentId)
                self.finishSummary(for: next.documentId)
            }
        }, rejecter: { _, _, _ in
            DispatchQueue.main.async {
                self.summaryRequestsInFlight.remove(next.documentId)
                self.finishSummary(for: next.documentId)
            }
        })
    }

    private func cleanedSummaryText(_ text: String) -> String {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let bannedPrefixes = [
            "i understand",
            "you've provided",
            "you have provided",
            "if you have any",
            "feel free to ask",
            "i'll do my best to assist",
            "i can help",
            "let me know"
        ]

        lines.removeAll { line in
            let lower = line.lowercased()
            return bannedPrefixes.contains { lower.hasPrefix($0) || lower.contains($0) }
        }

        return lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isChattySummaryOutput(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            "i understand you've provided",
            "i understand you have provided",
            "if you have any particular questions",
            "feel free to ask",
            "i'll do my best to assist",
            "i can help you",
            "what would you like"
        ]
        return patterns.contains { lower.contains($0) }
    }

    private func makeStrictRewritePrompt(from originalPrompt: String) -> String {
        """
        <<<NO_HISTORY>>>
        You are rewriting a failed summary output into a proper document summary.
        Return only summary text, no meta commentary.
        Do not address the user.
        Do not ask questions.
        Do not use phrases like "I understand", "you've provided", or "feel free to ask".
        Use concise natural language paragraphs.

        \(originalPrompt)
        """
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

                Text("Unlock Identity")
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

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Identity.") { success, authError in
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
        guard KeychainService.passcodeExists() else {
            unlockErrorMessage = "No passcode set."
            passcodeEntry = ""
            return
        }
        if KeychainService.verifyPasscode(passcodeEntry) {
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
                lockIfNeeded(force: true)
            }
            return
        }

        lockIfNeeded(force: true)
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
    let showsSuccess: Bool
    @State private var circleOffset: CGFloat = 16.3

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.gray.opacity(0.06))
                .ignoresSafeArea()

            if showsSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(Color("Primary"))
            } else {
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
