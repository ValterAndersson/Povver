import SwiftUI

/// Profile editing screen — combines Account + Body Metrics from the old ProfileView.
/// Accessed via NavigationLink from MoreView's profile card.
struct ProfileEditView: View {
    @ObservedObject private var authService = AuthService.shared

    @State private var user: User?
    @State private var userAttributes: UserAttributes?
    @State private var isLoading = true
    @State private var sessionCount = 0
    @State private var linkedProviders: [AuthProvider] = []

    // Edit sheets
    @State private var showingNicknameEditor = false
    @State private var showingHeightEditor = false
    @State private var showingWeightEditor = false
    @State private var showingFitnessLevelPicker = false
    @State private var showingEmailChange = false
    @State private var showingPasswordChange = false

    // Edit values
    @State private var editingNickname = ""
    @State private var editingHeightText = ""
    @State private var editingFeetText = ""
    @State private var editingInchesText = ""
    @State private var editingWeightText = ""
    @State private var editingFitnessLevel = ""

    @State private var errorMessage: String?

    private var weightUnit: WeightUnit { UserService.shared.weightUnit }
    private var heightUnit: HeightUnit { UserService.shared.heightUnit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Header
                profileHeader

                // Account Section
                sectionHeader("Account")
                accountSection

                // Body Metrics Section
                sectionHeader("Body Metrics")
                bodyMetricsSection

                // Error banner
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .padding(.horizontal, Space.lg)
                }

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProfile()
        }
        .sheet(isPresented: $showingNicknameEditor) {
            nicknameEditorSheet
        }
        .sheet(isPresented: $showingHeightEditor) {
            heightEditorSheet
        }
        .sheet(isPresented: $showingWeightEditor) {
            weightEditorSheet
        }
        .sheet(isPresented: $showingFitnessLevelPicker) {
            fitnessLevelPickerSheet
        }
        .sheet(isPresented: $showingEmailChange) {
            EmailChangeView(
                hasEmailProvider: linkedProviders.contains(.email),
                providerDisplayName: linkedProviders.first(where: { $0 != .email })?.displayName ?? "your provider"
            )
        }
        .sheet(isPresented: $showingPasswordChange) {
            PasswordChangeView(hasEmailProvider: linkedProviders.contains(.email))
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                ZStack {
                    Circle()
                        .fill(Color.accent.opacity(0.15))
                        .frame(width: 64, height: 64)

                    Text(initials)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(Color.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color.textPrimary)

                    if let email = user?.email ?? authService.currentUser?.email,
                       !email.hasSuffix("@privaterelay.appleid.com") {
                        Text(email)
                            .font(.system(size: 14))
                            .foregroundColor(Color.textSecondary)
                    }
                }

                Spacer()
            }

            HStack(spacing: Space.lg) {
                if let createdAt = user?.createdAt {
                    statItem(value: formatMemberSince(createdAt), label: "Member since")
                }

                statItem(value: "\(sessionCount)", label: "Sessions")
            }
        }
        .padding(Space.lg)
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(spacing: 0) {
            if linkedProviders.contains(.email) {
                ProfileRow(
                    icon: "envelope",
                    title: "Email",
                    value: user?.email ?? authService.currentUser?.email ?? "-",
                    isEditable: true
                ) {
                    showingEmailChange = true
                }

                Divider().padding(.leading, 56)
            }

            ProfileRow(
                icon: "person",
                title: "Nickname",
                value: user?.name ?? "Not set",
                isEditable: true
            ) {
                editingNickname = user?.name ?? ""
                showingNicknameEditor = true
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Body Metrics Section

    private var bodyMetricsSection: some View {
        VStack(spacing: 0) {
            ProfileRow(
                icon: "ruler",
                title: "Height",
                value: formatHeight(userAttributes?.height),
                isEditable: true
            ) {
                let cm = userAttributes?.height ?? 170
                if heightUnit == .cm {
                    editingHeightText = "\(Int(cm))"
                } else {
                    let (feet, inches) = HeightFormatter.toFeetInches(cm)
                    editingFeetText = "\(feet)"
                    editingInchesText = "\(inches)"
                }
                showingHeightEditor = true
            }

            Divider().padding(.leading, 56)

            ProfileRow(
                icon: "scalemass",
                title: "Weight",
                value: formatWeight(userAttributes?.weight),
                isEditable: true
            ) {
                let weightKg = userAttributes?.weight ?? 70
                let displayed = WeightFormatter.display(weightKg, unit: weightUnit)
                editingWeightText = WeightFormatter.truncateTrailingZeros(displayed)
                showingWeightEditor = true
            }

            Divider().padding(.leading, 56)

            ProfileRow(
                icon: "flame",
                title: "Fitness Level",
                value: userAttributes?.fitnessLevel?.capitalized ?? "Not set",
                isEditable: true
            ) {
                editingFitnessLevel = userAttributes?.fitnessLevel ?? ""
                showingFitnessLevelPicker = true
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Edit Sheets

    private var nicknameEditorSheet: some View {
        SheetScaffold(
            title: "Edit Nickname",
            doneTitle: "Save",
            onCancel: { showingNicknameEditor = false },
            onDone: {
                Task { await saveNickname() }
                showingNicknameEditor = false
            }
        ) {
            VStack(spacing: Space.lg) {
                TextField("Nickname", text: $editingNickname)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                Spacer()
            }
        }
        .presentationDetents([.medium])
    }

    private var heightEditorSheet: some View {
        SheetScaffold(
            title: "Edit Height",
            doneTitle: "Save",
            onCancel: {
                errorMessage = nil
                showingHeightEditor = false
            },
            onDone: {
                Task {
                    if await saveHeight() {
                        showingHeightEditor = false
                    }
                }
            }
        ) {
            VStack(spacing: Space.lg) {
                if heightUnit == .cm {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        TextField("170", text: $editingHeightText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 36, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(width: 120)

                        Text("cm")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(Color.textSecondary)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        TextField("5", text: $editingFeetText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 36, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(width: 80)

                        Text("ft")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(Color.textSecondary)

                        TextField("10", text: $editingInchesText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 36, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(width: 80)

                        Text("in")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(Color.textSecondary)
                    }
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(Color.destructive)
                }
            }
            .padding(.top, Space.xl)
            .padding(.bottom, Space.lg)
        }
        .presentationDetents([.height(200)])
    }

    private var weightEditorSheet: some View {
        SheetScaffold(
            title: "Edit Weight",
            doneTitle: "Save",
            onCancel: {
                errorMessage = nil
                showingWeightEditor = false
            },
            onDone: {
                Task {
                    if await saveWeight() {
                        showingWeightEditor = false
                    }
                }
            }
        ) {
            VStack(spacing: Space.lg) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    TextField("70", text: $editingWeightText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .foregroundColor(Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(width: 140)

                    Text(weightUnit.label)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(Color.textSecondary)
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(Color.destructive)
                }
            }
            .padding(.top, Space.xl)
            .padding(.bottom, Space.lg)
        }
        .presentationDetents([.height(200)])
    }

    private var fitnessLevelPickerSheet: some View {
        SheetScaffold(
            title: "Fitness Level",
            doneTitle: nil,
            onCancel: { showingFitnessLevelPicker = false }
        ) {
            List {
                ForEach(["beginner", "intermediate", "advanced"], id: \.self) { level in
                    Button {
                        editingFitnessLevel = level
                        Task { await saveFitnessLevel(level) }
                        showingFitnessLevelPicker = false
                    } label: {
                        HStack {
                            Text(level.capitalized)
                                .foregroundColor(Color.textPrimary)
                            Spacer()
                            if editingFitnessLevel == level {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Color.accent)
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color.textSecondary)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
        }
    }

    private var displayName: String {
        if let name = user?.name, !name.isEmpty {
            return name
        }
        if let email = user?.email ?? authService.currentUser?.email,
           !email.hasSuffix("@privaterelay.appleid.com") {
            return email.components(separatedBy: "@").first ?? email
        }
        return "User"
    }

    private var initials: String {
        let name = displayName
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func formatMemberSince(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private func formatHeight(_ height: Double?) -> String {
        HeightFormatter.format(height, unit: heightUnit)
    }

    private func formatWeight(_ weight: Double?) -> String {
        guard let weight = weight else { return "Not set" }
        return WeightFormatter.format(weight, unit: weightUnit)
    }

    // MARK: - Data Loading

    private func loadProfile() async {
        guard let userId = authService.currentUser?.uid else {
            isLoading = false
            return
        }

        await authService.reloadCurrentUser()
        linkedProviders = authService.linkedProviders

        do {
            user = try await UserRepository.shared.getUser(userId: userId)
        } catch {
            AppLogger.shared.error(.app, "Failed to load user", error)
        }

        do {
            userAttributes = try await UserRepository.shared.getUserAttributes(userId: userId)
        } catch {
            AppLogger.shared.error(.app, "Failed to load user attributes", error)
        }

        do {
            sessionCount = try await WorkoutRepository().getWorkoutCount(userId: userId)
        } catch {
            // Non-critical — shows 0 sessions on failure
        }

        isLoading = false
    }

    // MARK: - Save Methods

    private func saveNickname() async {
        guard let userId = authService.currentUser?.uid else { return }
        errorMessage = nil

        do {
            try await UserRepository.shared.updateUserProfile(
                userId: userId,
                name: editingNickname,
                email: user?.email ?? ""
            )
            user?.name = editingNickname
        } catch {
            errorMessage = "Failed to save nickname. Please try again."
        }
    }

    /// Returns true on success, false on validation/save failure.
    private func saveHeight() async -> Bool {
        guard let userId = authService.currentUser?.uid else { return false }
        errorMessage = nil

        let heightCm: Double
        if heightUnit == .cm {
            guard let cm = Int(editingHeightText), cm >= 50, cm <= 300 else {
                errorMessage = "Please enter a valid height (50–300 cm)."
                return false
            }
            heightCm = Double(cm)
        } else {
            let feet = Int(editingFeetText) ?? 0
            let inches = Int(editingInchesText) ?? 0
            guard feet >= 1, feet <= 8, inches >= 0, inches <= 11 else {
                errorMessage = "Please enter a valid height (0–11 inches)."
                return false
            }
            heightCm = HeightFormatter.toCm(feet: feet, inches: inches)
            guard heightCm >= 50, heightCm <= 300 else {
                errorMessage = "Please enter a valid height."
                return false
            }
        }

        var attrs = userAttributes ?? UserAttributes(
            id: userId,
            fitnessGoal: nil,
            fitnessLevel: nil,
            equipment: nil,
            height: nil,
            weight: nil,
            workoutFrequency: nil,
            lastUpdated: nil
        )
        attrs.height = heightCm

        do {
            try await UserRepository.shared.saveUserAttributes(attrs)
            userAttributes = attrs
            AnalyticsService.shared.bodyMetricsUpdated(field: "height")
            return true
        } catch {
            errorMessage = "Failed to save height. Please try again."
            return false
        }
    }

    /// Returns true on success, false on validation/save failure.
    private func saveWeight() async -> Bool {
        guard let userId = authService.currentUser?.uid else { return false }
        errorMessage = nil

        let minWeight = weightUnit == .lbs ? 66.0 : 30.0
        let maxWeight = weightUnit == .lbs ? 440.0 : 200.0

        guard let inputValue = Double(editingWeightText),
              inputValue >= minWeight, inputValue <= maxWeight else {
            let rangeLabel = weightUnit == .lbs ? "66–440 lbs" : "30–200 kg"
            errorMessage = "Please enter a valid weight (\(rangeLabel))."
            return false
        }

        var attrs = userAttributes ?? UserAttributes(
            id: userId,
            fitnessGoal: nil,
            fitnessLevel: nil,
            equipment: nil,
            height: nil,
            weight: nil,
            workoutFrequency: nil,
            lastUpdated: nil
        )
        let weightKg = WeightFormatter.toKg(inputValue, from: weightUnit)
        attrs.weight = (weightKg * 10).rounded() / 10

        do {
            try await UserRepository.shared.saveUserAttributes(attrs)
            userAttributes = attrs
            AnalyticsService.shared.bodyMetricsUpdated(field: "weight")
            return true
        } catch {
            errorMessage = "Failed to save weight. Please try again."
            return false
        }
    }

    private func saveFitnessLevel(_ level: String) async {
        guard let userId = authService.currentUser?.uid else { return }
        errorMessage = nil

        var attrs = userAttributes ?? UserAttributes(
            id: userId,
            fitnessGoal: nil,
            fitnessLevel: nil,
            equipment: nil,
            height: nil,
            weight: nil,
            workoutFrequency: nil,
            lastUpdated: nil
        )
        attrs.fitnessLevel = level

        do {
            try await UserRepository.shared.saveUserAttributes(attrs)
            userAttributes = attrs
            AnalyticsService.shared.bodyMetricsUpdated(field: "fitness_level")
        } catch {
            errorMessage = "Failed to save fitness level. Please try again."
        }
    }
}
