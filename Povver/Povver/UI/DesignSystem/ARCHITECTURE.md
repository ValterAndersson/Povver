# Design System Architecture

> The visual foundation for the Povver iOS app. All UI should consume tokens, not hard-coded values.

## Typography

**Single source of truth:** `TextStyle` enum with `.textStyle()` view modifier.

| Style | Size/Weight | Usage |
|-------|------------|-------|
| `.appTitle` | 34pt semibold | Coach landing headline only |
| `.screenTitle` | 22pt semibold | Screen headings |
| `.sectionHeader` | 17pt semibold | Section headers |
| `.body` | 17pt regular | Body text |
| `.bodyStrong` | 17pt semibold | Emphasized body |
| `.secondary` | 15pt regular | Secondary text |
| `.caption` | 13pt regular | Captions |
| `.micro` | 12pt regular | Smallest text |
| `.sectionLabel` | 11pt semibold uppercase tracking:1 | Whoop-style section labels |
| `.metricL/M/S` | 28/22/17pt semibold monospaced | Numeric displays |

**Deprecated:** `PovverTextStyle` enum and `PovverText` struct. Use `Text("...").textStyle(.body)` instead.

## Corner Radius

| Token | Value | Usage |
|-------|-------|-------|
| `radiusCard` | 16pt | Card containers |
| `radiusControl` | 12pt | Buttons, inputs, controls |
| `radiusIcon` | 10pt | Icon containers, small badges |
| `pill` | 999pt | Capsule shapes |

**Deprecated:** `small`, `medium`, `large`, `card` — all mapped to v1.1 tokens with deprecation annotations.

## Color Philosophy: Earned Color

Emerald accent (`Color.accent`) is reserved for:
- Progress indicators and achievements
- Primary CTAs (start workout, confirm action)
- Coach presence (breathing glow)
- Active/completed states

Everything else uses neutrals: `textPrimary`, `textSecondary`, `textTertiary`, `surface`, `surfaceElevated`.

## Card Hierarchy

| Tier | Background | Border | Shadow | Usage |
|------|-----------|--------|--------|-------|
| 0 | None (on bg) | None | None | List rows, flat content |
| 1 | `surface` | `Stroke.card` hairline | `level1` | Standard cards |
| 2 | `surfaceElevated` | `Stroke.cardActive` | `level2` | Active/hero cards |

## Motion

| Preset | Response | Damping | Usage |
|--------|----------|---------|-------|
| `snappy` | 0.3s | 0.7 | Workout mode, press states |
| `gentle` | 0.5s | 0.8 | Screen entrances, browsing |
| `bouncy` | 0.4s | 0.6 | Celebrations, achievements |

## Key Components

- **CoachPresenceIndicator** — Breathing emerald glow (8s normal, 2s thinking). Represents AI coach presence.
- **TrainingConsistencyMap** — 12-week grid of workout completion. Emerald fills for completed sessions.
- **StaggeredEntrance** — `.staggeredEntrance(index: N, active: hasAppeared)` for sequential fade+slide reveals.
- **HapticManager** — `@MainActor enum`. Centralized haptic feedback for set completion, PRs, milestones. All methods are main-actor-isolated. Includes rapid succession guard (200ms per category) and scroll suppression.

## Task Lifecycle

All view-launched async work must be stored in `@State` properties and cancelled in `.onDisappear`. Use `Task.sleep(for:)` with `Task.isCancelled` guards instead of `DispatchQueue.main.asyncAfter` — GCD closures are not cancellable and can modify state on deallocated views.

Key components following this pattern: `PovverButton` (actionTask, loadingTask), `SetCompletionCircle` (animationTask), `SetCompletionRowFlash` (flashTask), `UndoToast` (dismissTask).

## Environment Values

- `workoutActive: Bool` — Injected by `MainTabsView`, read by child views to adapt behavior (e.g., snappier animations, deeper background).
- `buttonHapticStyle: ButtonHapticStyle?` — Override default haptic style for descendant `PovverButton`s.
