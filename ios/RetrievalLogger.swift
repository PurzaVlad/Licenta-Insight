import Foundation
import OSLog

private let retrievalLog = Logger(subsystem: "com.purzavlad.identity", category: "retrieval")

// Simplified types for logging (to avoid circular dependencies)
struct ChunkHitLog {
    let documentTitle: String
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
    let question: String
    let queryType: String
    let topChunks: [ChunkLog]
    let selectedDocuments: [String]
    let primaryDocument: String?
    let avgScore: Double
    let maxScore: Double
    
    struct ChunkLog: Codable {
        let rank: Int
        let documentTitle: String
        let chunkId: String
        let score: Double
        let bm25Score: Double
        let exactMatchScore: Double
        let recencyScore: Double
        let text: String
        let pageNumber: Int?
    }
}

class RetrievalLogger {
    static let shared = RetrievalLogger()
    private let logFileURL: URL
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("retrieval_logs.jsonl")
    }
    
    func log(
        question: String,
        queryType: String,
        hits: [ChunkHitLog],
        selectedDocs: [String],
        primaryDoc: String?
    ) {
        let topChunks = hits.prefix(10).enumerated().map { idx, hit in
            RetrievalLog.ChunkLog(
                rank: idx + 1,
                documentTitle: hit.documentTitle,
                chunkId: hit.chunkId.uuidString,
                score: hit.finalScore,
                bm25Score: hit.bm25Score,
                exactMatchScore: hit.exactMatchScore,
                recencyScore: hit.recencyScore,
                text: String(hit.chunkText.prefix(200)),
                pageNumber: hit.pageNumber
            )
        }
        
        let scores = hits.map { $0.finalScore }
        
        let log = RetrievalLog(
            timestamp: Date(),
            question: question,
            queryType: queryType,
            topChunks: topChunks,
            selectedDocuments: selectedDocs,
            primaryDocument: primaryDoc,
            avgScore: scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count),
            maxScore: scores.first ?? 0
        )
        
        do {
            let data = try JSONEncoder().encode(log)
            if let json = String(data: data, encoding: .utf8) {
                try (json + "\n").appendToFile(at: logFileURL)
            }
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
