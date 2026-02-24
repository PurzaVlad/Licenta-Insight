import Foundation
import OSLog
import CryptoKit

private let retrievalLog = Logger(subsystem: "com.purzavlad.insight", category: "retrieval")

// Simplified types for logging (to avoid circular dependencies)
struct ChunkHitLog {
    let documentId: UUID
    let chunkId: UUID
    let finalScore: Double
    let bm25Score: Double
    let exactMatchScore: Double
    let recencyScore: Double
    let chunkText: String
    let pageNumber: Int?
}

struct RetrievalLog: Codable {
    let timestamp: Date
    let queryHash: String
    let topChunks: [ChunkLog]
    let selectedDocumentIds: [String]
    let primaryDocumentId: String?
    let avgScore: Double
    let maxScore: Double
    
    struct ChunkLog: Codable {
        let rank: Int
        let documentId: String
        let chunkId: String
        let score: Double
        let bm25Score: Double
        let exactMatchScore: Double
        let recencyScore: Double
        let textHash: String
        let pageNumber: Int?
    }
}

class RetrievalLogger {
    static let shared = RetrievalLogger()
    private let logFileURL: URL
    private let isEnabledKey = "debug_retrieval_logging_enabled"
    private let retentionDays = AppConstants.Security.retrievalLogRetentionDays
    private let maxBytes = AppConstants.Security.retrievalLogMaxBytes
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("retrieval_logs.jsonl")
        ensureLogFileAttributes()
        purgeExpiredAndOversizedLogs()
    }

    private var isEnabled: Bool {
#if DEBUG
        return UserDefaults.standard.bool(forKey: isEnabledKey)
#else
        return false
#endif
    }
    
    func log(
        question: String,
        hits: [ChunkHitLog],
        selectedDocIds: [UUID],
        primaryDocId: UUID?
    ) {
        guard isEnabled else { return }
        purgeExpiredAndOversizedLogs()

        let topChunks = hits.prefix(10).enumerated().map { idx, hit in
            RetrievalLog.ChunkLog(
                rank: idx + 1,
                documentId: hit.documentId.uuidString,
                chunkId: hit.chunkId.uuidString,
                score: hit.finalScore,
                bm25Score: hit.bm25Score,
                exactMatchScore: hit.exactMatchScore,
                recencyScore: hit.recencyScore,
                textHash: Self.sha256Hex(String(hit.chunkText.prefix(500))),
                pageNumber: hit.pageNumber
            )
        }
        
        let scores = hits.map { $0.finalScore }
        
        let log = RetrievalLog(
            timestamp: Date(),
            queryHash: Self.sha256Hex(question),
            topChunks: topChunks,
            selectedDocumentIds: selectedDocIds.map(\.uuidString),
            primaryDocumentId: primaryDocId?.uuidString,
            avgScore: scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count),
            maxScore: scores.first ?? 0
        )
        
        do {
            let data = try JSONEncoder().encode(log)
            if let json = String(data: data, encoding: .utf8) {
                try (json + "\n").appendToFile(at: logFileURL)
            }
            ensureLogFileAttributes()
            purgeExpiredAndOversizedLogs()
        } catch {
            retrievalLog.error("Failed to encode or write retrieval log: \(error.localizedDescription)")
        }
    }
    
    func exportLogs() -> URL? {
        FileManager.default.fileExists(atPath: logFileURL.path) ? logFileURL : nil
    }
    
    func clearLogs() {
        do {
            try FileManager.default.removeItem(at: logFileURL)
        } catch {
            retrievalLog.warning("Failed to clear retrieval logs: \(error.localizedDescription)")
        }
    }

    func removeEntries(referencing documentId: UUID) {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }

        let idString = documentId.uuidString
        let filtered = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return true
                }
                return !Self.logReferencesDocument(obj: obj, documentId: idString)
            }
            .joined(separator: "\n")

        do {
            let rewritten = filtered.isEmpty ? "" : filtered + "\n"
            try rewritten.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            retrievalLog.warning("Failed to remove referenced retrieval logs: \(error.localizedDescription)")
        }
    }

    private func purgeExpiredAndOversizedLogs() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        var kept = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> (line: String, date: Date)? in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                let date: Date?
                if let ts = obj["timestamp"] as? TimeInterval {
                    date = Date(timeIntervalSinceReferenceDate: ts)
                } else if let ts = obj["timestamp"] as? String {
                    date = ISO8601DateFormatter().date(from: ts)
                } else {
                    date = nil
                }
                guard let date, date >= cutoff else { return nil }
                return (String(line), date)
            }

        var serialized = kept.map(\.line).joined(separator: "\n")
        var serializedData = Data(serialized.utf8)
        if serializedData.count > maxBytes {
            kept.sort(by: { $0.date > $1.date })
            var pruned: [String] = []
            var running = 0
            for entry in kept {
                let candidateSize = entry.line.utf8.count + 1
                if running + candidateSize > maxBytes { continue }
                pruned.append(entry.line)
                running += candidateSize
            }
            serialized = pruned.joined(separator: "\n")
            serializedData = Data(serialized.utf8)
            _ = serializedData
        }

        do {
            let rewritten = serialized.isEmpty ? "" : serialized + "\n"
            try rewritten.write(to: logFileURL, atomically: true, encoding: .utf8)
            ensureLogFileAttributes()
        } catch {
            retrievalLog.warning("Failed to purge expired retrieval logs: \(error.localizedDescription)")
        }
    }

    private func ensureLogFileAttributes() {
        try? (logFileURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        try? (logFileURL as NSURL).setResourceValue(FileProtectionType.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func logReferencesDocument(obj: [String: Any], documentId: String) -> Bool {
        if let selectedIds = obj["selectedDocumentIds"] as? [String], selectedIds.contains(documentId) {
            return true
        }
        if let primaryId = obj["primaryDocumentId"] as? String, primaryId == documentId {
            return true
        }
        if let chunks = obj["topChunks"] as? [[String: Any]] {
            for chunk in chunks {
                if let chunkDocId = chunk["documentId"] as? String, chunkDocId == documentId {
                    return true
                }
            }
        }
        return false
    }
}

extension String {
    func appendToFile(at url: URL) throws {
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(self.utf8))
            handle.closeFile()
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
