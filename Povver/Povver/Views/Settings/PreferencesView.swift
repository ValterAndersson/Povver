import SwiftUI

/// Preferences screen — timezone and week start settings.
/// Accessed via NavigationLink from MoreView.
struct PreferencesView: View {
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var userService = UserService.shared

    @State private var user: User?
    @State private var errorMessage: String?
    @State private var selectedWeightUnit: WeightUnit = UserService.shared.weightUnit
    @State private var selectedHeightUnit: HeightUnit = UserService.shared.heightUnit
    @State private var isUpdatingWeightUnit = false
    @State private var isUpdatingHeightUnit = false
    @State private var isInitializing = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                sectionHeader("General")

                VStack(spacing: 0) {
                    ProfileRow(
                        icon: "globe",
                        title: "Timezone",
                        value: user?.timeZone ?? TimeZone.current.identifier
                    )

                    Divider().padding(.leading, 56)

                    ProfileRowToggle(
                        icon: "calendar",
                        title: "Week Starts On Monday",
                        isOn: Binding(
                            get: { user?.weekStartsOnMonday ?? true },
                            set: { newValue in
                                Task { await updateWeekStart(newValue) }
                            }
                        )
                    )
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .padding(.horizontal, Space.lg)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .padding(.horizontal, Space.lg)
                }

                sectionHeader("Units")

                VStack(spacing: 0) {
                    HStack(spacing: Space.md) {
                        Image(systemName: "scalemass")
                            .font(.system(size: 18))
                            .foregroundColor(Color.textSecondary)
                            .frame(width: 24)

                        Text("Weight")
                            .font(.system(size: 15))
                            .foregroundColor(Color.textPrimary)

                        Spacer()

                        Picker("", selection: $selectedWeightUnit) {
                            ForEach(WeightUnit.allCases, id: \.self) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                        .disabled(isUpdatingWeightUnit)
                        .onChange(of: selectedWeightUnit) { _, newValue in
                            guard !isInitializing else { return }
                            HapticManager.selectionChanged()
                            Task { await updateWeightUnit(newValue) }
                        }
                    }
                    .padding(Space.md)

                    Divider().padding(.leading, 56)

                    HStack(spacing: Space.md) {
                        Image(systemName: "ruler")
                            .font(.system(size: 18))
                            .foregroundColor(Color.textSecondary)
                            .frame(width: 24)

                        Text("Height")
                            .font(.system(size: 15))
                            .foregroundColor(Color.textPrimary)

                        Spacer()

                        Picker("", selection: $selectedHeightUnit) {
                            ForEach(HeightUnit.allCases, id: \.self) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                        .disabled(isUpdatingHeightUnit)
                        .onChange(of: selectedHeightUnit) { _, newValue in
                            guard !isInitializing else { return }
                            HapticManager.selectionChanged()
                            Task { await updateHeightUnit(newValue) }
                        }
                    }
                    .padding(Space.md)
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .padding(.horizontal, Space.lg)

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadUser()
            await userService.ensurePreferencesLoaded()
            print("[PreferencesView] Loaded prefs — weight: \(userService.weightUnit), height: \(userService.heightUnit)")
            selectedWeightUnit = userService.weightUnit
            selectedHeightUnit = userService.heightUnit
            isInitializing = false
            print("[PreferencesView] Init complete — selectedWeight: \(selectedWeightUnit), selectedHeight: \(selectedHeightUnit)")
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color.textSecondary)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }

    private func loadUser() async {
        guard let userId = authService.currentUser?.uid else { return }
        do {
            user = try await UserRepository.shared.getUser(userId: userId)
        } catch {
            print("[PreferencesView] Failed to load user: \(error)")
        }
    }

    private func updateWeekStart(_ startsOnMonday: Bool) async {
        guard let userId = authService.currentUser?.uid else { return }
        errorMessage = nil

        do {
            try await UserRepository.shared.updateUserProfile(
                userId: userId,
                name: user?.name ?? "",
                email: user?.email ?? "",
                weekStartsOnMonday: startsOnMonday
            )
            user?.weekStartsOnMonday = startsOnMonday
            AnalyticsService.shared.preferenceChanged(preference: "week_start", value: startsOnMonday ? "monday" : "sunday")
        } catch {
            errorMessage = "Failed to update preference. Please try again."
        }
    }

    private func updateWeightUnit(_ unit: WeightUnit) async {
        guard authService.currentUser?.uid != nil else {
            print("[PreferencesView] updateWeightUnit — no auth, skipping")
            return
        }
        print("[PreferencesView] updateWeightUnit — saving \(unit) (firestore: \(unit.firestoreFormat))")
        errorMessage = nil
        isUpdatingWeightUnit = true

        defer {
            isUpdatingWeightUnit = false
        }

        do {
            let requestBody = UpdatePreferencesRequest(preferences: ["weight_format": unit.firestoreFormat])
            let _: UpdatePreferencesResponse = try await ApiClient.shared.postJSON("updateUserPreferences", body: requestBody)
            print("[PreferencesView] updateWeightUnit — API success, optimistic update to \(unit)")
            UserService.shared.weightUnit = unit
            AnalyticsService.shared.preferenceChanged(preference: "weight_unit", value: unit.rawValue)
        } catch {
            print("[PreferencesView] updateWeightUnit — API FAILED: \(error)")
            errorMessage = "Failed to update preference. Please try again."
            selectedWeightUnit = userService.weightUnit
        }
    }

    private func updateHeightUnit(_ unit: HeightUnit) async {
        guard authService.currentUser?.uid != nil else {
            print("[PreferencesView] updateHeightUnit — no auth, skipping")
            return
        }
        print("[PreferencesView] updateHeightUnit — saving \(unit) (firestore: \(unit.firestoreFormat))")
        errorMessage = nil
        isUpdatingHeightUnit = true

        defer {
            isUpdatingHeightUnit = false
        }

        do {
            let requestBody = UpdatePreferencesRequest(preferences: ["height_format": unit.firestoreFormat])
            let _: UpdatePreferencesResponse = try await ApiClient.shared.postJSON("updateUserPreferences", body: requestBody)
            print("[PreferencesView] updateHeightUnit — API success, optimistic update to \(unit)")
            UserService.shared.heightUnit = unit
            AnalyticsService.shared.preferenceChanged(preference: "height_unit", value: unit.rawValue)
        } catch {
            print("[PreferencesView] updateHeightUnit — API FAILED: \(error)")
            errorMessage = "Failed to update preference. Please try again."
            selectedHeightUnit = userService.heightUnit
        }
    }
}

// MARK: - Request/Response Types

struct UpdatePreferencesRequest: Encodable {
    let preferences: [String: String]
}

struct UpdatePreferencesResponse: Decodable {
    let success: Bool
}
