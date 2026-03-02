import Foundation
import FirebaseAuth

final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isSignedIn: Bool = false
    @Published var currentUserEmail: String? = nil

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    private init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.isSignedIn = user != nil
                self?.currentUserEmail = user?.email
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    var currentUserID: String? {
        Auth.auth().currentUser?.uid
    }

    func signIn(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        try await Auth.auth().createUser(withEmail: email, password: password)
    }

    func signOut() {
        try? Auth.auth().signOut()
    }

    func getIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthServiceError.notSignedIn
        }
        return try await user.getIDToken(forcingRefresh: false)
    }

    /// Synchronous token fetch for use on background threads.
    func currentIDTokenSync() -> String {
        var result = ""
        let semaphore = DispatchSemaphore(value: 0)
        Auth.auth().currentUser?.getIDTokenForcingRefresh(false) { token, _ in
            result = token ?? ""
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }
}

enum AuthServiceError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        "No user is currently signed in."
    }
}
