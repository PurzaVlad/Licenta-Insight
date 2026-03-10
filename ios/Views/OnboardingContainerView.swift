import SwiftUI

struct OnboardingContainerView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var lockManager: LockManager

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            if !hasSeenWelcome {
                WelcomeView()
            } else if !authService.isSignedIn {
                LoginView()
                    .environmentObject(authService)
            } else {
                BiometricSetupView {
                    if let uid = authService.currentUserID {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding_\(uid)")
                    }
                    hasCompletedOnboarding = true
                }
                .environmentObject(lockManager)
            }
        }
        .tint(Color("Primary"))
    }
}

#Preview("Welcome step") {
    OnboardingContainerView()
        .environmentObject(AuthService.shared)
        .environmentObject(LockManager())
        .onAppear {
            UserDefaults.standard.removeObject(forKey: "hasSeenWelcome")
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        }
}

#Preview("Login step") {
    OnboardingContainerView()
        .environmentObject(AuthService.shared)
        .environmentObject(LockManager())
        .onAppear {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        }
}

#Preview("Biometric step") {
    OnboardingContainerView()
        .environmentObject(AuthService.shared)
        .environmentObject(LockManager())
        .onAppear {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        }
}
