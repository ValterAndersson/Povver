/**
 * ExercisePerformanceSheet.swift
 *
 * In-workout exercise performance history sheet.
 * Queries set_facts for the given exercise and displays recent performance
 * grouped by workout date. Presented from the exercise ellipsis menu.
 *
 * Firestore index required: set_facts subcollection needs composite index
 * (exercise_id ASC, is_warmup ASC, workout_date DESC). Firestore will log
 * the creation URL on first failed query if the index doesn't exist.
 */

import SwiftUI
import FirebaseFirestore

// MARK: - SetFact Model (read-only projection of set_facts document)

/// Lightweight projection of set_facts fields needed for performance display.
/// Uses decodeIfPresent + defaults for resilience (matches codebase convention).
private struct SetFact: Decodable {
    let workoutId: String
    let workoutDate: String
    let setIndex: Int
    let weightKg: Double?
    let reps: Int?
    let rir: Int?
    let e1rm: Double?
    let isWarmup: Bool
    let isFailure: Bool

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case workoutDate = "workout_date"
        case setIndex = "set_index"
        case weightKg = "weight_kg"
        case reps
        case rir
        case e1rm
        case isWarmup = "is_warmup"
        case isFailure = "is_failure"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workoutId = try container.decodeIfPresent(String.self, forKey: .workoutId) ?? ""
        workoutDate = try container.decodeIfPresent(String.self, forKey: .workoutDate) ?? ""
        setIndex = try container.decodeIfPresent(Int.self, forKey: .setIndex) ?? 0
        weightKg = try container.decodeIfPresent(Double.self, forKey: .weightKg)
        reps = try container.decodeIfPresent(Int.self, forKey: .reps)
        rir = try container.decodeIfPresent(Int.self, forKey: .rir)
        e1rm = try container.decodeIfPresent(Double.self, forKey: .e1rm)
        isWarmup = try container.decodeIfPresent(Bool.self, forKey: .isWarmup) ?? false
        isFailure = try container.decodeIfPresent(Bool.self, forKey: .isFailure) ?? false
    }

    /// Set type indicator matching SetTable convention
    var setTypeLabel: String? {
        if isWarmup { return "W" }
        if isFailure { return "F" }
        return nil
    }

    var setTypeColor: Color? {
        if isWarmup { return Color.warning }
        if isFailure { return Color.destructive }
        return nil
    }
}

// MARK: - Sheet View

struct ExercisePerformanceSheet: View {
    let exerciseId: String
    let exerciseName: String
    let onDismiss: () -> Void

    @State private var setFacts: [SetFact] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var weightUnit: WeightUnit { UserService.shared.activeWorkoutWeightUnit }

    var body: some View {
        SheetScaffold(
            title: exerciseName,
            cancelTitle: "Done",
            doneTitle: nil,
            onCancel: { onDismiss() }
        ) {
            if isLoading {
                loadingView
            } else if let error {
                errorView(error)
            } else if groupedSessions.isEmpty {
                emptyView
            } else {
                performanceContent
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await loadSetFacts()
        }
    }

    // MARK: - Data Loading

    private func loadSetFacts() async {
        guard let userId = AuthService.shared.currentUser?.uid else {
            error = "Not signed in"
            isLoading = false
            return
        }

        do {
            let db = Firestore.firestore()
            let snapshot = try await db.collection("users")
                .document(userId)
                .collection("set_facts")
                .whereField("exercise_id", isEqualTo: exerciseId)
                .whereField("is_warmup", isEqualTo: false)
                .order(by: "workout_date", descending: true)
                .limit(to: 30)
                .getDocuments()

            setFacts = snapshot.documents.compactMap { doc in
                try? doc.data(as: SetFact.self)
            }
        } catch {
            self.error = "Could not load history"
            print("[ExercisePerformanceSheet] Query failed: \(error)")
        }

        isLoading = false
    }

    // MARK: - Data Processing

    /// Group set_facts by workout_id, ordered by most recent workout_date
    private var groupedSessions: [(workoutDate: String, sets: [SetFact])] {
        var groups: [String: (date: String, sets: [SetFact])] = [:]

        for fact in setFacts {
            if groups[fact.workoutId] == nil {
                groups[fact.workoutId] = (date: fact.workoutDate, sets: [])
            }
            groups[fact.workoutId]?.sets.append(fact)
        }

        // Sort by date descending, limit to 5 sessions
        return groups.values
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { (workoutDate: $0.date, sets: $0.sets.sorted { $0.setIndex < $1.setIndex }) }
    }

    /// Best e1RM across all loaded sets
    private var bestE1RM: Double? {
        setFacts.compactMap(\.e1rm).max()
    }

    /// Most recent set's weight
    private var lastWeight: Double? {
        groupedSessions.first?.sets.last?.weightKg
    }

    /// Most recent set's reps
    private var lastReps: Int? {
        groupedSessions.first?.sets.last?.reps
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Loading history...")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(Color.textTertiary)
            Text(message)
                .font(.system(size: 15))
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyView: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 36))
                .foregroundColor(Color.textTertiary)
            Text("No performance history")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            Text("Complete a workout with this exercise to see your history here.")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var performanceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Summary row
                summaryRow

