import Foundation
import React

@objc(EdgeAI)
class EdgeAI: RCTEventEmitter {

    static var shared: EdgeAI?
    static let sharedRequests = EdgeAIRequests()
    
    override init() {
        super.init()
        EdgeAI.shared = self
    }

    override static func requiresMainQueueSetup() -> Bool { true }

    override func supportedEvents() -> [String]! {
        return ["EdgeAIRequest"]
    }

    // SwiftUI calls this:
    @objc func generate(_ prompt: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        print("[EdgeAI] Generate called with prompt length: \(prompt.count)")
        
        if prompt.isEmpty {
            print("[EdgeAI] Error: Empty prompt")
            reject("EMPTY_PROMPT", "Prompt cannot be empty", nil)
            return
        }
        
        let requestId = UUID().uuidString
        print("[EdgeAI] Generated requestId: \(requestId)")
        
        // Use longer timeout for summaries (4 minutes), shorter for chat (1 minute)
        let timeoutSeconds: TimeInterval = prompt.contains("<<<SUMMARY_REQUEST>>>") ? 240 : 60
        
        EdgeAI.sharedRequests.store(requestId: requestId, resolve: resolve, reject: reject, timeoutSeconds: timeoutSeconds)

        // Emit event to JS on main queue to ensure delivery order
        DispatchQueue.main.async { [weak self] in
            print("[EdgeAI] Emitting EdgeAIRequest event")
            self?.sendEvent(withName: "EdgeAIRequest", body: [
                "requestId": requestId,
                "prompt": prompt
            ])
        }
    }

    // JS calls this to respond:
    @objc func resolveRequest(_ requestId: String, text: String) {
        print("[EdgeAI] Resolving request \(requestId) with text length: \(text.count)")
        EdgeAI.sharedRequests.resolve(requestId: requestId, text: text)
    }

    @objc func rejectRequest(_ requestId: String, code: String, message: String) {
        print("[EdgeAI] Rejecting request \(requestId) with code: \(code), message: \(message)")
        EdgeAI.sharedRequests.reject(requestId: requestId, code: code, message: message)
    }
}

final class EdgeAIRequests {
    private var resolvers: [String: RCTPromiseResolveBlock] = [:]
    private var rejecters: [String: RCTPromiseRejectBlock] = [:]
    private var timers: [String: Timer] = [:]
    private let lock = NSLock()

    func store(requestId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock, timeoutSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        print("[EdgeAIRequests] Storing request \(requestId) with timeout \(timeoutSeconds)s")
        resolvers[requestId] = resolve
        rejecters[requestId] = reject

        let timer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            print("[EdgeAIRequests] Request \(requestId) timed out")
            self.lock.lock(); defer { self.lock.unlock() }
            if let _ = self.rejecters.removeValue(forKey: requestId) {
                _ = self.resolvers.removeValue(forKey: requestId)
                self.timers.removeValue(forKey: requestId)
                // Reject due to timeout
                reject("TIMEOUT", "The AI request timed out after \(timeoutSeconds) seconds.", nil)
            }
        }
        timers[requestId] = timer
        print("[EdgeAIRequests] Active requests: \(resolvers.count)")
    }

    func resolve(requestId: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        timers.removeValue(forKey: requestId)?.invalidate()
        guard let r = resolvers.removeValue(forKey: requestId) else { 
            print("[EdgeAIRequests] Warning: No resolver found for request \(requestId)")
            return 
        }
        _ = rejecters.removeValue(forKey: requestId)
        print("[EdgeAIRequests] Resolved request \(requestId). Remaining requests: \(resolvers.count)")
        r(text)
    }

    func reject(requestId: String, code: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        timers.removeValue(forKey: requestId)?.invalidate()
        guard let rej = rejecters.removeValue(forKey: requestId) else { 
            print("[EdgeAIRequests] Warning: No rejecter found for request \(requestId)")
            return 
        }
        _ = resolvers.removeValue(forKey: requestId)
        print("[EdgeAIRequests] Rejected request \(requestId) with \(code): \(message). Remaining requests: \(rejecters.count)")
        rej(code, message, nil)
    }
}
