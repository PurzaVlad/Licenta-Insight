import SwiftUI

/// Drives the linear first-launch flow:
///   WelcomeView → LoginView → BiometricSetupView
///
/// Shown as a fullScreenCover until the user completes all steps.
/// After this, the existing LoadingScreenView handles the model-download wait.
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
                    hasCompletedOnboarding = true
                }
                .environmentObject(lockManager)
            }
        }
    }
}
