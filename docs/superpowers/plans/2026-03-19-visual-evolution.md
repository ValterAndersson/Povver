# Visual Evolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Elevate the main iOS app's visual polish and brand identity to match the onboarding experience, with proper data services for dynamic Coach tab content.

**Architecture:** Four-tier rollout — (1) design system foundation, (2) data services for training intelligence, (3) screen redesigns consuming the new tokens and services, (4) personality/delight layer. Each tier is independently shippable. Services follow the existing singleton `ObservableObject` pattern. All training analytics data already exists in Firestore — the iOS work is reading and presenting it.

**Tech Stack:** SwiftUI, Firebase/Firestore, Swift Testing, existing design token system in `Tokens.swift`.

**Spec:** `docs/superpowers/specs/2026-03-19-visual-evolution-design.md`

---

## File Map

### New Files

| File | Purpose |
|------|---------|
| `Models/TrainingIntelligence.swift` | Codable models: `WeeklyReview`, `AnalysisInsight`, `AnalyticsRollup`, `ExerciseTrend`, `TrainingSnapshot`, `PostWorkoutSummary`, `Milestone`, `WeekWorkoutCount` |
| `Services/TrainingDataService.swift` | Reads training intelligence from Firestore (weekly_reviews, analysis_insights, analytics_rollups). Caching. Singleton. |
| `Services/HapticManager.swift` | Centralized haptic feedback utility |
| `ViewModels/CoachTabViewModel.swift` | State machine for Coach tab (newUser/workoutDay/restDay/postWorkout/returning) |
| `UI/Components/CoachPresenceIndicator.swift` | Breathing emerald glow component |
| `UI/Components/TrainingConsistencyMap.swift` | 12-week training consistency grid — Povver's signature visual |
| `UI/Components/TrendDelta.swift` | "+2.5 kg" earned-color trend badge |
| `UI/Components/StaggeredEntrance.swift` | Reusable staggered fade+slide view modifier |

### Modified Files (key changes only)

| File | Changes |
|------|---------|
| `UI/DesignSystem/Tokens.swift` | Add `sectionLabel` TextStyle, spring presets, workout mode colors. Remove legacy TypographyToken/CornerRadiusToken values. |
| `UI/Components/PovverText.swift` | Deprecate `PovverTextStyle` enum. Keep `PovverText` struct working but mark legacy styles as deprecated. |
| `UI/Components/SurfaceCard.swift` | Formalize Tier 0/1/2 API if needed |
| `UI/Components/Inputs/Chip.swift` | Neutral selected state (no accentMuted) |
| `Views/MainTabsView.swift` | Tab bar tint → neutral, inject `workoutActive` environment |
| `Views/Tabs/CoachTabView.swift` | Full rewrite — state-driven hero, consistency map, contextual actions |
| `Views/Tabs/LibraryView.swift` | Rewrite — routine hero, template cards, exercise quick access |
| `Views/Tabs/HistoryView.swift` | Section labels, chart colors, PR badges, typography migration |
| `Views/Tabs/MoreView.swift` | Section labels, typography migration, avatar/sign-out cleanup |
| `UI/FocusMode/FocusModeWorkoutScreen.swift` | Workout mode tint, coach presence dot, header refinements |
| `UI/FocusMode/FocusModeSetGrid.swift` | Column alignment, monospaced digits, PR detection badge |
| `UI/FocusMode/FocusModeWorkoutHelpers.swift` | WorkoutCompletionSummary sequenced reveal rewrite |
| `UI/Shared/FloatingWorkoutBanner.swift` | Shadow token, breathing animation, exercise name |

---

## Tier 1: Design System Foundation

### Task 1: Add Design System Tokens

**Files:**
- Modify: `Povver/Povver/UI/DesignSystem/Tokens.swift`

- [ ] **Step 1: Read current Tokens.swift**

Read the full file to understand the existing structure before making changes.

- [ ] **Step 2: Add `sectionLabel` to TextStyle enum**

In the `TextStyle` enum (around line 191), add the new case:

```swift
case sectionLabel  // 11pt semibold, uppercased, tracking 1pt
```

And in the `.textStyle()` view modifier implementation, add the rendering:

```swift
case .sectionLabel:
    self
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(1)
        .foregroundColor(Color.textSecondary)
```

- [ ] **Step 3: Add spring presets to MotionToken**

```swift
// MARK: - Spring Presets
extension MotionToken {
    /// Workout mode, press states, state changes
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Screen entrances, browsing transitions
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.8)
    /// Celebrations, achievements, milestone reveals
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
}
```

- [ ] **Step 4: Add workout mode environment key**

```swift
// MARK: - Workout Mode Environment
private struct WorkoutActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workoutActive: Bool {
        get { self[WorkoutActiveKey.self] }
        set { self[WorkoutActiveKey.self] = newValue }
    }
}
```

- [ ] **Step 5: Add workout mode background color variants**

In the Color extensions section, add:

```swift
/// Workout mode background — slightly deeper/cooler than standard bg
static let bgWorkout = Color("dsBgWorkout")
```

Note: This requires adding a `dsBgWorkout` color set in `Assets.xcassets` with:
- Light: `#EEF0F2` (cooler than standard `#F6F7F8`)
- Dark: `#080A0E` (deeper than standard `#0B0D12`)

- [ ] **Step 6: Build and verify no compilation errors**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 7: Commit**

```bash
git add Povver/Povver/UI/DesignSystem/Tokens.swift Povver/Povver/Assets.xcassets/
git commit -m "feat(design): add sectionLabel, spring presets, workout mode tokens"
```

---

### Task 2: Create HapticManager

**Files:**
- Create: `Povver/Povver/Services/HapticManager.swift`

- [ ] **Step 1: Create HapticManager**

```swift
import UIKit

/// Centralized haptic feedback — avoids scattered UIImpactFeedbackGenerator calls.
enum HapticManager {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()

    static func setCompleted() {
        lightImpact.impactOccurred()
    }

    static func prDetected() {
        notification.notificationOccurred(.success)
    }

    static func workoutCompleted() {
        notification.notificationOccurred(.success)
    }

    static func milestoneUnlocked() {
        notification.notificationOccurred(.success)
    }

    static func destructiveAction() {
        notification.notificationOccurred(.warning)
    }

    static func primaryAction() {
        lightImpact.impactOccurred()
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/Services/HapticManager.swift
git commit -m "feat(design): add centralized HapticManager"
```

