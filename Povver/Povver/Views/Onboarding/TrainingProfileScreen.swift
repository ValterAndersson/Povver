import SwiftUI

// MARK: - Reusable Components

struct OnboardingSelectionCard: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    init(title: String, subtitle: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                // Left border indicator (3pt emerald, only when selected)
                Rectangle()
                    .fill(Color.accent)
                    .frame(width: 3)
                    .opacity(isSelected ? 1 : 0)

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title)
                        .textStyle(.bodyStrong)
                        .foregroundColor(isSelected ? .textPrimary : .textSecondary)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .textStyle(.secondary)
                            .foregroundColor(.textTertiary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, Space.lg)
            .padding(.horizontal, Space.md)
            .background(
                isSelected
                    ? Color.accent.opacity(0.06)
                    : Color(hex: "111820")
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
            )
        }
        .buttonStyle(.plain)
    }
}

struct FrequencyCircle: View {
    let number: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.system(size: 17, weight: .semibold, design: .default).monospacedDigit())
                .foregroundColor(isSelected ? .black : .textSecondary)
                .frame(width: 48, height: 48)
                .background(
                    isSelected
                        ? Color.accent
                        : Color(hex: "111820")
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
                )
                .scaleEffect(isSelected ? 1.12 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Training Profile Screen

struct TrainingProfileScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onContinue: () -> Void

    @State private var showContinue = false

    private let experienceOptions: [(id: String, title: String)] = [
        ("under_1_year", "Under a year"),
        ("1_3_years", "1 – 3 years"),
        ("3_plus_years", "3+ years")
    ]

    var body: some View {
        VStack(spacing: Space.xl) {
            // Q1: Training experience
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Training experience")
                    .textStyle(.screenTitle)
                    .foregroundColor(.textPrimary)

                VStack(spacing: Space.md) {
                    ForEach(experienceOptions, id: \.id) { option in
                        OnboardingSelectionCard(
                            title: option.title,
                            isSelected: vm.selectedExperience == option.id
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            vm.selectedExperience = option.id
                            checkCompletion()
                        }
                    }
                }
            }

            // Q2: Days per week
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Days per week")
                    .textStyle(.screenTitle)
                    .foregroundColor(.textPrimary)

                HStack(spacing: Space.md) {
                    ForEach(2...6, id: \.self) { day in
                        FrequencyCircle(
                            number: day,
                            isSelected: vm.selectedFrequency == day
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            vm.selectedFrequency = day
                            checkCompletion()
                        }
                    }
                }
            }

            Spacer()

            // Continue button (slides up when complete)
            if showContinue {
                PovverButton("Continue", style: .primary) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onContinue()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xl)
    }

    private func checkCompletion() {
        let wasComplete = showContinue
        let isComplete = vm.profileComplete

        if isComplete && !wasComplete {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                showContinue = true
            }
        }
    }
}

#if DEBUG
struct TrainingProfileScreen_Previews: PreviewProvider {
    static var previews: some View {
        TrainingProfileScreen(
            vm: OnboardingViewModel(),
            onContinue: {}
        )
        .background(Color.bg)
    }
}
#endif
