import SwiftUI

struct EquipmentScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onSelected: () -> Void

    private let equipmentOptions: [(id: String, title: String, subtitle: String)] = [
        ("commercial_gym", "Commercial gym", "Full equipment"),
        ("home_gym", "Home gym", "Barbell & dumbbells"),
        ("minimal", "Minimal setup", "Bodyweight focused")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Where do you train?")
                .textStyle(.screenTitle)
                .foregroundColor(.textPrimary)

            VStack(spacing: Space.md) {
                ForEach(equipmentOptions, id: \.id) { option in
                    OnboardingSelectionCard(
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: vm.selectedEquipment == option.id
                    ) {
                        HapticManager.selectionTick()
                        vm.selectedEquipment = option.id

                        // Auto-advance after 400ms
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            onSelected()
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xl)
    }
}

#if DEBUG
struct EquipmentScreen_Previews: PreviewProvider {
    static var previews: some View {
        EquipmentScreen(
            vm: OnboardingViewModel(),
            onSelected: {}
        )
        .background(Color.bg)
    }
}
#endif
