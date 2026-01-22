import SwiftUI
import UIKit
import LocalAuthentication

struct TabContainerView: View {
    @StateObject private var documentManager = DocumentManager()
    @State private var summaryRequestsInFlight: Set<UUID> = []
    @State private var summaryQueue: [SummaryJob] = []
    @State private var isSummarizing = false
    @State private var currentSummaryDocId: UUID? = nil
    @State private var canceledSummaryIds: Set<UUID> = []
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
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

    private struct SummaryJob: Equatable {
        let documentId: UUID
        let prompt: String
    }
    
    private struct PreviewItem: Identifiable {
        let id: UUID
        let url: URL
        let document: Document
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .system
    }

    var body: some View {
        ZStack {
        TabView {
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
                    Image(systemName: "doc.text")
                    Text("Documents")
                }

            NativeChatView()
                .environmentObject(documentManager)
                .tabItem {
                    Image(systemName: "message")
                    Text("Chat")
                }

            PDFEditView()
                .environmentObject(documentManager)
                .tabItem {
                    Image(systemName: "doc.richtext")
                    Text("PDFEdit")
                }

            ConversionView()
                .environmentObject(documentManager)
                .tabItem {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Convert")
                }

            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
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
        }
        .onAppear {
            applyUserInterfaceStyle()
            for doc in documentManager.documents where isSummaryPlaceholder(doc.summary) && doc.type != .zip {
                documentManager.generateSummary(for: doc)
            }
            lockIfNeeded(force: true)
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
               !isSummaryPlaceholder(doc.summary) {
                return
            }

            // Ensure we re-queue for regenerate.
            summaryQueue.removeAll { $0.documentId == docId }
            let job = SummaryJob(documentId: docId, prompt: prompt)
            summaryQueue.append(job)
            processNextSummaryIfNeeded()
        }
    }

    private func isSummaryPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary..."
    }

    private func processNextSummaryIfNeeded() {
        guard !isSummarizing else { return }
        guard let next = summaryQueue.first else { return }
        guard let doc = documentManager.getDocument(by: next.documentId),
              isSummaryPlaceholder(doc.summary) else {
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

}
