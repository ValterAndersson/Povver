# Povver Input Interaction System — Design Spec

**Goal:** Define a unified interaction system that makes every input in Povver feel purpose-built for the device — tactile, immediate, and forgiving. The system covers button states, haptic policy, motion language, error communication, destructive action tiers, input anticipation, and the workout flow state.

**Scope:** iOS app only. All SwiftUI views, all reusable components in the design system, all screen-level interactions.

**Principles:** This is an instrument, not an interface. The app should feel like an extension of the workout, not a screen between the user and the workout.

---

## 1. Platform Contract

Every decision in this spec passes through these five principles. If an implementation satisfies the component rules but violates a principle, the principle wins.

### 1.1 Obey the device, then extend it

Use system springs (`.spring()`, `.snappy`, `.bouncy`), system gestures (swipe-back, pull-to-dismiss, long-press context menus), and system scroll physics. Never replace them. When we add to them — a haptic at a swipe threshold, an emerald flash on completion — it should feel like the phone learned a new trick, not like the app is fighting the phone.

**Rule:** No hardcoded spring damping/response values. Reference SwiftUI's named presets. When Apple refines them, Povver refines with them.

### 1.2 Direct manipulation over indirect control

Where a user can grab, drag, or physically manipulate a value instead of typing into a field, prefer the physical interaction. A swipe should delete — not tap edit, tap red circle, tap delete.

**Rule:** Any interaction requiring 3+ taps to accomplish what a single gesture could do is a design failure.

### 1.3 Contextual density

Show less when the user is in motion. Show more when they're stationary. During a workout, the active exercise is large, generous, forgiving. Completed exercises compress to summaries. Upcoming exercises recede. In Library or History, where the user browses at rest, density increases.

**Rule:** Touch targets in workout mode are minimum 48pt. Everywhere else, minimum 44pt (Apple HIG baseline).

### 1.4 The app is never empty

Every state — loading, empty, error — is a designed state with a clear forward path. Loading isn't a spinner in a void; it's the destination view at rest, waiting. Empty isn't "no data"; it's an invitation. Error isn't a red message; it's a conversation about what to do next.

**Rule:** No view may show a centered `ProgressView()` as its only content. Every loading state must have structural context — navigation chrome, section headers, or at minimum a message about what's coming.

### 1.5 Accessibility is structure, not decoration

Dynamic Type, Reduce Motion, Bold Text, Increased Contrast, VoiceOver — these are structural requirements. Every text element uses design tokens that map to Dynamic Type scales. Every spring animation has a Reduce Motion fallback. Every interactive element has an accessibility label.

**Rule:** If Reduce Motion is enabled, all spring/transform animations become 0.2s cross-fades. Haptics remain — they're the primary feedback channel when motion is reduced.

---

## 2. Sensory Language

Haptics and motion are one system, not two. Every meaningful moment has a **sensory signature**: the animation and the haptic are choreographed together, landing at the same instant.

### 2.1 The Five Motion Intents

Every animation maps to exactly one intent. No ambiguity, no per-screen decisions.

| Intent | Motion | Haptic | When |
|--------|--------|--------|------|
| **Respond** | Scale to 0.97, immediate, releases on finger-up | Light impact (primary/destructive) or none (secondary/ghost) | User tapped something. Acknowledge before anything else. |
| **Reveal** | Opacity 0→1 + 8pt vertical shift, ease-in, `MotionToken.medium` | None | New content appears — data loaded, section expanded, view pushed. |
| **Transform** | System spring (`.snappy`), element morphs shape/size/state | Matched to significance: selection tick (small), medium impact (mode change), success notification (completion) | An element changes what it is — button to loading state, card expanding, mode switching. |
| **Exit** | Opacity 1→0 + slide toward origin, ease-out, `MotionToken.fast` | None (unless destructive: warning notification) | Content leaving — set deleted, filter removed, sheet dismissed. Exits are faster than reveals. |
| **Reflow** | Position-only ease-in-out, `MotionToken.medium` | None | Surrounding content adjusts to a layout change. Rows shifting after deletion, sections reordering. Never bouncy. |

