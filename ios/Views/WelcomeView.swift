import SwiftUI

/// Placeholder welcome screen.
/// Replace the content between the TODO markers with your design.
/// The only requirement: call `hasSeenWelcome = true` when the user taps "Get Started".
struct WelcomeView: View {
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // TODO: Replace everything in this VStack with your welcome design
                VStack(spacing: 16) {
                    Image("IconSvg")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)   // control size here
                        .foregroundStyle(.tint)

                    Text("Insight")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Your AI document assistant")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                // END TODO

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hasSeenWelcome = true
                    }
                } label: {
                    Text("Get Started")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 48)
            }
        }
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
