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

    var requiresUnlock: Bool {
        useFaceID || KeychainService.passcodeExists()
    }

    func lockIfNeeded(force: Bool) {
        guard requiresUnlock else {
            isLocked = false
            return
        }

        if force {
            isLocked = true
        } else if let lastBackgroundDate {
            let interval = Date().timeIntervalSince(lastBackgroundDate)
            if interval >= 300 {
                isLocked = true
            }
        }

        if isLocked {
            unlockErrorMessage = ""
            passcodeEntry = ""
            showingPasscodeEntry = !useFaceID && KeychainService.passcodeExists()
            if useFaceID {
                attemptFaceIDUnlock()
            }
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
            isLocked = false
            unlockErrorMessage = ""
            passcodeEntry = ""
        } else {
            unlockErrorMessage = "Incorrect passcode."
            passcodeEntry = ""
        }
    }
}
