import Foundation
import FirebaseAuth
import GoogleSignIn

final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isSignedIn: Bool = false
    @Published var currentUserEmail: String? = nil
    /// True after the first Firebase auth state callback fires (persisted user restored or confirmed absent)
    @Published var authStateLoaded: Bool = false

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    private init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.isSignedIn = user != nil
                self?.currentUserEmail = user?.email
                self?.authStateLoaded = true
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

    func signInWithGoogle(presenting viewController: UIViewController) async throws {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingGoogleToken
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await Auth.auth().signIn(with: credential)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
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
    case missingGoogleToken

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "No user is currently signed in."
        case .missingGoogleToken: return "Google sign-in failed: missing token."
        }
    }
}
