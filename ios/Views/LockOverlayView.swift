import SwiftUI

struct LockOverlayView: View {
    @ObservedObject var lockManager: LockManager

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Unlock Identity")
                    .font(.headline)

                if !lockManager.unlockErrorMessage.isEmpty {
                    Text(lockManager.unlockErrorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if lockManager.showingPasscodeEntry {
                    SecureField("Enter 6-digit passcode", text: $lockManager.passcodeEntry)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .onChange(of: lockManager.passcodeEntry) { newValue in
                            let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                            if filtered != newValue {
                                lockManager.passcodeEntry = filtered
                            }
                            if lockManager.passcodeEntry.count == 6 {
                                lockManager.validatePasscode()
                            }
                        }
                        .frame(maxWidth: 220)
                }

                HStack(spacing: 12) {
                    if lockManager.useFaceID {
                        Button(lockManager.isUnlocking ? "Checking..." : "Use Face ID") {
                            lockManager.attemptFaceIDUnlock()
                        }
                        .disabled(lockManager.isUnlocking)
                    }

                    if KeychainService.passcodeExists() {
                        Button(lockManager.showingPasscodeEntry ? "Hide Passcode" : "Use Passcode") {
                            lockManager.showingPasscodeEntry.toggle()
                            lockManager.unlockErrorMessage = ""
                            lockManager.passcodeEntry = ""
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
