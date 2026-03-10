import SwiftUI
import LocalAuthentication

class LockManager: ObservableObject {
    @Published var isLocked = false
    @Published var isUnlocking = false
    @Published var showingPasscodeEntry = false
    @Published var passcodeEntry = ""
    @Published var unlockErrorMessage = ""
    @AppStorage("useFaceID") var useFaceID = false

    var lastBackgroundDate: Date?
    private var userID: String = ""

    func configure(userID: String) {
        self.userID = userID
        KeychainService.currentUserID = userID
    }

    // MARK: - Passcode Brute-Force Protection
    private static let maxPasscodeAttempts = 5
    private static let failedAttemptsKey = "passcodeFailedAttempts"

    private var failedAttempts: Int {
        get { UserDefaults.standard.integer(forKey: LockManager.failedAttemptsKey) }
        set { UserDefaults.standard.set(newValue, forKey: LockManager.failedAttemptsKey) }
    }

    private func recordFailedAttempt() {
        failedAttempts += 1
        if failedAttempts >= LockManager.maxPasscodeAttempts {
            lockoutUser()
        }
    }

    private func resetFailedAttempts() {
        failedAttempts = 0
    }

    /// Called after too many wrong passcodes: wipes the passcode and signs the user out.
    /// The user must re-authenticate via Firebase to regain access.
    private func lockoutUser() {
        _ = KeychainService.deletePasscode()
        UserDefaults.standard.set(false, forKey: "useFaceID")
        AuthService.shared.signOut()
        isLocked = false
        showingPasscodeEntry = false
        passcodeEntry = ""
        unlockErrorMessage = "Too many incorrect attempts. The app has been locked and you must sign in again."
        failedAttempts = 0
    }

    var requiresUnlock: Bool {
        useFaceID || KeychainService.passcodeExists()
    }

    func lockIfNeeded(force: Bool) {
        guard requiresUnlock else {
            isLocked = false
            return
        }

        let wasAlreadyLocked = isLocked

        if force {
            isLocked = true
        } else if let lastBackgroundDate {
            let interval = Date().timeIntervalSince(lastBackgroundDate)
            if interval >= 300 {
                isLocked = true
            }
        }

        // Only trigger the unlock prompt when transitioning unlocked → locked,
        // not on repeated calls while already locked (prevents double Face ID).
        guard isLocked && !wasAlreadyLocked else { return }
        unlockErrorMessage = ""
        passcodeEntry = ""
        showingPasscodeEntry = !useFaceID && KeychainService.passcodeExists()
        if useFaceID {
            attemptFaceIDUnlock()
        }
    }

    func attemptFaceIDUnlock() {
        guard useFaceID, !isUnlocking else { return }
        isUnlocking = true
        unlockErrorMessage = ""

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .faceID else {
            isUnlocking = false
            unlockErrorMessage = error?.localizedDescription ?? "Face ID is not available."
            showingPasscodeEntry = KeychainService.passcodeExists()
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Insight.") { success, authError in
            DispatchQueue.main.async {
                self.isUnlocking = false
                if success {
                    self.lastBackgroundDate = nil
                    self.isLocked = false
                    self.unlockErrorMessage = ""
                    self.passcodeEntry = ""
                } else {
                    self.unlockErrorMessage = authError?.localizedDescription ?? "Face ID failed. Try again or use passcode."
                    self.showingPasscodeEntry = KeychainService.passcodeExists()
                }
            }
        }
    }

    func validatePasscode() {
        guard KeychainService.passcodeExists() else {
            unlockErrorMessage = "No passcode set."
            passcodeEntry = ""
            return
        }
        if KeychainService.verifyPasscode(passcodeEntry) {
            resetFailedAttempts()
            lastBackgroundDate = nil
            isLocked = false
            unlockErrorMessage = ""
            passcodeEntry = ""
        } else {
            recordFailedAttempt()
            let remaining = LockManager.maxPasscodeAttempts - failedAttempts
            if remaining > 0 {
                unlockErrorMessage = "Incorrect passcode. \(remaining) attempt\(remaining == 1 ? "" : "s") remaining."
            }
            passcodeEntry = ""
        }
    }
}
