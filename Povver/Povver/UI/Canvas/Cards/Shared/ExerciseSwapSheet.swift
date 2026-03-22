import SwiftUI

/// Sheet for swapping an exercise - uses SheetScaffold for v1.1 consistency
/// Supports both AI suggestions and manual search
public struct ExerciseSwapSheet: View {
    let currentExercise: PlanExercise
    let onSwapWithAI: (ExerciseActionsRow.SwapReason, String) -> Void  // Reason + instruction
    let onSwapManual: (Exercise) -> Void  // Selected replacement exercise
    let onDismiss: () -> Void
    
    @State private var selectedTab: SwapTab = .aiSuggestions
    @State private var searchQuery: String = ""
    @State private var searchResults: [Exercise] = []
    @State private var isSearching: Bool = false
    @State private var errorMessage: String? = nil
    
    private let exerciseRepo = ExerciseRepository()
    
    enum SwapTab {
        case aiSuggestions
        case manualSearch
    }
    
    public var body: some View {
        SheetScaffold(
            title: "Swap Exercise",
            doneTitle: nil,  // No done button, actions are in the content
            onCancel: { onDismiss() }
        ) {
            VStack(spacing: 0) {
                // Current exercise info
                currentExerciseHeader
                
                // Tab picker
                Picker("", selection: $selectedTab) {
                    Text("AI Suggestions").tag(SwapTab.aiSuggestions)
                    Text("Search").tag(SwapTab.manualSearch)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
                .onChange(of: selectedTab) { _, _ in
                    HapticManager.selectionChanged()
                }
                
                // Content
                switch selectedTab {
                case .aiSuggestions:
                    aiSuggestionsView
                case .manualSearch:
                    manualSearchView
                }
            }
        }
        .presentationDetents([.large])
    }
    
    // MARK: - Current Exercise Header
    
    private var currentExerciseHeader: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Currently:")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.textSecondary)
            
            HStack(spacing: Space.sm) {
                Image(systemName: "dumbbell")
                    .font(.system(size: 16))
                    .foregroundColor(Color.accent)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentExercise.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.textPrimary)
                    
                    Text(currentExercise.summaryLine)
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                }
                
                Spacer()
            }
            .padding(Space.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
    
    // MARK: - AI Suggestions View
    
    private var aiSuggestionsView: some View {
        ScrollView {
            VStack(spacing: Space.sm) {
                ForEach([
                    ExerciseActionsRow.SwapReason.sameMuscles,
                    .sameEquipment,
                    .differentAngle,
                    .aiSuggestion
                ], id: \.self) { reason in
                    aiOptionButton(reason: reason)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.lg)
        }
    }
    
    private func aiOptionButton(reason: ExerciseActionsRow.SwapReason) -> some View {
        let (instruction, _) = ExerciseActionsRow.buildSwapInstruction(
            exercise: currentExercise,
            reason: reason
        )
        
        return Button {
            onSwapWithAI(reason, instruction)
            onDismiss()
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: reason.icon)
                    .font(.system(size: 18))
                    .foregroundColor(Color.accent)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.textPrimary)
                    
                    Text(descriptionFor(reason))
                        .font(.system(size: 12))
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary.opacity(0.5))
            }
            .padding(Space.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func descriptionFor(_ reason: ExerciseActionsRow.SwapReason) -> String {
        let muscles = currentExercise.primaryMuscles?.first ?? "same muscles"
        let equipment = currentExercise.equipment ?? "similar equipment"
        
        switch reason {
        case .sameMuscles:
            return "Another \(muscles) exercise with different equipment"
        case .sameEquipment:
            return "Another \(equipment) exercise with a different angle"
        case .differentAngle:
            return "A different movement pattern targeting \(muscles)"
        case .aiSuggestion:
            return "Let the AI coach pick the best alternative based on your goals"
        case .manualSearch:
            return ""
        }
    }
    
    // MARK: - Manual Search View
    
    private var manualSearchView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.textSecondary)
                
                TextField("Search exercises...", text: $searchQuery)
                    .textFieldStyle(PlainTextFieldStyle())
                    .onSubmit { performSearch() }
                
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(Space.sm)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
            
            // Results
            if isSearching {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(Color.destructive)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else if searchResults.isEmpty && !searchQuery.isEmpty {
                Spacer()
                VStack(spacing: Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(Color.textSecondary.opacity(0.5))
                    Text("No exercises found")
                        .font(.system(size: 15))
                        .foregroundColor(Color.textSecondary)
                }
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                VStack(spacing: Space.sm) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(Color.textSecondary.opacity(0.5))
                    Text("Search for an exercise to swap")
                        .font(.system(size: 15))
                        .foregroundColor(Color.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchResults) { exercise in
                            exerciseResultRow(exercise)
                            Divider()
                        }
                    }
                }
            }
        }
    }
    
    private func exerciseResultRow(_ exercise: Exercise) -> some View {
        Button {
            onSwapManual(exercise)
            onDismiss()
        } label: {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.textPrimary)
                    
                    HStack(spacing: Space.sm) {
                        if !exercise.primaryMuscles.isEmpty {
                            Text(exercise.primaryMuscles.joined(separator: ", "))
                                .font(.system(size: 12))
                                .foregroundColor(Color.textSecondary)
                        }
                        
                        if !exercise.equipment.isEmpty {
                            Text("• \(exercise.equipment.joined(separator: ", "))")
                                .font(.system(size: 12))
                                .foregroundColor(Color.textSecondary)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 18))
                    .foregroundColor(Color.accent)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, 12)
            .background(Color.surface)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Search
    
    private func performSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        isSearching = true
        errorMessage = nil
        
        Task {
            do {
                let allResults = try await exerciseRepo.searchExercises(query: searchQuery)
                // Limit to first 30 results
                let results = Array(allResults.prefix(30))
                await MainActor.run {
                    searchResults = results
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Search failed: \(error.localizedDescription)"
                    isSearching = false
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ExerciseSwapSheet_Previews: PreviewProvider {
    static var previews: some View {
        ExerciseSwapSheet(
            currentExercise: PlanExercise(name: "Bench Press", sets: [
                PlanSet(type: .working, reps: 8, weight: 80, rir: 2)
            ]),
            onSwapWithAI: { reason, instruction in print("AI swap: \(reason) - \(instruction)") },
            onSwapManual: { exercise in print("Manual swap to: \(exercise.name)") },
            onDismiss: { print("Dismissed") }
        )
    }
}
#endif