### 2.2 Sensory Signatures for Key Moments

**Set completed:**
Done circle fills emerald from center outward (radial fill, 0.15s). Pulse scale 1.0 → 1.15 → 1.0 (system `.bouncy` spring). Light impact haptic at pulse peak (1.15). Checkmark strokes in during settle (0.2s). Row background emerald flash fades over 0.3s. Total ~0.5s.

**Exercise completed (all sets done):**
Final set signature fires first. Then: emerald left-edge indicator slides in (Reveal). Card compresses to completed density (Transform, `.snappy`). Medium impact haptic on compression. Next exercise expands to active density. Total ~0.7s from final set tap.

**Workout completed:**
Final exercise signature fires. Then: 0.5s held beat of stillness. Success notification haptic. Transition to completion summary. Summary reveals in staggered phases (0.0s/0.2s/0.4s/0.6s/0.8s) — duration, volume, PRs, consistency map, coach reflection. Each phase uses Reveal.

**Destructive confirm (Tier 3):**
After user confirms in dialog: warning notification haptic. Affected content exits with deliberate fade — the weight of the action felt in the animation's pace.

### 2.3 Override Rules

Components ship with default sensory signatures. Override only when:

- **Rapid succession:** Multiple identical interactions firing quickly (bulk-toggling sets) — fire haptic on first event only. Subsequent events animate silently.
- **Elevation:** High-stakes primary buttons ("Start Session", "Delete Account") can elevate from light to medium impact. Animation stays the same.
- **Suppression:** Components inside scroll views during fast flicking suppress haptics. The user is scrolling, not selecting.
- **Reduce Motion:** All Transform and Reveal animations become 0.2s opacity cross-fades. Haptics remain.

---

## 3. The Workout Flow State

The workout is where Povver lives or dies. Everything else is in service of this experience.

### 3.1 Flow State Protection

During an active workout, the app enters a structurally different interaction mode — not visually dramatic, but optimized for speed and minimal cognition.

**Auto-advance:** When you complete a set (tap done), the editing dock automatically shifts focus to the next undone set's weight field. You never hunt for where to tap next. The completed set compresses (Transform), the next set expands to active size (Transform), and the dock is ready.

**Input anticipation (ghost values):** Every undone set pre-fills with values from the user's last session for this exercise, displayed at 40% opacity. Tapping done without editing accepts all ghost values. Tapping a field replaces the ghost with the cursor. If no prior session exists, template prescription values appear as ghosts instead. If neither exists, fields are blank.

**Forgiveness:** Tapping done is immediately reversible — tap the checkmark again to undo. No toast, no confirmation. The checkmark unchecks. This makes the done button safe to tap quickly.

**Reduced interruption:** During an active workout, no confirmation dialogs for Tier 1 actions. Remove a set — gone, undo toast. Remove an exercise — gone, undo toast. Only Tier 3 actions (discard workout, finish workout) show dialogs.

### 3.2 Contextual Density

The active exercise occupies ~60% of visible screen. Touch targets 48pt minimum. Set values large enough to read at arm's length.

Completed exercises collapse to a single row — name, set count, completion indicator. Tappable to expand.

Upcoming exercises show name and set count only.

As the user progresses, completed work compresses upward, the active exercise stays centered, upcoming work waits below. The scroll feels like forward momentum.

### 3.3 The Signature Interaction: Set Completion

The most frequent tap in the app. Unmistakably Povver.

**Choreography:**
1. Finger touches done circle — Respond (scale 0.97, instant)
2. Finger lifts — circle fills emerald from center outward (radial fill, 0.15s)
3. Fill triggers pulse (scale 1.0 → 1.15, system `.bouncy`) — light impact haptic at peak
4. During settle (1.15 → 1.0), checkmark draws in (stroke animation, 0.2s)
5. Row background flashes subtle emerald tint, fades (0.3s)
6. If auto-advance on, next set begins expanding

