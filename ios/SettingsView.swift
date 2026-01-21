import SwiftUI
import LocalAuthentication
import Security

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct SettingsView: View {
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage("useFaceID") private var useFaceID = false
    @State private var isFaceIDAvailable = false
    @State private var faceIDStatusText = ""
    @State private var showingFaceIDError = false
    @State private var faceIDErrorMessage = ""

    @State private var showingPasscodeSheet = false
    @State private var passcodeSet = false
    @State private var passcode = ""
    @State private var confirmPasscode = ""
    @State private var showingPasscodeError = false
    @State private var passcodeErrorMessage = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Theme")) {
                    Picker("Theme", selection: $appThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Unlock Method")) {
                    Toggle(isOn: faceIDToggleBinding) {
                        Text("Face ID")
                    }
                    .disabled(!isFaceIDAvailable)

                    if !isFaceIDAvailable {
                        Text(faceIDStatusText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Passcode")
                        Spacer()
                        Text(passcodeSet ? "Set" : "Not set")
                            .foregroundColor(.secondary)
                    }

                    Button(passcodeSet ? "Change Passcode" : "Set Passcode") {
                        passcode = ""
                        confirmPasscode = ""
                        showingPasscodeSheet = true
                    }

                    if passcodeSet {
                        Button("Remove Passcode", role: .destructive) {
                            if KeychainService.deletePasscode() {
                                passcodeSet = false
                            }
                        }
                    }

                    Text("Passcode is used if Face ID fails.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" Settings ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .onAppear {
            refreshFaceIDAvailability()
            passcodeSet = KeychainService.passcodeExists()
        }
        .alert("Face ID Error", isPresented: $showingFaceIDError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(faceIDErrorMessage)
        }
        .alert("Passcode Error", isPresented: $showingPasscodeError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(passcodeErrorMessage)
        }
        .sheet(isPresented: $showingPasscodeSheet) {
            NavigationView {
                Form {
                    SecureField("New 6-digit passcode", text: $passcode)
                        .keyboardType(.numberPad)
                    SecureField("Confirm passcode", text: $confirmPasscode)
                        .keyboardType(.numberPad)
                }
                .navigationTitle(passcodeSet ? "Change Passcode" : "Set Passcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            savePasscode()
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showingPasscodeSheet = false
                        }
                    }
                }
            }
        }
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .light
    }

    private var faceIDToggleBinding: Binding<Bool> {
        Binding(
            get: { useFaceID },
            set: { newValue in
                if newValue {
                    enableFaceID()
                } else {
                    useFaceID = false
                }
            }
        )
    }

    private func refreshFaceIDAvailability() {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        isFaceIDAvailable = canEvaluate && context.biometryType == .faceID

        if !isFaceIDAvailable {
            useFaceID = false
            if let error = error {
                faceIDStatusText = error.localizedDescription
            } else {
                faceIDStatusText = "Face ID is not available on this device."
            }
        } else {
            faceIDStatusText = ""
        }
    }

    private func enableFaceID() {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .faceID else {
            refreshFaceIDAvailability()
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Enable Face ID to unlock VaultAI.") { success, authError in
            DispatchQueue.main.async {
                if success {
                    useFaceID = true
                } else {
                    useFaceID = false
                    faceIDErrorMessage = authError?.localizedDescription ?? "Face ID could not be enabled."
                    showingFaceIDError = true
                }
            }
        }
    }

    private func savePasscode() {
        let trimmed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else {
            passcodeErrorMessage = "Passcode must be exactly 6 digits."
            showingPasscodeError = true
            return
        }
        guard trimmed == confirmPasscode else {
            passcodeErrorMessage = "Passcodes do not match."
            showingPasscodeError = true
            return
        }

        if KeychainService.setPasscode(trimmed) {
            passcodeSet = true
            showingPasscodeSheet = false
        } else {
            passcodeErrorMessage = "Failed to save passcode."
            showingPasscodeError = true
        }
    }
}
