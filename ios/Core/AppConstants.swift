import Foundation
import Security

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
        static let securityProfile = "securityProfile"
        static let lastKeyRotationMajorVersion = "lastKeyRotationMajorVersion"
        static let pendingToolsDeepLink = "pendingToolsDeepLink"
        static let pendingConvertDeepLink = "pendingConvertDeepLink"
        static let passcodeHashMigration = "passcodeHashMigrationComplete"
    }

    enum AppGroup {
        static let identifier = "group.com.purzavlad.insight"
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

    enum Security {
        static let convertedCacheRetentionDays = 14
        static let tempPreviewRetentionHours = 24
        static let convertedCacheMaxBytes = 200 * 1024 * 1024
        static let retrievalLogMaxBytes = 5 * 1024 * 1024
        static let retrievalLogRetentionDays = 7
        static let metadataSizeWarningMB = 8
    }
}

enum SecurityProfile: String, CaseIterable, Identifiable {
    case standard
    case strict

    var id: String { rawValue }

    static var current: SecurityProfile {
        let raw = UserDefaults.standard.string(forKey: AppConstants.UserDefaultsKeys.securityProfile)
        return SecurityProfile(rawValue: raw ?? "") ?? .standard
    }

    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .strict:
            return "Strict"
        }
    }

    var metadataWriteOptions: Data.WritingOptions {
        switch self {
        case .standard:
            return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        case .strict:
            return [.atomic, .completeFileProtection]
        }
    }

    var metadataFileProtection: FileProtectionType {
        switch self {
        case .standard:
            return .completeUntilFirstUserAuthentication
        case .strict:
            return .complete
        }
    }

    var keychainAccessibility: CFString {
        switch self {
        case .standard:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .strict:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}