Total: ~0.5s from tap to settled. Fast enough to not slow the user down. Distinctive enough to feel rewarding.

**Progressive intensity:**
- Standard sets: signature as described
- Final set of exercise: exercise completion layers on (card compression + medium haptic)
- Final set of workout: workout completion layers on (success notification + held beat)

Each escalation is additive. The base signature is always present — it gains layers as significance increases.

### 3.4 Taps-to-Completion

The ideal workout where the user matches last session:

- **Current:** ~5 interactions per set (tap weight, type, tap reps, type, tap done). 20-set workout = 100+ taps.
- **With ghost values + auto-advance:** 1 interaction per set (tap done). 20-set workout = 20 taps.

This is the single largest UX improvement in the spec.

---

## 4. Component Interaction Standards

### 4.1 PovverButton

| State | Visual | Haptic |
|-------|--------|--------|
| **Idle** | Full color, full opacity | — |
| **Pressed** | Scale 0.97, ~90% brightness. Instant on touch-down, releases on finger-up. | Light impact (primary), medium impact (destructive), none (secondary/ghost) |
| **Loading** | After 300ms: label cross-fades to compact pulsing dot within same frame. Button dims to ~70%. No shape change. | None (press haptic already fired) |
| **Loaded** | Dot cross-fades back to label. Optional brief emerald flash if significant action. Min 600ms display if indicator appeared. | Success tick if action was significant |
| **Disabled** | 40% opacity, entire component | None. Fully inert — no press state, no animation. |

**API:**
```swift
PovverButton("Start Session", isLoading: $isStarting) {
    await startWorkout()
}
.buttonHaptic(.medium) // Override default
```

Default haptic: `.light` (primary), `.medium` (destructive), `.none` (secondary/ghost). Override with `.buttonHaptic()` modifier.

### 4.2 PovverTextField

| State | Visual |
|-------|--------|
| **Idle** | Hairline border, `Color.separatorLine` |
| **Focused** | Accent border (`StrokeWidthToken.thin`). View scrolls to place field above keyboard with `Space.lg` padding. Multi-field forms: background elevates to `Color.surfaceElevated`. |
| **Validation error** | Destructive border. Error message below with Reveal animation. Persists until input changes. |
| **Validation success** | Success border. Fades to idle after 1s. |
| **Disabled** | 40% opacity. Not focusable. |

### 4.3 Other Components

| Component | Default Haptic | Notes |
|-----------|---------------|-------|
| PovverToggle | Selection feedback on state change | System toggle animation — don't customize |
| PovverSegmented | Selection feedback on segment change | System `.pickerStyle(.segmented)` |
| PovverSlider | None (continuous) | If discrete steps added later: tick at boundaries |
| Chip / ChipGroup | Selection feedback on toggle | Rapid selection exception: haptic on first tap only within 200ms |
| Stepper +/- | Selection tick per tap | Hold-to-repeat: haptic on first tick and every 5th |
| ListRow | None | Navigation rows are silent |
| AgentPromptBar | Light impact on submit | Send arrow appear/disappear uses Reveal/Exit |

---

## 5. Destructive Action Tiers

Friction matches consequence.

### Tier 1: Reversible — Act, then offer undo

Action happens immediately. UndoToast appears with 5-second reversal window.

**Actions:** Remove set from workout, remove exercise from workout, clear filter(s), dismiss notification.

**UndoToast:** slides up from bottom. Shows brief description + "Undo" button. Auto-dismisses 5s. If undone: content reappears with Reveal. Haptic: none on delete, light impact if undo tapped.

### Tier 2: Recoverable — Inline confirmation

Deliberate gesture confirms. No modal dialog.

**Actions:** Swipe-to-delete (full swipe >150pt confirms + warning haptic, partial >60pt reveals delete button).

### Tier 3: Irreversible — Modal confirmation

`.confirmationDialog` with explicit destructive button.

**Actions:** Discard workout, finish workout, sign out, delete account, delete template, delete routine.

