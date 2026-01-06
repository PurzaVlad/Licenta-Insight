import Foundation
import React

@objc(EdgeAI)
class EdgeAI: RCTEventEmitter {

    static let shared = EdgeAI()
    static let sharedRequests = EdgeAIRequests()

    override static func requiresMainQueueSetup() -> Bool { true }

    override func supportedEvents() -> [String]! {
        return ["EdgeAIRequest"]
    }

    // SwiftUI calls this:
    @objc func generate(_ prompt: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        let requestId = UUID().uuidString
        EdgeAI.sharedRequests.store(requestId: requestId, resolve: resolve, reject: reject)

        // Emit event to JS:
        sendEvent(withName: "EdgeAIRequest", body: [
            "requestId": requestId,
            "prompt": prompt
        ])
    }

    // JS calls this to respond:
    @objc func resolveRequest(_ requestId: String, text: String) {
        EdgeAI.sharedRequests.resolve(requestId: requestId, text: text)
    }

    @objc func rejectRequest(_ requestId: String, code: String, message: String) {
        EdgeAI.sharedRequests.reject(requestId: requestId, code: code, message: message)
    }
}

final class EdgeAIRequests {
    private var resolvers: [String: RCTPromiseResolveBlock] = [:]
    private var rejecters: [String: RCTPromiseRejectBlock] = [:]
    private let lock = NSLock()

    func store(requestId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        lock.lock(); defer { lock.unlock() }
        resolvers[requestId] = resolve
        rejecters[requestId] = reject
    }

    func resolve(requestId: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        guard let r = resolvers.removeValue(forKey: requestId) else { return }
        _ = rejecters.removeValue(forKey: requestId)
        r(text)
    }

    func reject(requestId: String, code: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let rej = rejecters.removeValue(forKey: requestId) else { return }
        _ = resolvers.removeValue(forKey: requestId)
        rej(code, message, nil)
    }
}
