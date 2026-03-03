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
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 72))
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
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 48)
            }
        }
    }
}