**Dialog copy rules:**
- Title: what will happen ("Discard this workout?")
- Message: what will be lost ("Your sets and progress from this session won't be saved.")
- Destructive button: verb matching title ("Discard")
- Cancel: always present, always "Cancel"
- Haptic: warning notification after confirm, not before

**Rule:** Never disable a destructive button. If unavailable, hide it entirely.

---

## 6. Completion & Reward Arc

The moments after success are more important than the moments before. Loading states prevent confusion. Completion states build habits.

### Completion Hierarchy

Four levels, each additive — higher levels include everything below.

**Level 1 — Field confirmed:** Value settles instantly. No animation, no haptic. Silence means everything works.

**Level 2 — Set completed:** Signature interaction (Section 3.3). Light impact. Row flash. Auto-advance. ~0.5s.

**Level 3 — Exercise completed:** Level 2 fires for final set + emerald left-edge slides in + card compresses + medium haptic. ~0.7s.

**Level 4 — Workout completed:** Level 3 fires for final exercise + 0.5s held beat + success notification haptic + staggered summary reveal (5 phases over 0.8s).

### What Completion Is Not

- No confetti, particle effects, or sound effects
- No congratulatory text ("Great job!") — the data is the reward
- No gamification metrics (streaks, points, XP)

The arc: **physical effort → tactile acknowledgment → data reflection.** Each stage quieter than the last.

---

## 7. Error Communication

Errors are conversations, not alerts.

### Language Rules

- **Never show:** status codes, error class names, technical identifiers
- **Always show:** what happened, what to do next, how to get help if it persists
- **Voice:** brief, calm, no exclamation marks, no apologies

### Error Patterns

**Sync errors (during workout):**
Optimistic UI stays. Subtle sync indicator on affected row, resolves silently on retry. If persistent (3+ retries / 30s): transient toast — "Couldn't save — will retry automatically."

**Form submissions (login, save template):**
Inline error below the button. Stays until user retries. Button returns to idle.
- First failure: "That didn't work. Try again?"
- Second failure: "Still not working. Check your connection, or message your coach for help."

**Data loading (fetch workouts, load template):**
Content area becomes the error state. Not a toast over empty space.
- First failure: "Couldn't load right now." + Retry button
- Second failure: "Something's not right. Let us know and we'll sort it out." + Retry + "Message coach" link

**Destructive action failure:**
System alert: "That didn't go through — nothing was deleted. Try again?" Buttons: "Try Again" / "Cancel."

### Coach as Escalation Path

"Message your coach" links pre-fill context: "Hey — I ran into an issue while [saving a template]. Can you help?" Turns dead-end errors into conversations.

### Error Animation

- Inline errors: Reveal (opacity + 8pt lift)
- Toasts: slide up from bottom, auto-dismiss
- Error-state views: cross-fade from loading — never hard cut
- Error resolves: error Exits, content Reveals

---

## 8. Input Anticipation & Smart Defaults

The best interaction is the one that doesn't need to happen.

### Ghost Values

Undone sets show values from last session at 40% opacity. Tapping done accepts ghosts. Tapping a field replaces ghost with cursor. Fallback order: last session → template prescription → blank.

### Auto-Advance

After set completion, focus moves to next undone set automatically. If next set has ghost values, done button is highlighted as primary target. If no ghosts, weight field activates with editing dock.

Between exercises: auto-advance moves to first set of next exercise with scroll and density transitions.

User can always tap any cell to jump — auto-advance is default path, not constraint.

### Pre-filled Contexts

| Input | Pre-fill |
|-------|----------|
| Workout name | Template name if from template, "Workout" if empty start |
| New set added | Copies weight/reps/RIR from last set in that exercise |
| Exercise swap search | Pre-selects same muscle group and equipment |
| Coach message after error | Context about what went wrong |
| Coach message from CTA | Entry context (e.g., "Create routine") |
| New exercise in template | 1 working set, 10 reps, no weight, RIR 2 |

---

## 9. Navigation & Loading

### Navigation Destinations (push)

Show destination view immediately. Content fades in with Reveal when data loads. Never a blank screen with centered spinner.

### Sheets