---

### Task 3: Create StaggeredEntrance View Modifier

**Files:**
- Create: `Povver/Povver/UI/Components/StaggeredEntrance.swift`

- [ ] **Step 1: Create the modifier**

```swift
import SwiftUI

/// Staggered fade + slide entrance animation.
/// Usage: `.staggeredEntrance(index: 0, active: hasAppeared)`
struct StaggeredEntrance: ViewModifier {
    let index: Int
    let active: Bool
    let offset: CGFloat
    let delay: Double

    init(index: Int, active: Bool, offset: CGFloat = 8, delay: Double = 0.08) {
        self.index = index
        self.active = active
        self.offset = offset
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active ? 0 : offset)
            .animation(
                MotionToken.gentle.delay(Double(index) * delay),
                value: active
            )
    }
}

extension View {
    /// Apply staggered entrance animation. Set `active` to true on appear.
    /// - Parameters:
    ///   - index: Position in the stagger sequence (0 = first, appears earliest)
    ///   - active: Toggle to true to trigger the entrance
    func staggeredEntrance(index: Int, active: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, active: active))
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/UI/Components/StaggeredEntrance.swift
git commit -m "feat(design): add StaggeredEntrance view modifier"
```

---

### Task 4: Corner Radius Consolidation

**Files:**
- Modify: `Povver/Povver/UI/DesignSystem/Tokens.swift`
- Modify: All files referencing `CornerRadiusToken.small`, `.medium`, `.large`, `.card`

- [ ] **Step 1: Read Tokens.swift to find legacy corner radius values**

Read the `CornerRadiusToken` section.

- [ ] **Step 2: Mark legacy values as deprecated with migration guidance**

```swift
@available(*, deprecated, renamed: "radiusIcon")
static let small: CGFloat = 8

@available(*, deprecated, renamed: "radiusControl")
static let medium: CGFloat = 12

@available(*, deprecated, renamed: "radiusCard")
static let large: CGFloat = 16

@available(*, deprecated, renamed: "radiusCard")
static let card: CGFloat = 18
```

- [ ] **Step 3: Search and replace legacy usages across codebase**

Use Grep to find all usages of `CornerRadiusToken.small`, `.medium`, `.large`, `.card` across the Povver iOS source. Replace:
- `CornerRadiusToken.small` → `CornerRadiusToken.radiusIcon` (or `radiusControl` depending on context)
- `CornerRadiusToken.medium` → `CornerRadiusToken.radiusControl`
- `CornerRadiusToken.large` → `CornerRadiusToken.radiusCard`
- `CornerRadiusToken.card` → `CornerRadiusToken.radiusCard`

Review each usage to pick the right replacement based on what the element is (card container vs control vs icon).

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(design): consolidate corner radius tokens to v1.1"
```

---

### Task 5: Typography Migration — Design System Components

**Files:**
- Modify: `Povver/Povver/UI/Components/PovverText.swift`
- Modify: Any design system components using legacy `PovverTextStyle`

This task migrates the design system components themselves. Screen-level typography migration happens in Tier 3 tasks per screen.

- [ ] **Step 1: Read PovverText.swift**

Understand the legacy `PovverTextStyle` enum and how `PovverText` uses it.

- [ ] **Step 2: Mark PovverTextStyle as deprecated**

Add `@available(*, deprecated, message: "Use .textStyle() modifier instead")` to the enum.

- [ ] **Step 3: Migrate design system components that use PovverTextStyle**

Search for `PovverText(` across `UI/Components/` directory. For each usage, decide whether to:
- Replace `PovverText("text", style: .body)` with `Text("text").textStyle(.body)`
- Or keep `PovverText` temporarily if the component is widely used and the change is too broad.

Priority: migrate components that are used by Tab views (since those will be redesigned in Tier 3).

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(design): deprecate PovverTextStyle, migrate components to .textStyle()"
```

---

### Task 6: Color Adjustments — Tab Bar, Chips, Avatar

**Files:**
- Modify: `Povver/Povver/Views/MainTabsView.swift`
- Modify: `Povver/Povver/UI/Components/Inputs/Chip.swift`
- Modify: `Povver/Povver/Views/Tabs/MoreView.swift` (avatar tint only)

- [ ] **Step 1: Read MainTabsView.swift**

Find the `.tint(Color.accent)` on the TabView.

- [ ] **Step 2: Change tab bar tint to neutral**

Replace `.tint(Color.accent)` with `.tint(Color.textSecondary)`.

- [ ] **Step 3: Read Chip.swift**

Find the selected state styling that uses `accentMuted` and `accentStroke`.

- [ ] **Step 4: Change chip selected state to neutral**

Replace the selected state:
- Background: use a stronger surface (e.g., `Color.surface` with increased opacity or a slightly elevated surface)
- Text: semibold weight (add `.fontWeight(.semibold)` to selected state)
- Border: slightly stronger than unselected (e.g., `Color.textTertiary` at 20% opacity instead of `accentStroke`)

The exact values depend on what's in the file — read it first and make the minimal change.

- [ ] **Step 5: Change avatar tint in MoreView**

Read `MoreView.swift`, find the profile avatar circle with `Color.accent.opacity(0.15)` background and `Color.accent` text. Change to `Color.textTertiary.opacity(0.1)` background and `Color.textSecondary` text.

- [ ] **Step 6: Inject workoutActive environment in MainTabsView**

In `MainTabsView`, add `.environment(\.workoutActive, focusModeService.activeWorkout != nil)` to the TabView so child views can read the workout state.

- [ ] **Step 7: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(design): earned color — neutral tab bar, chips, avatar"
```

---

### Task 7: FloatingWorkoutBanner Refinements

**Files:**
- Modify: `Povver/Povver/UI/Shared/FloatingWorkoutBanner.swift`

- [ ] **Step 1: Read FloatingWorkoutBanner.swift**

- [ ] **Step 2: Replace inline shadow with token**

Replace `.shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)` with `.shadowStyle(ShadowsToken.level2)`.

- [ ] **Step 3: Add subtle breathing animation**

Add a `@State private var breatheScale: CGFloat = 1.0` and apply:
```swift
.scaleEffect(breatheScale)
.onAppear {
    withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
        breatheScale = 1.02
    }
}
```

Note: spec says 0.98→1.0 but 1.0→1.02 is equivalent and avoids starting below natural size.

- [ ] **Step 4: Show current exercise name instead of workout name**

The banner currently shows `workoutName`. If the parent view can pass the current exercise name, show that instead. Check what data the banner receives and whether `FocusModeWorkoutService` exposes the current exercise name. If it does, use it. If not, keep workout name for now and note the dependency.

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/Shared/FloatingWorkoutBanner.swift
git commit -m "feat(design): refine FloatingWorkoutBanner — shadow token, breathing animation"
```

