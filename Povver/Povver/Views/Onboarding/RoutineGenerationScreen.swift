import SwiftUI

struct RoutineGenerationScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onStartTraining: () -> Void
    let onAdjustWithCoach: () -> Void

    @State private var phase = 1
    @State private var showTitle = false
    @State private var showRoutineName = false
    @State private var showDayCards: [Bool] = []

    var body: some View {
        VStack(spacing: Space.zero) {
            if phase == 1 {
                buildingPhase
            } else {
                revealPhase
            }
        }
        .task {
            await startGeneration()
        }
    }

    // MARK: - Phase 1: Building

    private var buildingPhase: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            VStack(spacing: Space.xl) {
                // Title
                Text("Building your program")
                    .textStyle(.screenTitle)
                    .foregroundColor(.textPrimary)

                // Thinking dots (3 emerald circles pulsing)
                HStack(spacing: Space.sm) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.accent)
                            .frame(width: 6, height: 6)
                            .opacity(0.3)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.2),
                                value: phase
                            )
                    }
                }

                // Parameter echo
                Text(parameterEcho)
                    .textStyle(.secondary)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(.horizontal, Space.lg)
    }

    private var parameterEcho: String {
        let level = vm.fitnessLevel?.capitalized ?? "Intermediate"
        let days = vm.selectedFrequency.map { "\($0) days" } ?? "4 days"
        let equipment = equipmentLabel
        return "\(level) · \(days) · \(equipment)"
    }

    private var equipmentLabel: String {
        guard let eq = vm.selectedEquipment else { return "full equipment" }
        switch eq {
        case "commercial_gym": return "full equipment"
        case "home_gym": return "home gym"
        case "minimal": return "minimal setup"
        default: return "full equipment"
        }
    }

    // MARK: - Phase 2: Reveal

    private var revealPhase: some View {
        VStack(spacing: Space.xl) {
            // Title
            if showTitle {
                Text("Your program")
                    .textStyle(.screenTitle)
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // Routine name with gradient
            if showRoutineName, let name = vm.generatedRoutineName {
                Text(name)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(hex: "22C59A"),
                                Color(hex: "7CEFCE"),
                                Color(hex: "22C59A")
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // Day cards
            ScrollView {
                VStack(spacing: Space.md) {
                    ForEach(Array(vm.generatedDays.enumerated()), id: \.offset) { index, day in
                        if index < showDayCards.count && showDayCards[index] {
                            dayCard(day: day)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }

            Spacer()

            // Dual CTA
            if showDayCards.allSatisfy({ $0 }) && !vm.generatedDays.isEmpty {
                VStack(spacing: Space.md) {
                    PovverButton("Start training", style: .primary) {
                        HapticManager.modeToggle()
                        onStartTraining()
                    }

                    Button {
                        onAdjustWithCoach()
                    } label: {
                        Text("Adjust with coach")
                            .textStyle(.body)
                            .foregroundColor(.accent)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xl)
    }

    @ViewBuilder
    private func dayCard(day: (day: Int, title: String, exerciseCount: Int, duration: Int)) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Day \(day.day)")
                    .textStyle(.secondary)
                    .foregroundColor(.textTertiary)

                Text(day.title)
                    .textStyle(.bodyStrong)
                    .foregroundColor(.textPrimary)

                HStack(spacing: Space.md) {
                    Label("\(day.exerciseCount) exercises", systemImage: "figure.strengthtraining.traditional")
                        .textStyle(.secondary)
                        .foregroundColor(.textSecondary)

                    Label("\(day.duration) min", systemImage: "clock")
                        .textStyle(.secondary)
                        .foregroundColor(.textSecondary)
                }
                .font(.system(size: 15))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Generation Logic

    private func startGeneration() async {
        await MainActor.run {
            showDayCards = Array(repeating: false, count: vm.generatedDays.count)
        }

        let startTime = Date()

        // Poll for generation completion (60s timeout, matching server timeoutSeconds)
        var elapsed: TimeInterval = 0
        while !vm.generationComplete && elapsed < 60 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            elapsed = Date().timeIntervalSince(startTime)
        }

        // Ensure minimum 3s in phase 1
        let minPhase1Duration = 3.0
        if elapsed < minPhase1Duration {
            try? await Task.sleep(nanoseconds: UInt64((minPhase1Duration - elapsed) * 1_000_000_000))
        }

        // Transition to phase 2
        await MainActor.run {
            // Re-sync showDayCards with generated data (may have arrived during poll)
            showDayCards = Array(repeating: false, count: vm.generatedDays.count)

            withAnimation(.easeOut(duration: 0.4)) {
                phase = 2
            }
        }

        // Fire success haptic
        HapticManager.confirmAction()

        // Staggered reveals
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                showTitle = true
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.4)) {
                showRoutineName = true
            }
        }

        // Stagger day cards (200ms each)
        for index in vm.generatedDays.indices {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    if index < showDayCards.count {
                        showDayCards[index] = true
                    }
                }
            }
        }
    }
}

#if DEBUG
struct RoutineGenerationScreen_Previews: PreviewProvider {
    static var previews: some View {
        let vm = OnboardingViewModel()
        vm.generatedRoutineName = "Upper/Lower Split"
        vm.generatedDays = [
            (day: 1, title: "Upper Body A", exerciseCount: 6, duration: 60),
            (day: 2, title: "Lower Body A", exerciseCount: 5, duration: 55),
            (day: 3, title: "Upper Body B", exerciseCount: 6, duration: 60),
            (day: 4, title: "Lower Body B", exerciseCount: 5, duration: 55)
        ]
        vm.generationComplete = true

        return RoutineGenerationScreen(
            vm: vm,
            onStartTraining: {},
            onAdjustWithCoach: {}
        )
        .background(Color.bg)
    }
}
#endif
