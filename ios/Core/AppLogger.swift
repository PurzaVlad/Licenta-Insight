import OSLog

enum AppLogger {
    static let persistence = Logger(subsystem: "com.purzavlad.identity", category: "persistence")
    static let fileStorage = Logger(subsystem: "com.purzavlad.identity", category: "fileStorage")
    static let fileProcessing = Logger(subsystem: "com.purzavlad.identity", category: "fileProcessing")
    static let documents = Logger(subsystem: "com.purzavlad.identity", category: "documents")
    static let ui = Logger(subsystem: "com.purzavlad.identity", category: "ui")
    static let ai = Logger(subsystem: "com.purzavlad.identity", category: "ai")
    static let sharing = Logger(subsystem: "com.purzavlad.identity", category: "sharing")
    static let conversion = Logger(subsystem: "com.purzavlad.identity", category: "conversion")
    static let general = Logger(subsystem: "com.purzavlad.identity", category: "general")
}