Show chrome (title, drag indicator) immediately. If data needed, compact spinner within content area — not replacing the sheet.

### Full-screen Covers

Current pattern (start view appears immediately) is correct. No change.

### Minimum Display

If a loading indicator appears, hold for minimum 400ms before showing content. Prevents flash-of-spinner.

### Disabled States

40% opacity universally. Fully inert — no press, no haptic, no animation. Disable when fixable ("fill in email first"). Hide when irrelevant. Never disable destructive buttons.

---

## 10. Screen-by-Screen Audit

### Workout Mode (FocusModeWorkoutScreen)

| Gap | Required Change | Priority |
|-----|----------------|----------|
| No ghost values | Implement ghost values from last session | High |
| No auto-advance after set completion | Add focus progression logic | High |
| Set completion is checkmark-only | Implement signature interaction (radial fill + pulse + stroke draw) | High |
| Exercise completion has no sensory moment | Add card compression + medium haptic + left-edge slide | Medium |
| Remove exercise uses Tier 3 dialog | Downgrade to Tier 1 (undo toast) | Medium |
| Error banner auto-dismisses 4s | Change sync errors to inline row indicator | Medium |
| Active exercise same density as others | Implement contextual density | High |
| "Add Exercise" button no haptic | PovverButton default handles this | Low |
| "Finish Workout" button no haptic | `.buttonHaptic(.medium)` | Low |

### Workout Start View

| Gap | Required Change | Priority |
|-----|----------------|----------|
| No loading state on "Start Session" | Add `isLoading` binding | High |
| No error feedback on failure | Add inline error below CTA | Medium |

### Completion Summary

| Gap | Required Change | Priority |
|-----|----------------|----------|
| No held beat before transition | Add 0.5s pause after final set | Medium |
| Verify staggered reveal timing | Match spec (0.0/0.2/0.4/0.6/0.8s) | Low |

### Coach Tab

| Gap | Required Change | Priority |
|-----|----------------|----------|
| AgentPromptBar no haptic on submit | Add light impact | Low |
| Loading is centered ProgressView | Add structural context while loading | Medium |

### Library Tab

| Gap | Required Change | Priority |
|-----|----------------|----------|
| Search field no focus behavior | Scroll-to-focus + accent border | Medium |
| Detail views show centered spinner | Replace with immediate view + opacity fade-in | Medium |
| Filter chips no haptic | Chip component default handles this | Low |

### History Tab

| Gap | Required Change | Priority |
|-----|----------------|----------|
| "Load More" no loading state | Add `isLoading` to PovverButton | Low |
| Empty state minimal | Redesign as invitation | Low |

### Settings / More

| Gap | Required Change | Priority |
|-----|----------------|----------|
| Weight unit custom disabled state | Standardize to 40% opacity | Low |
| Sign out no haptic on confirm | Warning notification per Tier 3 | Low |

### Auth Screens

| Gap | Required Change | Priority |
|-----|----------------|----------|
| Login button no loading state | Add `isLoading` binding | High |
| Error is red text, no guidance | Progressive inline error copy | Medium |
| No focus management | Scroll-to-focus + field elevation | Medium |
| SSO buttons no loading state | Add `isLoading` binding | Medium |

### Onboarding

| Gap | Required Change | Priority |
|-----|----------------|----------|
| Direct UIKit haptic calls | Migrate to HapticManager | Low |

### Floating Workout Banner

| Gap | Required Change | Priority |
|-----|----------------|----------|
| No haptic on tap | Add light impact | Low |

---

## 11. Out of Scope

The following are acknowledged but not addressed in this spec:

1. **Sound design** — audio feedback for completion moments. Worth exploring separately.
2. **Watch/widget interactions** — different input paradigm entirely.
3. **Gesture vocabulary expansion** — long-press context menus, force touch. Potential future spec.
4. **Dark mode motion adjustments** — whether animations should differ in dark vs. light. Currently no difference planned.
5. **Performance budgets** — animation frame rate targets, memory limits for complex transitions. Should be validated during implementation.