---

## Tier 2: Data Services

### Task 8: Training Intelligence Models

**Files:**
- Create: `Povver/Povver/Models/TrainingIntelligence.swift`

- [ ] **Step 1: Read existing Firestore schema for field names**

Read `docs/FIRESTORE_SCHEMA.md` to understand the exact field names in `weekly_reviews`, `analysis_insights`, and `analytics_rollups` collections.

- [ ] **Step 2: Create Codable models**

```swift
import Foundation

// MARK: - Weekly Review (from weekly_reviews/{YYYY-WNN})

struct WeeklyReview: Codable {
    let weekId: String
    let trainingLoad: TrainingLoad?
    let fatigueStatus: FatigueStatus?
    let summary: String?

    struct TrainingLoad: Codable {
        let acwr: Double?
        let vsLastWeek: String?

        enum CodingKeys: String, CodingKey {
            case acwr
            case vsLastWeek = "vs_last_week"
        }
    }

    struct FatigueStatus: Codable {
        let overallAcwr: Double?
        let interpretation: String? // "optimal", "building", "overreaching", "detraining"
        let flags: [String]?

        enum CodingKeys: String, CodingKey {
            case overallAcwr = "overall_acwr"
            case interpretation
            case flags
        }
    }

    enum CodingKeys: String, CodingKey {
        case weekId = "week_id"
        case trainingLoad = "training_load"
        case fatigueStatus = "fatigue_status"
        case summary
    }
}

// MARK: - Analysis Insight (from analysis_insights/{id})

struct AnalysisInsight: Codable, Identifiable {
    let id: String?
    let workoutId: String?
    let summary: String?
    let highlights: [Highlight]?
    let createdAt: Date?

    struct Highlight: Codable {
        let type: String // "pr", "volume_up", etc.
        let message: String?
        let exerciseName: String?
        let value: Double?
        let previousValue: Double?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workoutId = "workout_id"
        case summary
        case highlights
        case createdAt = "created_at"
    }
}

// MARK: - Analytics Rollup (from analytics_rollups/{weekId})

struct AnalyticsRollup: Codable {
    let weekId: String
    let workouts: Int
    let totalSets: Int?
    let totalVolume: Double?

    enum CodingKeys: String, CodingKey {
        case weekId = "week_id"
        case workouts
        case totalSets = "total_sets"
        case totalVolume = "total_volume"
    }
}

// MARK: - Composed Types for View Consumption

struct TrainingSnapshot {
    let currentACWR: Double?
    let acwrInterpretation: String?
    let latestInsight: AnalysisInsight?
    let latestWeeklyReview: WeeklyReview?
    let weeklyWorkoutCounts: [WeekWorkoutCount]
}

struct WeekWorkoutCount: Identifiable {
    let weekId: String
    let scheduledCount: Int
    let completedCount: Int
    var id: String { weekId }
}

struct PostWorkoutSummary {
    let highlights: [AnalysisInsight.Highlight]
    let coachReflection: String?
}

struct Milestone: Identifiable {
    let id: String
    let type: MilestoneType
    let message: String
    let value: Int

    enum MilestoneType: String {
        case workoutCount
        case volumeMilestone
    }
}
```

Adjust field names based on what the Firestore schema doc actually shows — the above is a best-effort mapping from the explorer analysis. Read the schema doc first and verify.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Models/TrainingIntelligence.swift
git commit -m "feat(data): add Codable models for training intelligence (WeeklyReview, AnalysisInsight, AnalyticsRollup)"
```

---

### Task 9: TrainingDataService

**Files:**
- Create: `Povver/Povver/Services/TrainingDataService.swift`

- [ ] **Step 1: Read existing repository patterns**

Read `Povver/Povver/Repositories/WorkoutRepository.swift` to understand how existing code reads from Firestore — the collection paths, auth pattern, and Codable decoding.

- [ ] **Step 2: Create TrainingDataService**

Follow the existing singleton `ObservableObject` pattern. The service reads from Firestore collections that already exist and are populated by the Training Analyst backend.

```swift
import Foundation
import FirebaseFirestore
import FirebaseAuth

/// Reads pre-computed training intelligence from Firestore.
/// All analytical data (ACWR, PRs, insights) is computed by the Training Analyst backend.
/// This service is a read/cache layer, not a computation layer.
class TrainingDataService: ObservableObject {
    static let shared = TrainingDataService()

    private let db = Firestore.firestore()
    private var cachedSnapshot: TrainingSnapshot?
    private var snapshotTimestamp: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    private init() {}

    // MARK: - Training Snapshot (for Coach tab)

    func fetchTrainingSnapshot() async throws -> TrainingSnapshot {
        if let cached = cachedSnapshot,
           let ts = snapshotTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "TrainingDataService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let userRef = db.collection("users").document(userId)

        // Fetch last 12 weeks of rollups for Consistency Map
        let rollups = try await fetchRollups(userRef: userRef, weeks: 12)

        // Fetch latest weekly review for ACWR
        let latestReview = try await fetchLatestWeeklyReview(userRef: userRef)

        // Fetch latest analysis insight
        let latestInsight = try await fetchLatestInsight(userRef: userRef)

        let weeklyWorkoutCounts = rollups.map { rollup in
            WeekWorkoutCount(
                weekId: rollup.weekId,
                scheduledCount: 0, // Filled by CoachTabViewModel from routine schedule
                completedCount: rollup.workouts
            )
        }

        let snapshot = TrainingSnapshot(
            currentACWR: latestReview?.fatigueStatus?.overallAcwr ?? latestReview?.trainingLoad?.acwr,
            acwrInterpretation: latestReview?.fatigueStatus?.interpretation,
            latestInsight: latestInsight,
            latestWeeklyReview: latestReview,
            weeklyWorkoutCounts: weeklyWorkoutCounts
        )

        cachedSnapshot = snapshot
        snapshotTimestamp = Date()
        return snapshot
    }