                // Recent sessions
                ForEach(Array(groupedSessions.enumerated()), id: \.offset) { _, session in
                    sessionCard(date: session.workoutDate, sets: session.sets)
                }

                Spacer(minLength: Space.lg)
            }
            .padding(Space.lg)
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 0) {
            if let e1rm = bestE1RM {
                summaryItem(value: WeightFormatter.formatValue(e1rm, unit: weightUnit), unit: weightUnit.label, label: "Best e1RM")
            }
            if let weight = lastWeight {
                summaryItem(value: WeightFormatter.formatValue(weight, unit: weightUnit), unit: weightUnit.label, label: "Last Weight")
            }
            if let reps = lastReps {
                summaryItem(value: "\(reps)", unit: "", label: "Last Reps")
            }
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }

    private func summaryItem(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color.textPrimary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                }
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionCard(date: String, sets: [SetFact]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // Date header
            Text(formatDateString(date))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.textSecondary)

            // Set rows
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    Text("Set")
                        .frame(width: 36, alignment: .center)
                    Text("Weight")
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("Reps")
                        .frame(width: 44, alignment: .center)
                    Text("RIR")
                        .frame(width: 36, alignment: .center)
                    Text("e1RM")
                        .frame(width: 52, alignment: .center)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.accent.opacity(0.6))
                .padding(.horizontal, Space.md)
                .padding(.vertical, 6)

                Rectangle()
                    .fill(Color.accent.opacity(0.15))
                    .frame(height: 1)

                ForEach(Array(sets.enumerated()), id: \.offset) { index, setFact in
                    setRow(index: index + 1, fact: setFact)
                    if index < sets.count - 1 {
                        Divider().padding(.leading, Space.md)
                    }
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon)
                    .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
            )
        }
    }

    private func setRow(index: Int, fact: SetFact) -> some View {
        HStack(spacing: 0) {
            // Set index with type badge
            ZStack {
                if let label = fact.setTypeLabel, let color = fact.setTypeColor {
                    Text(label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textInverse)
                        .frame(width: 22, height: 22)
                        .background(color)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("\(index)")
                        .foregroundColor(Color.textSecondary)
                }
            }
            .frame(width: 36, alignment: .center)

            Text(fact.weightKg.map { WeightFormatter.formatValue($0, unit: weightUnit) } ?? "—")
                .frame(maxWidth: .infinity, alignment: .center)
                .foregroundColor(Color.textPrimary)

            Text(fact.reps.map { "\($0)" } ?? "—")
                .frame(width: 44, alignment: .center)
                .foregroundColor(Color.textPrimary)

            Text(fact.isWarmup ? "—" : (fact.rir.map { "\($0)" } ?? "—"))
                .frame(width: 36, alignment: .center)
                .foregroundColor(fact.rir != nil && !fact.isWarmup ? Color.textPrimary : Color.textTertiary)

            Text(fact.e1rm.map { WeightFormatter.formatValue($0, unit: weightUnit) } ?? "—")
                .frame(width: 52, alignment: .center)
                .foregroundColor(fact.e1rm != nil ? Color.textSecondary : Color.textTertiary)
        }
        .font(.system(size: 14).monospacedDigit())
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    /// Format "YYYY-MM-DD" date string for display
    private func formatDateString(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let display = DateFormatter()
            display.dateFormat = "MMM d, yyyy"
            return display.string(from: date)
        }
    }
}
