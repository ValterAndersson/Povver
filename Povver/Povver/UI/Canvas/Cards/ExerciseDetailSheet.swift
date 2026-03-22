import SwiftUI

/// Exercise detail sheet - uses SheetScaffold for v1.1 consistency
public struct ExerciseDetailSheet: View {
    let exerciseId: String?
    let exerciseName: String
    let onDismiss: () -> Void
    
    @State private var exercise: Exercise? = nil
    @State private var isLoading: Bool = true
    @State private var error: String? = nil
    
    private let repository = ExerciseRepository()
    
    public init(exerciseId: String?, exerciseName: String, onDismiss: @escaping () -> Void) {
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        SheetScaffold(
            title: exerciseName,
            cancelTitle: "Done",  // Use "Done" as the cancel button text
            doneTitle: nil,  // Hide the done button (single button pattern)
            onCancel: { onDismiss() }
        ) {
            if isLoading {
                loadingView
            } else if let error = error {
                errorView(error)
            } else if let exercise = exercise {
                exerciseContent(exercise)
            } else {
                notFoundView
            }
        }
        .task {
            await loadExercise()
        }
    }
    
    // MARK: - Loading
    
    private var loadingView: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Loading exercise details…")
                .textStyle(.body)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(Color.destructive)
            Text("Failed to load exercise")
                .textStyle(.sectionHeader)
            Text(message)
                .textStyle(.caption)
                .foregroundStyle(Color.textSecondary)
            Button("Retry") {
                Task { await loadExercise() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    private var notFoundView: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundColor(Color.textSecondary)
            Text("Exercise not found")
                .textStyle(.sectionHeader)
            Text("This exercise may not be in the catalog yet.")
                .textStyle(.body)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Content

    private func exerciseContent(_ ex: Exercise) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Header info
                headerSection(ex)

                // Description
                if !ex.description.isEmpty {
                    descriptionSection(ex)
                }

                // Muscles
                musclesSection(ex)

                // Execution notes
                if !ex.executionNotes.isEmpty {
                    numberedListSection(
                        title: "How to Perform",
                        icon: "list.number",
                        items: ex.executionNotes
                    )
                }

                // Coaching cues
                if !ex.coachingCues.isEmpty {
                    bulletListSection(
                        title: "Coaching Cues",
                        icon: "megaphone",
                        items: ex.coachingCues,
                        bulletIcon: "quote.bubble.fill",
                        bulletColor: Color.accent
                    )
                }

                // Tips
                if !ex.tips.isEmpty {
                    bulletListSection(
                        title: "Tips",
                        icon: "lightbulb",
                        items: ex.tips,
                        bulletIcon: "star.fill",
                        bulletColor: Color.warning
                    )
                }

                // Common mistakes
                if !ex.commonMistakes.isEmpty {
                    bulletListSection(
                        title: "Common Mistakes",
                        icon: "exclamationmark.triangle",
                        items: ex.commonMistakes,
                        bulletIcon: "xmark.circle.fill",
                        bulletColor: Color.destructive
                    )
                }

                // Programming notes
                if !ex.programmingNotes.isEmpty {
                    bulletListSection(
                        title: "Programming Tips",
                        icon: "calendar.badge.clock",
                        items: ex.programmingNotes,
                        bulletIcon: "arrow.right.circle.fill",
                        bulletColor: Color.accent
                    )
                }

                // Suitability notes
                if !ex.suitabilityNotes.isEmpty {
                    bulletListSection(
                        title: "Best Suited For",
                        icon: "person.fill.checkmark",
                        items: ex.suitabilityNotes,
                        bulletIcon: "checkmark.circle.fill",
                        bulletColor: Color.success
                    )
                }

                Spacer(minLength: Space.xl)
            }
            .padding(Space.lg)
        }
    }

    private func descriptionSection(_ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(ex.description)
                .textStyle(.body)
        }
    }

    private func numberedListSection(title: String, icon: String, items: [String]) -> some View {
        section(title: title, icon: icon) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: Space.sm) {
                        Text("\(index + 1).")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.accent)
                            .frame(width: 20, alignment: .leading)
                        markdownText(items[index])
                    }
                }
            }
        }
    }

    /// Render a string as markdown, falling back to plain text if parsing fails.
    private func markdownText(_ string: String) -> some View {
        Group {
            if let attributed = try? AttributedString(markdown: string) {
                Text(attributed)
                    .textStyle(.body)
            } else {
                Text(string)
                    .textStyle(.body)
            }
        }
    }

    private func bulletListSection(title: String, icon: String, items: [String], bulletIcon: String, bulletColor: Color) -> some View {
        section(title: title, icon: icon) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: bulletIcon)
                            .font(.system(size: 14))
                            .foregroundColor(bulletColor)
                        markdownText(item)
                    }
                }
            }
        }
    }
    
    private func headerSection(_ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Category & Level badges
            FlowLayout(spacing: Space.xs) {
                StatusTag(ex.capitalizedCategory, kind: .info)
                StatusTag(ex.capitalizedLevel, kind: .info)
                if let split = ex.capitalizedMovementSplit {
                    StatusTag(split, kind: .info)
                }
                if let unilateral = ex.metadata.unilateral, unilateral {
                    StatusTag("Unilateral", kind: .info)
                }
            }

            // Equipment
            if !ex.equipment.isEmpty {
                HStack(spacing: Space.xs) {
                    Image(systemName: "dumbbell")
                        .font(.system(size: 14))
                        .foregroundColor(Color.textSecondary)
                    Text(ex.capitalizedEquipment)
                        .textStyle(.body)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            // Movement type & plane
            HStack(spacing: Space.xs) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textSecondary)
                Text(ex.capitalizedMovementType)
                    .textStyle(.body)
                    .foregroundStyle(Color.textSecondary)
                if let plane = ex.metadata.planeOfMotion {
                    Text("• \(plane.capitalized)")
                        .textStyle(.body)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            // Stimulus tags
            if !ex.stimulusTags.isEmpty {
                FlowLayout(spacing: Space.xs) {
                    ForEach(ex.stimulusTags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, 4)
                            .background(Color.accent.opacity(0.1))
                            .foregroundColor(Color.accent)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
                    }
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
    }
    
    private func musclesSection(_ ex: Exercise) -> some View {
        section(title: "Target Muscles", icon: "figure.strengthtraining.traditional") {
            VStack(alignment: .leading, spacing: Space.md) {
                // Primary muscles
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Primary")
                        .textStyle(.caption)
                        .foregroundStyle(Color.textSecondary)
                    FlowLayout(spacing: Space.xs) {
                        ForEach(ex.primaryMuscles, id: \.self) { muscle in
                            muscleBadge(muscle, isPrimary: true, contribution: ex.getContribution(for: muscle))
                        }
                    }
                }
                
                // Secondary muscles
                if !ex.secondaryMuscles.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Secondary")
                            .textStyle(.caption)
                            .foregroundStyle(Color.textSecondary)
                        FlowLayout(spacing: Space.xs) {
                            ForEach(ex.secondaryMuscles, id: \.self) { muscle in
                                muscleBadge(muscle, isPrimary: false, contribution: ex.getContribution(for: muscle))
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func muscleBadge(_ muscle: String, isPrimary: Bool, contribution: Double?) -> some View {
        HStack(spacing: 4) {
            Text(muscle.capitalized)
                .font(.system(size: 13, weight: isPrimary ? .medium : .regular))
            if let contrib = contribution {
                Text(String(format: "%.0f%%", contrib * 100))
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary)
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 4)
        .background(isPrimary ? Color.accent.opacity(0.15) : Color.surfaceElevated)
        .foregroundColor(isPrimary ? Color.accent : Color.textPrimary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
    }
    
    private func section<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color.accent)
                Text(title)
                    .textStyle(.sectionHeader)
            }
            content()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadExercise() async {
        isLoading = true
        error = nil
        
        print("[ExerciseDetailSheet] Loading exercise: id=\(exerciseId ?? "nil") name=\(exerciseName)")
        
        do {
            // Try by ID first
            if let id = exerciseId, !id.isEmpty {
                print("[ExerciseDetailSheet] Trying to read by ID: \(id)")
                exercise = try await repository.read(id: id)
                if exercise != nil {
                    print("[ExerciseDetailSheet] Found by ID: \(exercise!.name)")
                } else {
                    print("[ExerciseDetailSheet] Not found by ID, will try name search")
                }
            }
            
            // If not found by ID, search by name (case-insensitive)
            if exercise == nil {
                print("[ExerciseDetailSheet] Searching all exercises...")
                let allExercises = try await repository.list()
                print("[ExerciseDetailSheet] Got \(allExercises.count) exercises from list()")
                
                let searchName = exerciseName.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Exact match first
                exercise = allExercises.first { $0.name.lowercased() == searchName }
                if exercise != nil {
                    print("[ExerciseDetailSheet] Found by exact name match: \(exercise!.name)")
                }
                
                // Contains match fallback
                if exercise == nil {
                    exercise = allExercises.first { $0.name.lowercased().contains(searchName) || searchName.contains($0.name.lowercased()) }
                    if exercise != nil {
                        print("[ExerciseDetailSheet] Found by contains match: \(exercise!.name)")
                    }
                }
                
                if exercise == nil {
                    print("[ExerciseDetailSheet] Exercise not found. Sample names: \(allExercises.prefix(5).map { $0.name })")
                }
            }
        } catch {
            print("[ExerciseDetailSheet] Error: \(error)")
            self.error = "Couldn't load exercise details"
        }
        
        isLoading = false
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        
        let height = y + rowHeight
        return (CGSize(width: maxWidth, height: height), frames)
    }
}
