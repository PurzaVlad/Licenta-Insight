import SwiftUI
import LocalAuthentication

struct BiometricSetupView: View {
    var onComplete: () -> Void

    @EnvironmentObject private var lockManager: LockManager

    @State private var faceIDEnabled = false
    @State private var faceIDError = ""
    @State private var passcodeDone = false
    @State private var showPasscodeSheet = false

    private var deviceSupportsFaceID: Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            && ctx.biometryType == .faceID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Add an extra layer of security to your documents. You can change these in Settings at any time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // MARK: Options
                    VStack(spacing: 0) {
                        if deviceSupportsFaceID {
                            SecurityOptionRow(
                                icon: "faceid",
                                title: "Face ID",
                                subtitle: faceIDEnabled ? "Enabled" : "Unlock with your face",
                                isEnabled: faceIDEnabled,
                                errorMessage: faceIDError.isEmpty ? nil : faceIDError,
                                action: toggleFaceID
                            )
                            Divider().padding(.leading, 58)
                        }

                        SecurityOptionRow(
                            icon: "lock.fill",
                            title: "Passcode",
                            subtitle: passcodeDone ? "Set" : "Set a 6-digit passcode",
                            isEnabled: passcodeDone,
                            errorMessage: nil,
                            action: { showPasscodeSheet = true }
                        )
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // MARK: Actions
                    VStack(spacing: 14) {
                        Button {
                            onComplete()
                        } label: {
                            Text("Continue")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("Skip for now") {
                            onComplete()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Security")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showPasscodeSheet) {
            PasscodeSetupSheet(onComplete: {
                passcodeDone = true
                showPasscodeSheet = false
            }, onCancel: {
                showPasscodeSheet = false
            })
        }
    }

    private func toggleFaceID() {
        if faceIDEnabled {
            lockManager.useFaceID = false
            faceIDEnabled = false
            faceIDError = ""
            return
        }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            faceIDError = err?.localizedDescription ?? "Face ID unavailable."
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Enable Face ID for Insight.") { success, authErr in
            DispatchQueue.main.async {
                if success {
                    self.lockManager.useFaceID = true
                    self.faceIDEnabled = true
                    self.faceIDError = ""
                } else {
                    self.faceIDError = authErr?.localizedDescription ?? "Face ID authentication failed."
                }
            }
        }
    }
}

// MARK: - Option row

private struct SecurityOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let errorMessage: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isEnabled ? Color("Primary") : .secondary)
                    }

                    Spacer()

                    if isEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Passcode setup sheet

private struct PasscodeSetupSheet: View {
    var onComplete: () -> Void
    var onCancel: () -> Void

    @State private var phase = 0          // 0 = enter, 1 = confirm
    @State private var entry = ""
    @State private var firstPasscode = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Text(phase == 0 ? "Enter a 6-digit passcode" : "Confirm your passcode")
                    .font(.headline)

                SecureField("Passcode", text: $entry)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .frame(maxWidth: 160)
                    .id(phase)   // force recreation when phase changes so field clears
                    .onChange(of: entry) { newVal in
                        // Strip non-digits and cap at 6
                        let filtered = String(newVal.filter(\.isNumber).prefix(6))
                        if filtered != entry {
                            entry = filtered
                            return
                        }
                        guard filtered.count == 6 else { return }

                        if phase == 0 {
                            firstPasscode = filtered
                            entry = ""
                            phase = 1
                            error = ""
                        } else {
                            if filtered == firstPasscode {
                                _ = KeychainService.setPasscode(filtered)
                                onComplete()
                            } else {
                                error = "Passcodes don't match. Try again."
                                entry = ""
                            }
                        }
                    }

                if !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(.top, 40)
            .padding(.horizontal)
            .navigationTitle("Set Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
