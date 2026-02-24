import OSLog

enum AppLogger {
    static let persistence = Logger(subsystem: "com.purzavlad.insight", category: "persistence")
    static let fileStorage = Logger(subsystem: "com.purzavlad.insight", category: "fileStorage")
    static let fileProcessing = Logger(subsystem: "com.purzavlad.insight", category: "fileProcessing")
    static let documents = Logger(subsystem: "com.purzavlad.insight", category: "documents")
    static let ui = Logger(subsystem: "com.purzavlad.insight", category: "ui")
    static let ai = Logger(subsystem: "com.purzavlad.insight", category: "ai")
    static let sharing = Logger(subsystem: "com.purzavlad.insight", category: "sharing")
    static let conversion = Logger(subsystem: "com.purzavlad.insight", category: "conversion")
    static let general = Logger(subsystem: "com.purzavlad.insight", category: "general")
}