    // MARK: - Post-Workout Summary

    func fetchPostWorkoutSummary(workoutId: String) async throws -> PostWorkoutSummary? {
        guard let userId = Auth.auth().currentUser?.uid else { return nil }

        let userRef = db.collection("users").document(userId)
        let snapshot = try await userRef.collection("analysis_insights")
            .whereField("workout_id", isEqualTo: workoutId)
            .limit(to: 1)
            .getDocuments()

        guard let doc = snapshot.documents.first,
              let insight = try? doc.data(as: AnalysisInsight.self) else {
            return nil
        }

        return PostWorkoutSummary(
            highlights: insight.highlights ?? [],
            coachReflection: insight.summary
        )
    }

    // MARK: - Milestones

    func checkMilestones(workoutCount: Int) -> [Milestone] {
        let thresholds = [10, 25, 50, 100, 250, 500, 1000]
        let acknowledged = UserDefaults.standard.array(forKey: "acknowledgedMilestones") as? [String] ?? []

        return thresholds.compactMap { threshold in
            guard workoutCount >= threshold else { return nil }
            let id = "workout_count_\(threshold)"
            guard !acknowledged.contains(id) else { return nil }
            return Milestone(
                id: id,
                type: .workoutCount,
                message: "\(threshold) workouts completed. Consistency is the hardest exercise — you're doing it.",
                value: threshold
            )
        }
    }

    func acknowledgeMilestone(_ milestone: Milestone) {
        var acknowledged = UserDefaults.standard.array(forKey: "acknowledgedMilestones") as? [String] ?? []
        acknowledged.append(milestone.id)
        UserDefaults.standard.set(acknowledged, forKey: "acknowledgedMilestones")
    }

    /// Invalidate cache (call after workout completion)
    func invalidateCache() {
        cachedSnapshot = nil
        snapshotTimestamp = nil
    }

    // MARK: - Private Helpers

    private func fetchRollups(userRef: DocumentReference, weeks: Int) async throws -> [AnalyticsRollup] {
        let snapshot = try await userRef.collection("analytics_rollups")
            .order(by: "week_id", descending: true)
            .limit(to: weeks)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            try? doc.data(as: AnalyticsRollup.self)
        }.reversed() // Chronological order (oldest first)
    }

    private func fetchLatestWeeklyReview(userRef: DocumentReference) async throws -> WeeklyReview? {
        let snapshot = try await userRef.collection("weekly_reviews")
            .order(by: "week_id", descending: true)
            .limit(to: 1)
            .getDocuments()

        return snapshot.documents.first.flatMap { try? $0.data(as: WeeklyReview.self) }
    }

    private func fetchLatestInsight(userRef: DocumentReference) async throws -> AnalysisInsight? {
        let snapshot = try await userRef.collection("analysis_insights")
            .order(by: "created_at", descending: true)
            .limit(to: 1)
            .getDocuments()

        return snapshot.documents.first.flatMap { try? $0.data(as: AnalysisInsight.self) }
    }
}
```

Important: Verify the exact Firestore collection paths by reading the schema doc. The sub-collection path (`users/{uid}/analytics_rollups` vs top-level `analytics_rollups`) must match the backend.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Services/TrainingDataService.swift
git commit -m "feat(data): add TrainingDataService — reads pre-computed training intelligence from Firestore"
```

---

### Task 10: CoachTabViewModel

**Files:**
- Create: `Povver/Povver/ViewModels/CoachTabViewModel.swift`

- [ ] **Step 1: Read existing CoachTabView.swift to understand current state/data flow**

Understand what data the Coach tab currently uses, how conversations are loaded, and what services it depends on.

- [ ] **Step 2: Read Routine.swift model**

Understand the `lastCompletedAt`, `lastCompletedTemplateId`, `templateIds` fields — these drive the state machine.

- [ ] **Step 3: Create CoachTabViewModel**

