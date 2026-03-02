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
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "doc.text.fill")
                    .font(.system(size: 60))
                    .foregroundColor(Color("Primary"))

                Text("Insight")
                    .font(.largeTitle.bold())

                VStack(spacing: 14) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                    SecureField("Password", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                    if isRegistering {
                        SecureField("Confirm Password", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)

                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button {
                    Task { await submitAction() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text(isRegistering ? "Create Account" : "Sign In")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .padding(.horizontal, 24)
                .disabled(isLoading)

                Button {
                    withAnimation {
                        isRegistering.toggle()
                        errorMessage = nil
                        confirmPassword = ""
                    }
                } label: {
                    Text(isRegistering ? "Already have an account? Sign In" : "Don't have an account? Register")
                        .font(.footnote)
                        .foregroundColor(Color("Primary"))
                }

                Spacer()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
    }

    private func submitAction() async {
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
}
