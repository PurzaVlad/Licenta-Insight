import Foundation

enum AppConstants {
    enum Notifications {
        static let modelReadyStatus = NSNotification.Name("ModelReadyStatus")
        static let generateDocumentSummary = NSNotification.Name("GenerateDocumentSummary")
        static let cancelDocumentSummary = NSNotification.Name("CancelDocumentSummary")
        static let summaryGenerationStatus = NSNotification.Name("SummaryGenerationStatus")
        static let globalOperationLoading = NSNotification.Name("GlobalOperationLoading")
        static let globalOperationLoadingSuccess = NSNotification.Name("GlobalOperationLoadingSuccess")
    }

    enum UserDefaultsKeys {
        static let modelReady = "modelReady"
        static let lastAccessedMap = "LastAccessedMap_v1"
        static let appTheme = "appTheme"
        static let useFaceID = "useFaceID"
        static let pendingToolsDeepLink = "pendingToolsDeepLink"
        static let pendingConvertDeepLink = "pendingConvertDeepLink"
        static let passcodeHashMigration = "passcodeHashMigrationComplete"
    }

    enum AppGroup {
        static let identifier = "group.com.purzavlad.identity"
        static let sharedInboxFolder = "ShareInbox"
    }

    enum Limits {
        static let maxOCRChars = 50_000
        static let maxFileSizeBytes = 50_000_000 // 50MB
        static let maxSummaryRetries = 3
        static let maxOCRImageDimension: CGFloat = 2560
        static let ocrChunkSize = 600
        static let ocrChunkOverlap = 60
    }

    enum FileNames {
        static let savedDocuments = "SavedDocuments_v2"
        static let savedDocumentsJSON = "SavedDocuments_v2.json"
    }
}