```swift
import SwiftUI
import FirebaseAuth

enum CoachState: Equatable {
    case loading
    case newUser
    case workoutDay(WorkoutDayContext)
    case restDay(RestDayContext)
    case postWorkout(PostWorkoutContext)
    case returningAfterInactivity(InactivityContext)

    static func == (lhs: CoachState, rhs: CoachState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.newUser, .newUser): return true
        case (.workoutDay, .workoutDay), (.restDay, .restDay): return true
        case (.postWorkout, .postWorkout), (.returningAfterInactivity, .returningAfterInactivity): return true
        default: return false
        }
    }
}

struct WorkoutDayContext {
    let scheduledWorkoutName: String
    let dayLabel: String // "Day 3 of 4"
    let trainingLoadStatus: String? // "Optimal", "Building", etc.
    let snapshot: TrainingSnapshot
    let greeting: String
}

struct RestDayContext {
    let insight: String? // From weekly review or latest insight
    let snapshot: TrainingSnapshot
    let greeting: String
}

struct PostWorkoutContext {
    let workoutName: String
    let exerciseCount: Int
    let setCount: Int
    let totalVolume: Double
    let highlights: [AnalysisInsight.Highlight]
    let snapshot: TrainingSnapshot
}

struct InactivityContext {
    let lastWorkoutDate: Date
    let lastWorkoutName: String
    let nextWorkoutName: String?
    let snapshot: TrainingSnapshot
}

@MainActor
class CoachTabViewModel: ObservableObject {
    @Published var state: CoachState = .loading
    @Published var pendingMilestones: [Milestone] = []

    private let trainingService = TrainingDataService.shared
    private let workoutService = FocusModeWorkoutService.shared

    func load() async {
        // 1. Check for post-workout flag
        if let postWorkoutData = loadPostWorkoutFlag() {
            let snapshot = (try? await trainingService.fetchTrainingSnapshot()) ?? emptySnapshot
            let summary = try? await trainingService.fetchPostWorkoutSummary(workoutId: postWorkoutData.workoutId)
            state = .postWorkout(PostWorkoutContext(
                workoutName: postWorkoutData.name,
                exerciseCount: postWorkoutData.exerciseCount,
                setCount: postWorkoutData.setCount,
                totalVolume: postWorkoutData.totalVolume,
                highlights: summary?.highlights ?? [],
                snapshot: snapshot
            ))
            return
        }

        // 2. Check if new user
        guard let userId = Auth.auth().currentUser?.uid else {
            state = .newUser
            return
        }

        let workoutCount = await fetchWorkoutCount(userId: userId)
        let activeRoutine = await fetchActiveRoutine(userId: userId)

        if activeRoutine == nil && workoutCount == 0 {
            state = .newUser
            return
        }

        // 3. Load training snapshot
        let snapshot = (try? await trainingService.fetchTrainingSnapshot()) ?? emptySnapshot

        // 4. Check milestones
        pendingMilestones = trainingService.checkMilestones(workoutCount: workoutCount)

        // 5. Check for inactivity (7+ days)
        if let routine = activeRoutine,
           let lastCompleted = routine.lastCompletedAt,
           Calendar.current.dateComponents([.day], from: lastCompleted, to: Date()).day ?? 0 >= 7 {
            state = .returningAfterInactivity(InactivityContext(
                lastWorkoutDate: lastCompleted,
                lastWorkoutName: "", // Would need last workout name — fetch if needed
                nextWorkoutName: nil, // From getNextWorkout
                snapshot: snapshot
            ))
            return
        }

        // 6. Determine workout day vs rest day
        // This requires knowing the routine schedule — simplified here.
        // A more robust implementation would call getNextWorkout to determine if today is a scheduled day.
        let greeting = timeAwareGreeting()

        // For now, default to workout day if routine exists, rest day otherwise.
        // The getNextWorkout endpoint call should be added to properly distinguish.
        if activeRoutine != nil {
            state = .workoutDay(WorkoutDayContext(
                scheduledWorkoutName: "Next Session", // Replace with actual from getNextWorkout
                dayLabel: "",
                trainingLoadStatus: snapshot.acwrInterpretation?.capitalized,
                snapshot: snapshot,
                greeting: greeting
            ))
        } else {
            state = .restDay(RestDayContext(
                insight: snapshot.latestWeeklyReview?.summary ?? snapshot.latestInsight?.summary,
                snapshot: snapshot,
                greeting: greeting
            ))
        }
    }

    // MARK: - Helpers

    private func timeAwareGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Afternoon session? Let's go"
        case 17..<22: return "Evening session — let's finish the day strong"
        default: return "Late session tonight. Let's make it count"
        }
    }

    private var emptySnapshot: TrainingSnapshot {
        TrainingSnapshot(currentACWR: nil, acwrInterpretation: nil, latestInsight: nil, latestWeeklyReview: nil, weeklyWorkoutCounts: [])
    }

    private func loadPostWorkoutFlag() -> PostWorkoutFlag? {
        guard let data = UserDefaults.standard.data(forKey: "postWorkoutFlag"),
              let flag = try? JSONDecoder().decode(PostWorkoutFlag.self, from: data),
              Date().timeIntervalSince(flag.timestamp) < 14400 // 4 hours
        else {
            return nil
        }
        return flag
    }

    static func setPostWorkoutFlag(workoutId: String, name: String, exerciseCount: Int, setCount: Int, totalVolume: Double) {
        let flag = PostWorkoutFlag(workoutId: workoutId, name: name, exerciseCount: exerciseCount, setCount: setCount, totalVolume: totalVolume, timestamp: Date())
        if let data = try? JSONEncoder().encode(flag) {
            UserDefaults.standard.set(data, forKey: "postWorkoutFlag")
        }
    }

    static func clearPostWorkoutFlag() {
        UserDefaults.standard.removeObject(forKey: "postWorkoutFlag")
    }

    private func fetchWorkoutCount(userId: String) async -> Int {
        // Use existing WorkoutRepository pattern
        // This is a simplified version — adapt to use the actual repository
        return 0 // Placeholder — wire to WorkoutRepository.getWorkoutCount()
    }

    private func fetchActiveRoutine(userId: String) async -> Routine? {
        // Read from user doc's activeRoutineId, then fetch routine
        // Adapt to existing patterns
        return nil // Placeholder — wire to existing routine fetch
    }
}

struct PostWorkoutFlag: Codable {
    let workoutId: String
    let name: String
    let exerciseCount: Int
    let setCount: Int
    let totalVolume: Double
    let timestamp: Date
}
```

Important: The `fetchWorkoutCount` and `fetchActiveRoutine` methods are placeholders. During implementation, wire these to the actual existing repositories (`WorkoutRepository`, user doc read). Read the existing code paths in `CoachTabView.swift` and `FocusModeWorkoutService.swift` to understand how routine/workout data is currently accessed.

The `getNextWorkout` integration (to properly distinguish workout day vs rest day and get the actual scheduled workout name) should call the existing Firebase Function via `CloudFunctionService`. Read how other views call Cloud Functions to follow the pattern.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/ViewModels/CoachTabViewModel.swift
git commit -m "feat(data): add CoachTabViewModel with state machine for dynamic Coach tab"
```

---

## Tier 3: Screen Redesigns

### Task 11: Coach Presence Indicator Component

**Files:**
- Create: `Povver/Povver/UI/Components/CoachPresenceIndicator.swift`

- [ ] **Step 1: Read OnboardingGlowLayer.swift for reference**

Read `Povver/Povver/UI/Components/OnboardingGlowLayer.swift` to understand the existing breathing glow pattern used in onboarding.

- [ ] **Step 2: Create CoachPresenceIndicator**

A smaller, scoped version of the onboarding glow. Breathing emerald radial pulse behind a sparkles icon.

```swift
import SwiftUI

struct CoachPresenceIndicator: View {
    var size: CGFloat = 40
    var isThinking: Bool = false

    @State private var breathePhase: CGFloat = 0

    private var cycleDuration: Double { isThinking ? 2.0 : 8.0 }
    private var glowIntensity: Double { isThinking ? 0.2 : 0.12 }

    var body: some View {
        ZStack {
            // Breathing glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.accent.opacity(glowIntensity), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.8
                    )
                )
                .frame(width: size * 1.6, height: size * 1.6)
                .scaleEffect(1.0 + breathePhase * 0.05)

