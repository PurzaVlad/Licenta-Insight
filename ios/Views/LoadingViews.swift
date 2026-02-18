import SwiftUI

struct LoadingScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var circleOffset: CGFloat = 16.3

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()

            Image("LogoComplet")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .accessibilityLabel("LogoComplet")
                .overlay {
                    Rectangle()
                        .fill(.background)
                        .frame(width: 220, height: 220)
                        .mask {
                            Rectangle()
                                .overlay {
                                    Circle()
                                        .frame(width: 64.4, height: 64.4)
                                        .offset(y: circleOffset)
                                        .blendMode(.destinationOut)
                                }
                        }
                        .compositingGroup()
                }
        }
        .onAppear {
            Task {
                while !Task.isCancelled {
                    circleOffset = 16.3
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = -16.3
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = 16.3
                    }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
        }
    }
}

struct LoadingScreenView2: View {
    let showsSuccess: Bool
    @State private var circleOffset: CGFloat = 16.3

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.gray.opacity(0.06))
                .ignoresSafeArea()

            if showsSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(Color("Primary"))
            } else {
                Image("LogoComplet")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .mask {
                        Circle()
                            .frame(width: 64.4, height: 64.4)
                            .offset(y: circleOffset)
                    }
                    .accessibilityLabel("LogoComplet")

                Rectangle()
                    .fill(Color.gray.opacity(0.14))
                    .ignoresSafeArea()
                    .mask {
                        Rectangle()
                            .ignoresSafeArea()
                            .overlay {
                                Circle()
                                    .frame(width: 64.4, height: 64.4)
                                    .offset(y: circleOffset)
                                    .blendMode(.destinationOut)
                            }
                    }
                    .compositingGroup()
            }
        }
        .onAppear {
            Task {
                while !Task.isCancelled {
                    circleOffset = 16.3
                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = -16.3
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    withAnimation(.easeInOut(duration: 1.5)) {
                        circleOffset = 16.3
                    }
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
        }
    }
}
