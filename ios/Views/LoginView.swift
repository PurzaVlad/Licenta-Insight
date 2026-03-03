import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isRegistering = false
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // MARK: Fields
                    VStack(spacing: 0) {
                        NativeField {
                            TextField("Email", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        Divider().padding(.leading, 16)
                        NativeField {
                            SecureField("Password", text: $password)
                                .textContentType(isRegistering ? .newPassword : .password)
                        }
                        if isRegistering {
                            Divider().padding(.leading, 16)
                            NativeField {
                                SecureField("Confirm Password", text: $confirmPassword)
                                    .textContentType(.newPassword)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // MARK: Error
                    if let error = errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // MARK: Primary action
                    VStack(spacing: 14) {
                        Button {
                            Task { await submitEmailAction() }
                        } label: {
                            if isLoading {
                                ProgressView().tint(.white)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(isRegistering ? "Create Account" : "Sign In")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isLoading)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isRegistering.toggle()
                                errorMessage = nil
                                confirmPassword = ""
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isRegistering ? "Already have an account?" : "Don't have an account?")
                                    .foregroundStyle(.secondary)
                                Text(isRegistering ? "Sign In" : "Register")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.horizontal)

                    // MARK: Divider
                    HStack(spacing: 12) {
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }
                    .padding(.horizontal)

                    // MARK: Social sign-in
                    HStack(spacing: 20) {
                        Button {
                            Task { await signInWithGoogle() }
                        } label: {
                            Image("GoogleLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                        }
                        .disabled(isLoading)
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isRegistering ? "Create Account" : "Sign In")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Actions

    private func submitEmailAction() async {
        errorMessage = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            errorMessage = "Please enter your email and password."
            return
        }
        if isRegistering {
            guard trimmedPassword == confirmPassword else {
                errorMessage = "Passwords do not match."
                return
            }
            guard trimmedPassword.count >= 6 else {
                errorMessage = "Password must be at least 6 characters."
                return
            }
        }

        isLoading = true
        do {
            if isRegistering {
                try await authService.signUp(email: trimmedEmail, password: trimmedPassword)
            } else {
                try await authService.signIn(email: trimmedEmail, password: trimmedPassword)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func signInWithGoogle() async {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await authService.signInWithGoogle(presenting: root)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}


// MARK: - Native field row

private struct NativeField<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