            // Icon container
            Circle()
                .fill(Color.accent.opacity(0.1))
                .frame(width: size, height: size)

            // Sparkles icon
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundColor(Color.accent)

            // Breathing ring
            Circle()
                .stroke(Color.accent.opacity(0.3 + breathePhase * 0.1), lineWidth: 1.5)
                .frame(width: size + 4, height: size + 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: cycleDuration).repeatForever(autoreverses: true)) {
                breathePhase = 1.0
            }
        }
        .onChange(of: isThinking) { _, newValue in
            breathePhase = 0
            withAnimation(.easeInOut(duration: newValue ? 2.0 : 8.0).repeatForever(autoreverses: true)) {
                breathePhase = 1.0
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/Components/CoachPresenceIndicator.swift
git commit -m "feat(ui): add CoachPresenceIndicator — breathing emerald glow component"
```

---

### Task 12: Training Consistency Map Component

**Files:**
- Create: `Povver/Povver/UI/Components/TrainingConsistencyMap.swift`

- [ ] **Step 1: Create TrainingConsistencyMap**

```swift
import SwiftUI

/// Povver's signature visual — 12-week training consistency grid.
/// Emerald fills for completed sessions (earned color at scale).
struct TrainingConsistencyMap: View {
    let weeks: [WeekWorkoutCount]
    let routineFrequency: Int // Sessions per week (e.g., 4 for a 4-day program)
    var animateLatest: Bool = false

    @State private var latestFilled = false

    private let cellSize: CGFloat = 8
    private let cellSpacing: CGFloat = 3

    var body: some View {
        HStack(spacing: cellSpacing) {
            ForEach(Array(paddedWeeks.enumerated()), id: \.offset) { weekIndex, week in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<routineFrequency, id: \.self) { dayIndex in
                        let isCompleted = dayIndex < week.completedCount
                        let isLatestCell = animateLatest && weekIndex == paddedWeeks.count - 1 && dayIndex == week.completedCount - 1

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellFill(completed: isCompleted && (!isLatestCell || latestFilled)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(cellStroke(completed: isCompleted), lineWidth: isCompleted ? 0 : 0.5)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .onAppear {
            if animateLatest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(MotionToken.bouncy) {
                        latestFilled = true
                    }
                    HapticManager.setCompleted()
                }
            }
        }
    }

    private var paddedWeeks: [WeekWorkoutCount] {
        // Ensure we always show 12 columns
        let target = 12
        if weeks.count >= target { return Array(weeks.suffix(target)) }
        let padding = (0..<(target - weeks.count)).map { i in
            WeekWorkoutCount(weekId: "pad_\(i)", scheduledCount: routineFrequency, completedCount: 0)
        }
        return padding + weeks
    }

    private func cellFill(completed: Bool) -> Color {
        completed ? Color.accent : Color.clear
    }

    private func cellStroke(completed: Bool) -> Color {
        completed ? Color.clear : Color.separatorLine
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/UI/Components/TrainingConsistencyMap.swift
git commit -m "feat(ui): add TrainingConsistencyMap — Povver's signature visual element"
```

---

### Task 13: TrendDelta Component

**Files:**
- Create: `Povver/Povver/UI/Components/TrendDelta.swift`

- [ ] **Step 1: Create TrendDelta**

```swift
import SwiftUI

/// Compact trend indicator: "+2.5 kg" in emerald or neutral.
struct TrendDelta: View {
    let value: Double
    let unit: String
    let format: String // e.g., "%.1f"

    var body: some View {
        let isPositive = value > 0
        let sign = isPositive ? "+" : ""
        let color: Color = isPositive ? .accent : .textTertiary

        Text("\(sign)\(String(format: format, value)) \(unit)")
            .textStyle(.micro)
            .foregroundColor(color)
            .monospacedDigit()
    }
}

/// PR badge — small emerald capsule.
struct PRBadge: View {
    var body: some View {
        Text("PR")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.textInverse)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accent)
            .clipShape(Capsule())
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/UI/Components/TrendDelta.swift
git commit -m "feat(ui): add TrendDelta and PRBadge components"
```

---

### Task 14: Coach Tab Redesign

**Files:**
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift`

This is the largest single task. The Coach tab is rewritten to use `CoachTabViewModel` and the new components.

- [ ] **Step 1: Read current CoachTabView.swift thoroughly**

Understand all current functionality: navigation, conversation launching, quick actions, recent chats, the `AllConversationsSheet`, initial conversation context handling.

- [ ] **Step 2: Read ConversationScreen.swift navigation pattern**

Understand how the Coach tab navigates to conversations — `@State navigateToConversation`, `.navigationDestination`, the delayed auto-navigation.

- [ ] **Step 3: Rewrite CoachTabView**

Key changes:
- Add `@StateObject private var viewModel = CoachTabViewModel()`
- Add `@State private var hasAppeared = false` for staggered entrance
- Remove the static "What's on the agenda today?" headline
- Replace the 2x2 `QuickActionCard` grid with a grouped list
- Add `CoachPresenceIndicator` to hero area
- Add `TrainingConsistencyMap` to hero area (for returning user states)
- Use `sectionLabel` for section headers
- Recent conversations become Tier 0 flat rows
- Call `viewModel.load()` in `.task {}` modifier
- Trigger `hasAppeared = true` in `.onAppear` after a brief delay

Preserve all existing functionality:
- Navigation to `ConversationScreen` via `.navigationDestination`
- `AllConversationsSheet` via `.sheet`
- `switchToTab` callback
- `initialConversationContext` handling

Structure the view with a `switch viewModel.state` that renders the appropriate hero, actions, and content for each state. Extract sub-views for each state to keep the file manageable.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 5: Test manually in simulator**

Run the app and verify:
- Coach tab renders without crash
- Navigation to conversations still works
- The hero shows (even if data is placeholder for now)
- Staggered entrance animation plays

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/Views/Tabs/CoachTabView.swift
git commit -m "feat(ui): redesign Coach tab — state-driven hero, consistency map, contextual actions"
```

---

### Task 15: Library Redesign

**Files:**
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift`

- [ ] **Step 1: Read current LibraryView.swift**

Understand the current structure — the 3 rows, the sub-views (RoutinesListView, TemplatesListView), and how data is loaded.

- [ ] **Step 2: Rewrite LibraryView**

Key changes:
- Replace header with `screenTitle` + contextual subtitle
- Add `sectionLabel` for section headers: "YOUR PROGRAM", "TEMPLATES", "EXERCISES"
- Active routine section: Tier 2 card with routine name + mini week strip (day indicators showing scheduled sessions). Requires reading the active routine and its template schedule.
- Templates section: show 3 most recent as Tier 1 cards with name + exercise count + muscle group tags. "See all" link.
- Exercises section: "Recently used" horizontal chip row (if history exists) + "Browse all exercises" row.
- Empty states with coach voice.
- Staggered entrance animations.

For the mini week strip in the routine hero, create a small private component within the file that renders day indicators.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Test manually in simulator**

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/Views/Tabs/LibraryView.swift
git commit -m "feat(ui): redesign Library — routine hero, template cards, exercise quick access"
```

---

### Task 16: History View Polish

**Files:**
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift`

- [ ] **Step 1: Read current HistoryView.swift**

- [ ] **Step 2: Apply design changes**

- Replace header font with `.textStyle(.screenTitle)` + `.textStyle(.secondary)` for subtitle
- Replace `DateHeaderView` text with `.textStyle(.sectionLabel)`
- In `WeeklyWorkoutChart`: change historical bar color from `Color.accent.opacity(0.35)` to `ColorsToken.n300` (light mode) / `ColorsToken.n600` (dark mode). Keep current week as `Color.accent`.
- Change "Load More" from a button to a `Text` link with `.textStyle(.secondary)` and `Color.textSecondary`
- Migrate any remaining raw `.font(.system(...))` calls to `.textStyle()` equivalents

PR badges on workout rows are deferred — they require wiring `analysis_insights` data into the history list, which is additional service work. Note as a follow-up.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Views/Tabs/HistoryView.swift
git commit -m "feat(ui): polish History — section labels, chart colors, typography tokens"
```

---

### Task 17: More View Polish

**Files:**
- Modify: `Povver/Povver/Views/Tabs/MoreView.swift`
- Modify: `Povver/Povver/UI/Components/ProfileComponents.swift` (if section label changes affect it)

- [ ] **Step 1: Read current MoreView.swift**

- [ ] **Step 2: Apply design changes**

- Replace `sectionHeader()` method to use `.textStyle(.sectionLabel)` (or refactor the method to use the token)
- Profile avatar: change `Color.accent.opacity(0.15)` to `Color.textTertiary.opacity(0.1)`, initials from `Color.accent` to `Color.textSecondary`
- Sign out button: remove `Color.surface` background and card shape. Replace with a simple `Button` with `.textStyle(.secondary)` and `Color.destructive` foreground.
- Migrate raw font sizes (17, 13, 12, 15, 16, 18, 20pt) to `.textStyle()` equivalents where possible
- Read `ProfileComponents.swift` for `ProfileRowLinkContent` — migrate its fonts too

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Views/Tabs/MoreView.swift Povver/Povver/UI/Components/ProfileComponents.swift
git commit -m "feat(ui): polish More — section labels, neutral avatar, typography tokens"
```

---

### Task 18: Workout Mode Visual Shift

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift`

- [ ] **Step 1: Read FocusModeWorkoutScreen.swift**

Understand the current background color, exercise card rendering, header structure.

- [ ] **Step 2: Apply workout mode background tint**

Change `Color.bg` background on the main content area to `Color.bgWorkout` when a workout is active. The `bgWorkout` color was added in Task 1.

- [ ] **Step 3: Apply card tier hierarchy to exercises**

In the exercise card rendering:
- Active exercise (the one being edited/focused): wrap in a Tier 2 treatment — `surfaceElevated` background, `level1` shadow, `radiusCard` corner radius.
- Completed exercises: Tier 0 (flat, no card) + thin emerald left-edge indicator (3pt wide `Color.accent` rectangle with `radiusIcon` corners).
- Upcoming exercises: Tier 0, title in `textSecondary` instead of `textPrimary`.

- [ ] **Step 4: Add coach presence dot to header**

On the coach (sparkles) button in the header, overlay a tiny emerald dot:
```swift
.overlay(alignment: .topTrailing) {
    Circle()
        .fill(Color.accent)
        .frame(width: 6, height: 6)
        .offset(x: 2, y: -2)
}
```

- [ ] **Step 5: Apply monospaced digits to set grid**

In `FocusModeSetGrid.swift`, ensure all numeric displays (weight, reps, RIR values) use `.monospacedDigit()`.

- [ ] **Step 6: Add set completion haptic**

In the set completion handler (where the checkmark is tapped), add `HapticManager.setCompleted()`.

- [ ] **Step 7: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 8: Commit**

```bash
git add Povver/Povver/UI/FocusMode/
git commit -m "feat(ui): workout mode — tinted bg, card tiers, coach dot, monospaced digits, haptics"
```

---

### Task 19: Post-Workout Completion Summary Redesign

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift`

- [ ] **Step 1: Read FocusModeWorkoutHelpers.swift**

Find the `WorkoutCompletionSummary` view (around line 24). Understand its current structure, what data it receives, and how it's presented (fullScreenCover).

- [ ] **Step 2: Redesign with sequenced reveal**

Rewrite `WorkoutCompletionSummary` with:
- `@State private var revealPhase = 0` — drives the sequenced reveal
- On appear, increment `revealPhase` with staggered delays using `DispatchQueue.main.asyncAfter`

Sequence:
1. `CoachPresenceIndicator` at top (phase 0 — immediate)
2. "Session Complete" headline + workout name (phase 1 — +0.1s)
3. Core metrics row: duration, volume, sets as stacked metric blocks with `metricL` numbers (phase 2 — +0.3s)
4. Consistency Map (phase 3 — +0.5s) — with `animateLatest: true` if this is the current day's fill
5. Exercise breakdown below (phase 4 — +0.7s, below the fold)
6. "Done" button at bottom

Each element uses opacity + offset, gated by `revealPhase >= N`.

PR highlights: attempt to load from `TrainingDataService.fetchPostWorkoutSummary(workoutId:)`. If available, show highlight cards between the metrics and the consistency map with `bouncy` spring. If not yet available (async processing), skip gracefully.

Add `HapticManager.workoutCompleted()` when the summary appears.

Set the post-workout flag via `CoachTabViewModel.setPostWorkoutFlag(...)` so the Coach tab shows the post-workout state.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Test manually**

Complete a workout in the simulator and verify the completion summary displays with the sequenced reveal.

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift
git commit -m "feat(ui): redesign WorkoutCompletionSummary — sequenced reveal, metrics, consistency map"
```

---

## Tier 4: Personality & Polish

### Task 20: Empty States with Coach Voice

**Files:**
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift` (empty states in RoutinesListView, TemplatesListView)
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift` (empty state)
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift` (empty conversations)

- [ ] **Step 1: Search for EmptyState usage across tab views**

Use Grep to find all `EmptyState(` calls in the Views/Tabs directory.

- [ ] **Step 2: Replace generic copy with coach-voiced copy**

For each empty state:
- No routines: "No programs yet — want me to design one for you?"
- No templates: "No templates yet — create one or ask your coach."
- No history: "Your training story starts with the first session."
- No conversations: "Ask me anything about your training."

Use the `CoachPresenceIndicator(size: 32)` as the icon instead of the generic SF Symbol where appropriate.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ui): coach-voiced empty states across all tabs"
```

---

### Task 21: Screen Entrance Animations

**Files:**
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift` (if not already done in Task 14)
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift`
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift`
- Modify: `Povver/Povver/Views/Tabs/MoreView.swift`

- [ ] **Step 1: Add staggered entrance to each tab view**

For each tab view that doesn't already have it:

Add `@State private var hasAppeared = false` and in `.onAppear`:
```swift
.onAppear {
    if !hasAppeared {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            hasAppeared = true
        }
    }
}
```

Then apply `.staggeredEntrance(index: N, active: hasAppeared)` to each major content block (header, sections, lists).

Skip this for the Train tab — workout mode disables staggered reveals.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 3: Test by switching between tabs in the simulator**

Verify animations play on first tab selection, don't re-play when returning from detail views.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ui): staggered entrance animations on all main tabs"
```

---

### Task 22: Remaining Typography Migration Sweep

**Files:**
- Any files still using raw `.font(.system(size:weight:))` in the Views/Tabs/ and UI/FocusMode/ directories

- [ ] **Step 1: Grep for remaining raw font usage**

```bash
grep -rn "\.font(\.system(size:" Povver/Povver/Views/Tabs/ Povver/Povver/UI/FocusMode/ Povver/Povver/UI/Components/ Povver/Povver/UI/Shared/
```

- [ ] **Step 2: Migrate each to design token equivalent**

For each raw font usage, determine the closest `TextStyle` case:
- 28pt bold → `.screenTitle` (22pt semi — may need adjustment) or keep as `metricL` (28pt) if it's a metric
- 17pt semibold → `.bodyStrong` or `.sectionHeader`
- 17pt regular → `.body`
- 15pt regular → `.secondary`
- 13pt regular → `.caption`
- 12pt regular → `.micro`
- 14pt → `.caption` or `.secondary` depending on weight
- 11pt → `.sectionLabel` (if uppercased) or `.micro`

Replace with `.textStyle(.X)`. If the size doesn't match exactly and the difference matters visually, note it — the token may need a value adjustment.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(design): complete typography migration to design tokens"
```

---

### Task 23: Documentation Update

**Files:**
- Modify: `docs/IOS_ARCHITECTURE.md`
- Create or modify: `Povver/Povver/UI/DesignSystem/ARCHITECTURE.md`

- [ ] **Step 1: Read current docs**

Read `docs/IOS_ARCHITECTURE.md` and any existing `ARCHITECTURE.md` in the UI/DesignSystem directory.

- [ ] **Step 2: Update iOS architecture doc**

Add/update sections covering:
- The card tier system (Tier 0/1/2)
- Earned color principle
- Motion context (browsing vs workout vs celebration)
- New services: `TrainingDataService`, `CoachTabViewModel`
- The `workoutActive` environment value

- [ ] **Step 3: Update design system ARCHITECTURE.md**

Document:
- Typography: `TextStyle` enum is the single source of truth. `PovverTextStyle` is deprecated.
- Corner radius: `radiusCard`/`radiusControl`/`radiusIcon`/`pill` — the full set
- Spring presets: `snappy`/`gentle`/`bouncy`
- Haptics: use `HapticManager`, not direct UIKit calls
- Color philosophy: earned emerald

- [ ] **Step 4: Commit**

```bash
git add docs/ Povver/Povver/UI/DesignSystem/ARCHITECTURE.md
git commit -m "docs: update architecture docs for visual evolution design system"
```

---

## Dependency Graph

```
Task 1 (Tokens) ──┬── Task 4 (Corner radius migration)
                   ├── Task 6 (Color adjustments)
                   ├── Task 7 (Banner refinements)
                   ├── Task 18 (Workout mode)
                   └── Task 21 (Entrance animations)

Task 2 (HapticManager) ── Task 18 (Workout mode haptics)
                       └── Task 19 (Completion summary haptics)

Task 3 (StaggeredEntrance) ── Task 21 (Entrance animations)

Task 5 (Typography deprecation) ── Task 22 (Migration sweep)

Task 8 (Models) ── Task 9 (TrainingDataService)
                └── Task 10 (CoachTabViewModel)

Task 9 (TrainingDataService) ── Task 10 (CoachTabViewModel)
                             └── Task 19 (Completion summary)

Task 10 (CoachTabViewModel) ── Task 14 (Coach tab redesign)

Task 11 (CoachPresence) ── Task 14 (Coach tab redesign)
                        └── Task 19 (Completion summary)

Task 12 (ConsistencyMap) ── Task 14 (Coach tab redesign)
                         └── Task 19 (Completion summary)

Task 13 (TrendDelta) ── Task 16 (History polish)

Tasks 14-19 (Screen redesigns) ── Task 20 (Empty states)
                                └── Task 21 (Entrance animations)

All tasks ── Task 23 (Documentation)
```

Tasks that can be parallelized:
- Tasks 1, 2, 3 (foundation components — no dependencies on each other)
- Tasks 8, 11, 12, 13 (new components/models — no dependencies on each other, only on Task 1)
- Tasks 15, 16, 17 (Library/History/More — independent screens, depend on Tasks 1, 4, 5)
