# Visual Evolution — Brand Identity & Polish Pass

**Date:** 2026-03-19
**Status:** Draft
**Scope:** iOS app — all main screens, design system foundation, interaction patterns, data services

---

## 1. Design Intent

Elevate the main app experience to match the polish level established by the landing page and onboarding sequence. The app should feel athletic, premium, and alive — like a training tool built by athletes, not a generic fitness app.

**Reference apps:** Whoop, Apple Health, Oura Ring.

**Core tension:** Usability and user experience trump brand distinction. This is a daily-use training tool, not a marketing surface. Every visual change must earn its place through improved clarity, motivation, or delight — never at the cost of speed or usability.

**What "premium" means here:** Not decoration — precision. Every number is typeset. Every transition has intent. Every screen knows who you are and what you need right now. The difference between a $5/mo app and a $30/mo app is whether the details feel considered or accidental.

---

## 2. Design Principles

### 2.1 Earned Color

Emerald is the color of progress, achievement, and action. It appears when something is meaningful — a completed workout, a PR, a primary CTA, the coach's presence. It does not appear as ambient decoration.

**Emerald is used for:**
- Primary CTAs (buttons that initiate action)
- Active workout state
- Progress indicators and achievement markers (PRs, streaks, milestones)
- Coach presence indicator (breathing glow)
- Training load status when positive
- Current week in charts (represents actual training)
- Completed exercise indicators
- Trend deltas showing improvement

**Emerald is NOT used for:**
- Tab bar tint (goes neutral)
- Selected chips/filters (neutral: stronger surface + bold text)
- Generic icons or navigation elements
- Profile avatar background
- Secondary buttons or links

The effort orange remains unchanged — already follows this principle (intensity indicators only).

### 2.2 Agent Presence — The Living Element

The AI coach is not a feature behind a button — it is a presence in the app. This is communicated through a visual language of subtle animation:

- **Breathing glow:** A soft emerald radial pulse behind the coach's avatar/icon. Slow cycle (6-8s), barely perceptible. Says "I'm here, I'm aware of your training."
- **Thinking state:** When the agent is generating a response, the pulse quickens or intensifies. The thinking indicator becomes a living element, not three bouncing dots.
- **Artifact marking:** When the coach surfaces a visualization or insight, it enters with a brief emerald edge glow that fades — distinguishing coach-generated content from static UI.

This visual language is scoped to agent interactions. It does not bleed into the rest of the app.

### 2.3 Context-Aware Motion

Motion matches the user's mental state. Speed is not a global setting — it adapts to context.

**Pre/post workout (browsing, planning, reviewing):**
- `gentle` spring (response: 0.5, damping: 0.8) for screen transitions
- Staggered entrance animations (fade + 8pt y-offset, 80ms delay between items)
- Satisfying feedback on interactions

**During active workout:**
- `snappy` spring (response: 0.3, damping: 0.7) or `MotionToken.fast` (0.12s)
- No staggered reveals on set rows. Sheets snap into place.
- Dropdowns, exercise info, any lookup — instant. The UI gets out of the way.
- Exception: set completion gets a light haptic + brief 0.12s scale pulse on checkmark

**Celebration moments (PR, workout complete, milestones):**
- `bouncy` spring (response: 0.4, damping: 0.6) — earned here
- Brief, not prolonged. 0.3s max.

**Implementation:** An environment value `workoutActive: Bool` that components read to automatically select the appropriate motion curve. Individual views should not decide — the system decides.

### 2.4 Dual-Mode Parity

Every visual element is designed for both light and dark mode simultaneously. No "looks great in dark, forgot about light."

- **Dark mode:** Depth from luminance steps (bg → surface → surfaceElevated). Borders more subtle (lower opacity). Emerald pops naturally on charcoal.
- **Light mode:** Depth from hairline borders and subtle shadows (luminance gap between layers is smaller). Emerald may need slightly more saturation or `accentMuted` background tints to achieve equivalent visual weight.
- **Every new component spec below calls out both mode treatments** where they differ.

### 2.5 Data Presentation Craft

Numbers are typeset, not just displayed. This is where Oura and Apple Health separate from generic fitness apps — not by having data, but by how the data is *rendered*.

- **Hero metrics:** Large monospaced number stacked above a small unit label. "82.5" in `metricL`, "kg" in `micro` below. Never inline ("82.5 kg") for hero numbers.
- **Tabular alignment:** Weight, reps, and RPE column-align across all sets within an exercise. Fixed-width columns so the eye can scan vertically without hunting.
- **Monospaced digits:** `.monospacedDigit()` on all numeric displays — weights, reps, timers, durations. Numbers should never cause layout shifts.
- **Trend indicators:** Tiny delta next to metrics showing direction vs. last session. "+2.5 kg" in emerald (improvement — earned color) or "-2.5 kg" in `textTertiary` (regression — neutral, not punitive). Applied contextually in History workout rows and exercise performance views.

### 2.6 Workout Mode — Visual Environment Shift

When a workout is active, the visual environment shifts to communicate focus. This is not cosmetic — it changes how the app *behaves*.

**Visual changes:**
- Background subtly deepens (2-3% cooler/darker tint on `bg`, both modes). In dark mode: `bg` shifts from `#0B0D12` toward `#080A0E`. In light mode: `bg` shifts from `#F6F7F8` toward `#EEF0F2`.
- Active exercise card lifts to Tier 2 (elevated, `level1` shadow). All other cards recede to Tier 0 (flat, no border, no background — content flows directly on the tinted `bg`).
- Completed exercises get a thin emerald left-edge indicator (3pt wide, `radiusIcon` corners) — earned color, says "done."
- Upcoming exercises show as Tier 0 rows with reduced emphasis (`textSecondary` title instead of `textPrimary`).

**Behavioral changes:**
- All motion switches to `snappy`/`MotionToken.fast`.
- Staggered reveals disabled. Content appears immediately.
- Sheet presentations snap (no spring overshoot).
- `UIApplication.shared.isIdleTimerDisabled = true` (already implemented).

**The floating workout banner** on other tabs becomes a first-class element:
- Accent background, inverse text (current — good).
- Shadow: `ShadowsToken.level2` (replace current inline shadow).
- Timer: monospaced digits (current — good).
- Content: show current exercise name instead of workout name (tells you where you left off).
- Subtle breathing animation: 0.98→1.0 scale, 4s cycle. Barely perceptible but alive.

---

## 3. Design System Changes

### 3.1 Typography Consolidation

Kill the legacy `TypographyToken` set. Migrate everything to the v1.1 Premium `TextStyle` enum.

**New role to add:**

| Role | Size/Weight | Use |
|------|-------------|-----|
| `sectionLabel` | 11pt semibold, uppercased, tracking 1pt | Whoop-style section headers. Used across all screens consistently. |

**Existing metric roles (no changes needed):**

| Role | Size/Weight | Use |
|------|-------------|-----|
| `metricL` | 28pt semibold, `.monospacedDigit()` | Hero numbers — volume, weight, streak count |
| `metricM` | 22pt semibold, `.monospacedDigit()` | Secondary metrics — timer, set counts |
| `metricS` | 17pt semibold, `.monospacedDigit()` | Inline metrics — individual set values, trend deltas |

**Migration:** Audit every view using raw `.font(.system(size:weight:))` and migrate to `.textStyle()`. The `WorkoutRow` component (`Povver/UI/Components/Domain/WorkoutRow.swift`) is the reference for correct usage.

### 3.2 Corner Radius Consolidation

Kill legacy values. Standardize on v1.1:

| Token | Value | Use |
|-------|-------|-----|
| `radiusCard` | 16pt | Cards, containers |
| `radiusControl` | 12pt | Buttons, inputs, chips, grouped list items |
| `radiusIcon` | 10pt | Icon containers, small elements |
| `pill` | 999pt | Capsules (prompt bar, tags, status badges) |

Remove: `small` (8), `medium` (12 — replaced by `radiusControl`), `large` (16 — replaced by `radiusCard`), `card` (18 — replaced by `radiusCard` at 16).

### 3.3 Card Hierarchy — 3 Tiers

| Tier | Background | Border | Shadow | Use |
|------|-----------|--------|--------|-----|
| Tier 0 (Flat) | None (inherits `bg`) | None | None | List rows, inline content, recent conversations, inactive exercises |
| Tier 1 (Surface) | `surface` | Hairline `separatorLine` | None | Default container, settings groups, template cards |
| Tier 2 (Elevated) | `surfaceElevated` | None | `level1` | Hero cards, active workout exercise, coach status, floating elements |

### 3.4 Motion Tokens

Add named spring presets to `MotionToken`:

| Name | Response | Damping | Use |
|------|----------|---------|-----|
| `snappy` | 0.3 | 0.7 | Workout mode, press states, state changes |
| `gentle` | 0.5 | 0.8 | Screen entrances, browsing transitions |
| `bouncy` | 0.4 | 0.6 | Celebrations, achievements, milestone reveals |

Retain existing `MotionToken.fast/medium/slow` for non-spring duration-based animations.

### 3.5 Haptic Feedback

Centralized in a `HapticManager` utility (not scattered `UIImpactFeedbackGenerator` calls in each view).

| Event | Feedback |
|-------|----------|
| Set completion (checkmark tap) | Light impact |
| PR detected on set | Success notification |
| Workout complete | Success notification |
| Milestone unlocked | Success notification |
| Destructive action confirmation | Warning notification |
| Primary CTA tap | Light impact |

### 3.6 Color Adjustments

- **Tab bar tint:** `textSecondary` (neutral). Active tab differentiated by filled vs. outlined icon variant and/or weight, not color.
- **Chip selected state:** Stronger `surface` background + semibold text + slightly heavier border. No `accentMuted` fill.
- **Profile avatar:** Neutral tint (e.g., `textTertiary` at 10% opacity background) instead of emerald.
- **Chart historical bars:** Neutral gray (`ColorsToken.n300` light / `ColorsToken.n600` dark) instead of `accent` at 0.35 opacity. Current week stays emerald.

---

## 4. Signature Visual Element — Training Consistency Map

Every great training app has a visual you'd recognize in a screenshot. Whoop has the strain gauge. Oura has the rings. Apple has the activity rings. Povver needs its own.

**The Training Consistency Map** is a compact grid of the last 12 weeks of training, displayed as a row of weekly columns. Each column represents a week, each cell within the column represents a scheduled training day.

**Structure:**
- 12 columns (weeks), most recent on the right
- Each column has cells for scheduled sessions that week (derived from the active routine's frequency — e.g., 4 cells for a 4-day program)
- Cells fill emerald when a session is completed (earned color at scale)
- Empty cells: faint neutral outline (`separatorLine` color)
- Missed scheduled sessions: neutral dot (no red, no guilt — the absence speaks for itself)
- Current week's column has a subtle highlight treatment (slightly brighter background)

**Where it lives:**
- Coach tab hero (below the coach status message, above the prompt bar). Visible on workout day, rest day, and returning states. Not shown for new users (nothing to display).
- Optionally in the History tab header (replacing or complementing the bar chart — TBD during implementation based on feel).

**Why this works:**
- It's glanceable — you understand your consistency pattern in under a second
- It rewards consistency visually without gamifying it (no streak counters, no punitive red)
- It's distinctly Povver — the combination of the emerald earned-color fills with the structured grid creates a visual signature
- It builds over time — each completed workout literally colors in your map
- It's honest — gaps show as empty cells, not as failures

**Both modes:**
- Dark: emerald cells glow subtly against charcoal background. Empty cells are faint outlines.
- Light: emerald cells are solid against near-white. Empty cells are light gray outlines.

**Data source:** `analytics_rollups` collection (weekly workout counts) cross-referenced with routine schedule frequency. See Section 9 for service architecture.

---

## 5. Screen Designs

### 5.1 Coach Tab — State-Driven Landing

The Coach tab adapts based on the user's training state. Same layout bones across all states: hero area → prompt bar → contextual content → recent conversations.

The hero is not a static card with swapped text. It's a **living status surface** — the coach's awareness of where you are in your training made visible. The breathing glow, the consistency map, the contextual message — they compose into something that feels like opening a conversation with someone who already knows your week.

#### State: New User (no routine, no history)

- **Hero (Tier 2):** Coach presence indicator with breathing glow. Emerald icon/avatar. Message: "Let's build your program." Below: brief context — "Tell me about your goals and I'll design a routine for you."
- **Prompt bar:** Multi-modal input (text, voice, file upload).
- **Primary action:** Single CTA — "Create your first program." No quick actions list. No clutter. The screen has one job: start the conversation.
- **No recent section.** Empty states with coach voice: "Your training story starts here."

#### State: Returning User, Workout Day

- **Hero (Tier 2):** Coach presence indicator with breathing glow.
  - `sectionLabel`: "YOUR COACH"
  - Status message (time-aware): "Good morning — ready for today's session."
  - Scheduled workout name in `bodyStrong`: "Upper Body A"
  - Training load indicator: ACWR-derived status word in emerald or `textSecondary` — "Optimal" / "Building" / "Deload" / "Recovery needed". The word is the interface — the number stays behind it.
  - Training Consistency Map (12 weeks). Today's cell is the one that fills when you train.
- **Prompt bar.**
- **Primary quick action:** "Start today's session" — emerald START label (earned color). This is visually distinct from the other actions — it's the thing the screen is pointing you toward.
- **Secondary quick actions:** Grouped list. "Analyze my progress", "Review my program" with neutral chevrons.
- **Recent conversations:** Tier 0 flat rows. Title + relative date. Hairline separator between rows.

#### State: Returning User, Rest Day

- **Hero (Tier 2):** Coach presence indicator. Status message: "Recovery day" or a dynamic insight pulled from the latest `weekly_review` or `analysis_insight` — e.g., "Your bench press is up 8% this month" or "Training load is optimal this week." The insight is pre-computed by the Training Analyst, not generated on-the-fly.
  - Training Consistency Map.
  - No training load indicator (irrelevant on rest days — the map shows the pattern).
- **No "Start session" action.** Primary action becomes contextual: "Check your progress" or "Review your program."
- **Quick actions and recent:** Same structure.

#### State: Post-Workout (just finished, returned to coach)

- **Hero (Tier 2):** The hero acknowledges the session. Pulls from `analysis_insights` for the just-completed workout:
  - "Solid session" + workout name.
  - Key stats: exercises / sets / total volume in compact metric row.
  - Highlight callouts if any (PRs, volume milestones) — emerald text, coach-voiced: "New PR on bench press — 92.5 kg estimated 1RM."
  - The Consistency Map updates — today's cell fills with emerald. If this is animated (the fill appearing), it's the single most satisfying micro-moment in the app. Brief `bouncy` spring.
- Transitions back to standard state (workout day / rest day) on next app open or after scrolling past.

#### State: Returning After Inactivity (7+ days since last workout)

- **Hero (Tier 2):** "Welcome back." No guilt. Shows:
  - Last workout date and name.
  - Routine cursor: "You left off at Day 3 — Lower Body B."
  - CTA: "Pick up where you left off" (starts next scheduled session).
  - Consistency Map: the recent gap is visible but unremarked. The invitation is forward-looking.

#### Coach Tab — Prompt Bar (Multi-Modal)

The prompt bar is the primary interaction surface for the coach across the entire app. It needs to support:

- **Text input** (current implementation — retain).
- **Voice chat:** The voice levels animation already exists. The transition from text mode to active voice needs a clear visual state change — the bar expands slightly, the voice waveform replaces the text field, a "listening" indicator appears. End-of-speech detection or manual stop button.
- **File/image upload:** Tap the "+" icon to access camera roll, files, or camera. Use cases: form check videos, screenshots of other programs, progress photos. Queued attachments appear as compact thumbnail chips below the prompt bar before sending.
- **Attachment preview row:** When files are attached, a horizontal row of thumbnail chips appears between the prompt bar and the content below. Each chip shows a tiny preview + "x" to remove. This row appears with `snappy` spring.

### 5.2 Train Tab — Workout Execution

#### Pre-Workout (Start View)

**Scheduled workout exists (routine with next session):**
- Tier 2 hero card showing the workout name, day label (e.g., "Day 3 of 4"), and exercise count preview ("5 exercises, ~45 min estimated").
- Primary CTA: "Start Session" — full-width emerald `PovverButton` (earned color — this is the moment).
- Below: "Start Empty Workout" and "From Template" as Tier 0 text links in `textSecondary`. Secondary paths, not competing for attention.

**No scheduled workout (no active routine):**
- No hero card. Clean start surface.
- "Start Empty Workout" as primary `PovverButton`.
- "From Template" as secondary action.
- No decorative icon or explanatory text. The user knows why they're here.

#### Active Workout — Set Input Experience

This is the most-used interaction in the app — weight, reps, RPE entered 30+ times per workout. It must be fast, precise, and satisfying.

- **Set row layout:** Fixed-width columns for weight, reps, RPE. All values in `metricS` with `.monospacedDigit()`. Column headers in `sectionLabel` ("WEIGHT", "REPS", "RPE") — visible at top of each exercise section, not repeated per row.
- **Input fields:** Tap a cell to edit. The cell highlights with a subtle `accent` at 8% opacity background (not a full border change — just a tint that says "editing here"). Keyboard type: `.decimalPad` for weight, `.numberPad` for reps.
- **Previous performance:** The set row shows last session's values as placeholder/ghost text in `textTertiary`. "82.5" in the weight cell if you did 82.5 last time. Tapping fills the value — one tap to repeat, edit to change. This is the core efficiency loop.
- **Set completion:** Tapping the checkmark (or the complete button) triggers:
  - Light haptic.
  - 0.12s scale pulse on the checkmark (1.0 → 1.15 → 1.0).
  - The row gets a subtle completed treatment (checkmark fills emerald — earned color).
  - If the set is a PR (detected by comparing e1RM against `set_facts`): success haptic + a brief "PR" badge appears next to the set in emerald with `bouncy` spring. The badge persists.
- **Adding a set:** "+" button below the last set. Appears with `snappy` spring. Pre-fills from last set's values (or from template prescription if first session).
- **Swipe actions:** Swipe-to-delete on set rows. `snappy` spring, no confirmation for individual sets (undo via shake or undo toast).

#### Active Workout — Visual Environment

(As described in Section 2.6 — workout mode tint, Tier 2 active exercise, Tier 0 others, emerald left-edge on completed exercises, snappy motion throughout.)

#### Header Bar

- Custom 52pt header retained.
- Coach button: sparkles icon in `textSecondary` with tiny emerald presence dot (6pt, positioned at top-right of icon). Signals "the coach is aware of your session" without distraction.
- Timer: `metricM` with monospaced digits. Appears when hero scrolls out of view (existing collapse behavior).
- Reorder button: monochrome (`textSecondary`).

#### Coach in Active Workout

- **Entry point:** Coach button in header opens a **compact half-sheet** (`.presentationDetents([.medium])`). Workout stays visible behind it.
- **Context injection:** The half-sheet's conversation automatically includes workout context — current exercise, completed sets, what's coming next, recent performance for this exercise from `set_facts`. The user doesn't need to explain where they are. This uses the existing `WorkoutCoachViewModel` which already has workout context access.
- **Inline actions:** Coach responses can include structured action buttons — "Swap exercise" (opens exercise search with the swap pre-selected), "Adjust weight to X kg" (pre-fills the next set), "Skip remaining sets" (marks exercise complete). These are not free-form — they're typed actions the workout service can execute.
- **Deep conversation:** If the user needs more space, the half-sheet expands to full (`.presentationDetents([.medium, .large])`). The workout stays active.
- **Multi-modal input:** Same capabilities as the Coach tab prompt bar — text, voice, file/image upload.
- **Visual language:** Half-sheet uses `surfaceElevated` background. Coach responses get a subtle left-edge emerald accent (2pt, same as completed exercise indicator). Workout mode's snappy motion applies.

#### Finish Workout — Signature Transition

This is the emotional payoff of every session. It should feel like crossing a finish line.

**The transition itself:**
1. User taps "Finish Workout" → confirmation sheet (current behavior — retain).
2. On confirmation: the workout mode tint fades (background returns to standard `bg` over 0.3s).
3. Full-screen cover presents with a custom transition — not the stock slide-up. A gentle fade-in (0.2s) that feels like the intensity releasing.

**The completion summary (WorkoutCompletionSummary) — sequenced reveal:**

The summary doesn't dump everything at once. It builds, creating anticipation:

1. **Coach presence** (immediate): Breathing glow appears at top. Coach avatar/icon. Brief pause (0.3s).
2. **Session headline** (stagger +0.1s): "Session Complete" in `screenTitle`. Workout name and date below in `secondary`.
3. **Core metrics row** (stagger +0.2s): Three stacked metric blocks, horizontally arranged:
   - Duration: `metricL` number + "min" in `micro`
   - Volume: `metricL` number + "kg" in `micro`
   - Sets: `metricL` number + "sets" in `micro`
   - Each fades in left-to-right, 0.1s apart. `gentle` spring.
4. **Highlights** (stagger +0.3s, only if they exist):
   - PR cards: Tier 2 elevated, emerald left edge. Exercise name + "New estimated 1RM: 92.5 kg" + delta from previous PR in emerald. Each card enters with `bouncy` spring.
   - Volume milestones: Same treatment. "Squat volume: 2,400 kg this week (+15%)."
   - If no highlights, this step is skipped — no empty "No PRs" placeholder.
5. **Consistency Map update** (stagger +0.2s after highlights): The map appears, and today's cell fills with emerald. This is the signature micro-moment — you literally see your consistency record grow. Animated fill with `bouncy` spring. Success haptic fires here.
6. **Exercise breakdown** (below the fold, scroll to see): Per-exercise summary rows. Exercise name, sets x reps, total volume. Trend indicator vs. last session where data exists.
7. **Coach reflection** (bottom): If `analysis_insights` for this workout are already available (they may not be — the Training Analyst processes asynchronously), show a brief coach-voiced summary: "Strong upper body session. Bench press is trending up — you've added 5 kg over the last 3 weeks." If not available yet, show nothing — don't wait for it or show a loading state.
8. **Dismiss CTA:** "Done" button at bottom. Returns to Coach tab (not Train tab) so the user sees the post-workout hero state.

### 5.3 Library — Training Assets Dashboard

Rethought from a 3-row transit screen into a content-rich surface that shows you your training assets at a glance.

#### Screen Header

- `screenTitle` (22pt semibold): "Library"
- Subtitle in `secondary`: contextual — "4 routines, 12 templates" (actual counts).

#### Active Routine — Hero Section

`sectionLabel`: "YOUR PROGRAM"

If user has an active routine:
- **Tier 2 card** with the routine name in `bodyStrong`.
- **Mini week strip:** A horizontal row of day indicators. Each day in the routine's schedule gets a compact cell showing the day label ("Day 1", "Day 2" or template short name). Layout:
  - Completed this week: emerald fill (earned color)
  - Today's session: emerald outline (call-to-action — this one's yours to fill)
  - Upcoming: neutral outline (`separatorLine`)
  - Rest days: no cell (only scheduled days appear)
- **Tap:** Opens full `RoutineDetailView`.
- **"Next up" subtext:** Below the week strip — "Next: Upper Body A" in `secondary` with `textSecondary`.

If multiple routines: active one is Tier 2 (above). Inactive ones listed below as Tier 0 rows with routine name + "X days/week" + chevron. `sectionLabel`: "OTHER ROUTINES".

If no routines: Coach-voiced empty state: "No programs yet — want me to design one for you?" with a CTA that opens the coach conversation.

#### Templates Section

`sectionLabel`: "TEMPLATES"

- **If ≤ 3 templates:** Show all as Tier 1 cards in a vertical stack. Each card: template name in `bodyStrong`, exercise count + set count in `secondary`, 2-3 muscle group tags as neutral chips (small capsules, `micro` text).
- **If > 3 templates:** Show the 3 most recently used as Tier 1 cards. "See all (N)" link in `textSecondary` at the bottom navigates to full `TemplatesListView`.
- **Tap:** Opens template detail.

Empty state: "No templates yet — create one or ask your coach."

#### Exercises Section

`sectionLabel`: "EXERCISES"

- **Recently used row:** If the user has workout history, show last 5 exercises as horizontally scrollable compact cells — exercise name only, `secondary` text, Tier 0 (flat, no card). Tap opens exercise detail.
- **Browse row:** "Browse all exercises" as a standard list row with chevron. Opens `ExercisesListView`.

If no history: just the "Browse all exercises" row.

### 5.4 History

#### Header

- `screenTitle` + session count in `secondary`: "History" / "47 completed sessions".

#### Weekly Chart

- Current week bar: emerald (earned color — actual training this week).
- Historical bars: neutral gray (`ColorsToken.n300` light / `ColorsToken.n600` dark).
- Otherwise unchanged — the chart structure works well.

#### Date Section Headers

- Adopt `sectionLabel` style: "TODAY", "YESTERDAY", "MONDAY, MAR 17".

#### Workout Rows

- Current `WorkoutRow.history()` structure retained (it uses design tokens well).
- **New: trailing trend indicator** — when the user taps into a workout, the detail view shows per-exercise deltas vs. the previous session of the same template. "+2.5 kg" in emerald or neutral delta. This requires `analytics_series_exercise` data (see Section 9).
- **New: PR badge** — if the workout contains a PR (from `analysis_insights.highlights`), a small emerald "PR" capsule badge appears in the workout row. Immediately communicates "something notable happened."
- Typography: migrate any remaining raw font values to `.textStyle()`.

#### Pagination

- "Load More" becomes a `textSecondary` text link, not a styled button. It's plumbing, not a feature.

### 5.5 More / Settings

Minimal changes — settings screens need clarity, not personality.

- **Profile card:** Avatar uses neutral tint (`textTertiary` at 10% opacity background) instead of emerald.
- **Section headers:** Adopt `sectionLabel` — "SETTINGS", "MORE".
- **Row typography:** Migrate raw font values (17, 15, 13, 12pt) to design system tokens.
- **Sign out:** Simple `destructive` text link at the bottom. No card wrapper — it's a rare action, not a feature.

---

## 6. Personality & Delight

### 6.1 Training Consistency Map

(Defined in Section 4. This is Povver's signature visual element.)

### 6.2 Milestone Moments

Cumulative achievements surfaced as one-time Coach tab hero states. These are detected by the `TrainingDataService` (Section 9) and shown as a special hero card that appears once and transitions away.

**Milestone types:**
- **Workout count:** 10th, 25th, 50th, 100th, 250th, 500th workout. Source: `WorkoutRepository.getWorkoutCount()`.
- **Cumulative volume:** Per-exercise all-time volume thresholds (10,000 kg, 50,000 kg, etc.). Source: requires new computation from `analytics_series_exercise` or `set_facts` aggregation.
- **PR achievements:** Already surfaced in post-workout. On the Coach tab, PRs from the last session appear in the post-workout hero state.

**Visual treatment:** The milestone card is a Tier 2 hero with enhanced breathing glow (slightly more intense emerald radial). Coach-voiced message: "50 workouts completed. Consistency is the hardest exercise — you're doing it." Brief emerald glow expansion, `bouncy` spring. The card appears once on the first Coach tab visit after the milestone is reached, then transitions to the standard state.

### 6.3 Time-Aware Coach Voice

Coach status messages adapt to time of day:

- Morning (5am-12pm): "Good morning — Upper Body A is up today"
- Afternoon (12pm-5pm): "Afternoon session? Let's go."
- Evening (5pm-10pm): "Evening session — let's finish the day strong."
- Late night (10pm-5am): "Late session tonight. Let's make it count."

Implementation: trivial — `Calendar.current.component(.hour, from: Date())` in the `CoachTabViewModel`.

### 6.4 Empty States with Coach Voice

Every empty state speaks as the coach, not as the system. This turns dead-ends into invitations.

| Screen | Current | Proposed |
|--------|---------|----------|
| No routines (Library) | Generic icon + "No routines" | "No programs yet — want me to design one for you?" + CTA |
| No templates (Library) | Generic icon + "No templates" | "No templates yet — create one or ask your coach." |
| No history | Generic icon + "No workouts" | "Your training story starts with the first session." + CTA to start |
| No conversations (Coach) | Generic | "Ask me anything about your training." |
| No exercise results (search) | Generic | "No matches — try a different name or ask me for alternatives." |

---

## 7. Screen Entrance Animations

All main tab screens get staggered entrance animations when first appearing. This replaces the current instant-render with a sense of intentionality.

**Pattern:** Each discrete content block (hero, prompt bar, section label, action group, list section) fades in with an 8pt y-offset, 80ms delay between elements. `gentle` spring.

**Constraints:**
- Only on initial appearance (tab selection), not on returning from a detail view (back navigation).
- Only in browsing mode (not during active workout — workout mode disables staggered reveals).
- Total duration for a full screen: ~0.4-0.5s max. Fast enough to not feel slow, slow enough to feel intentional.

**Implementation:** A reusable `StaggeredEntrance` view modifier that applies offset + opacity animation with configurable delay index.

---

## 8. Service Architecture — Data Layer for Dynamic Content

The visual evolution requires the iOS app to read training data that already exists in Firestore but is not currently consumed. This section defines the service architecture needed.

### 8.1 Existing Backend Data (Already Computed, Stored in Firestore)

The Training Analyst pipeline and `process-workout-completion.js` Cloud Tasks pipeline already compute and store:

| Collection | Key Fields | Computed By | Relevance |
|-----------|------------|-------------|-----------|
| `weekly_reviews/{YYYY-WNN}` | `training_load.acwr`, `fatigue_status.interpretation`, `fatigue_status.flags`, `muscle_balance`, `summary` | Training Analyst (weekly) | Coach tab: training load status, rest day insights |
| `analysis_insights/{id}` | `summary`, `highlights[]` (type: "pr" / "volume_up"), `flags[]`, `recommendations[]` | Training Analyst (post-workout) | Post-workout hero, PR badges, milestone detection |
| `analytics_rollups/{weekId}` | `workouts` (count), `hard_sets_per_muscle`, `load_per_muscle` | `process-workout-completion.js` | Consistency Map (weekly workout counts), ACWR backup |
| `analytics_series_exercise/{exerciseId}` | `points_by_day[]` (e1RM, volume), PR markers, plateau flags | `process-workout-completion.js` | History trend indicators, exercise progression |
| `analytics_series_muscle/{muscle}` | `weeks[]` (volume per week) | `process-workout-completion.js` | Future: muscle group visualizations |
| `set_facts/{id}` | `e1rm`, `e1rm_confidence`, exercise/muscle metadata | `process-workout-completion.js` | In-workout PR detection (compare current set e1RM vs historical best) |

### 8.2 Existing Firebase Functions (Callable from iOS)

These endpoints exist and return the data we need:

| Endpoint | Returns | Use |
|----------|---------|-----|
| `getAnalysisSummary` | Latest insights + weekly review + recommendation history | Coach tab rest-day insights, post-workout reflection |
| `getExerciseSummary` | Per-exercise e1RM series, last session, PR markers, plateau flags | History trend indicators, exercise detail |
| `getNextWorkout` | Next template in active routine rotation | Coach tab: scheduled workout name, workout day detection |

### 8.3 New iOS Service: `TrainingDataService`

A single service responsible for reading and caching training intelligence data from Firestore. This is the data backbone for the Coach tab states, post-workout summary, and trend indicators.

**Responsibilities:**

```
TrainingDataService
├── fetchTrainingSnapshot()        → TrainingSnapshot
│   ├── currentACWR: Double?       (from latest weekly_review)
│   ├── acwrInterpretation: String? ("optimal" / "building" / "overreaching" / "detraining")
│   ├── latestInsight: AnalysisInsight? (most recent post-workout insight)
│   ├── latestWeeklyReview: WeeklyReview? (most recent weekly review)
│   └── weeklyWorkoutCounts: [WeekWorkoutCount] (last 12 weeks, for Consistency Map)
│
├── fetchPostWorkoutSummary(workoutId:) → PostWorkoutSummary?
│   ├── highlights: [Highlight]     (PRs, volume milestones from analysis_insights)
│   └── coachReflection: String?    (from analysis_insights.summary)
│
├── checkMilestones()              → [Milestone]
│   ├── workoutCount milestones    (from WorkoutRepository.getWorkoutCount())
│   └── acknowledged milestones    (persisted in UserDefaults to show each only once)
│
└── fetchExerciseTrend(exerciseId:) → ExerciseTrend?
    ├── recentE1RM: [DataPoint]    (from analytics_series_exercise)
    ├── prMarkers: PRMarkers?      (all-time, recent window)
    └── vsLastSession: TrendDelta? (computed from points_by_day)
```

**Data flow:**
1. `TrainingDataService` reads from Firestore collections directly (not through Firebase Functions for the snapshot data — the collections are already there, a direct read is faster and avoids function cold starts).
2. For exercise-level trend data, it calls `getExerciseSummary` (the Firebase Function already does the heavy computation).
3. Results are cached in memory with a 5-minute TTL. The Coach tab doesn't need real-time data — a few minutes stale is fine.
4. The service does NOT compute ACWR, PR detection, or periodization status — all of that is pre-computed by the Training Analyst. The service is a **read layer**, not a computation layer.

**New Codable models:**

```
WeeklyReview       — maps weekly_reviews/{id}
AnalysisInsight    — maps analysis_insights/{id}
AnalyticsRollup    — maps analytics_rollups/{weekId}
ExerciseTrend      — wraps getExerciseSummary response
TrainingSnapshot   — composite of the above for Coach tab
PostWorkoutSummary — subset for completion screen
Milestone          — { type, message, value, acknowledgedAt }
WeekWorkoutCount   — { weekId, scheduledCount, completedCount }
```

### 8.4 New iOS ViewModel: `CoachTabViewModel`

Replaces the current inline state in `CoachTabView`. Determines coach state and loads appropriate data.

**State machine:**

```
enum CoachState {
    case newUser                    // no active routine AND no workout history
    case workoutDay(WorkoutDayContext)  // active routine, today has a scheduled session
    case restDay(RestDayContext)    // active routine, today is not a scheduled day
    case postWorkout(PostWorkoutContext) // just finished a workout this app session
    case returningAfterInactivity(InactivityContext) // 7+ days since last workout
}
```

**State derivation (on `CoachTabView` appearance):**

1. Check `postWorkoutFlag` (local `@AppStorage` flag set by `WorkoutCompletionSummary` dismiss). If set and < 4 hours old → `.postWorkout`.
2. Check `activeRoutineId` on user doc. If nil and `workoutCount == 0` → `.newUser`.
3. Check `lastCompletedAt` on active routine. If > 7 days ago → `.returningAfterInactivity`.
4. Call `getNextWorkout` (or read cached routine schedule). If today matches a scheduled day → `.workoutDay`. Else → `.restDay`.

**Data loading:** Once state is determined, load the relevant `TrainingSnapshot` via `TrainingDataService`. The hero content is composed from the snapshot data.

### 8.5 Consistency Map Data

The Consistency Map needs 12 weeks of data:

- **Scheduled sessions per week:** Derived from the active routine's template count (e.g., a 4-day routine = 4 scheduled sessions per week). If the routine changed mid-period, use the schedule that was active at the time (approximation is fine — this is a visual, not an audit trail).
- **Completed sessions per week:** From `analytics_rollups/{weekId}.workouts` (integer count). Already exists and is updated by `process-workout-completion.js`.

This is a single Firestore query: read the last 12 `analytics_rollups` documents ordered by weekId. O(12) document reads — negligible cost.

### 8.6 In-Workout PR Detection

For real-time PR detection during set completion:

- When a set is completed, compute its e1RM (Epley formula — already implemented in `set_facts` pipeline).
- Compare against the exercise's all-time best e1RM. This requires knowing the historical best.
- **Option A (simple):** On workout start, prefetch the current exercise's `analytics_series_exercise` document which contains `pr_markers.all_time_e1rm`. Cache in `FocusModeWorkoutService`. Compare each completed set's computed e1RM against this value.
- **Option B (deferred):** Don't detect PRs in real-time. Show them in the post-workout summary only (from `analysis_insights` after the Training Analyst processes). Simpler but less immediate.

**Recommendation:** Option A. The "PR" badge appearing the moment you complete a heavy set is the single most emotionally impactful micro-interaction in a strength training app. It's worth the prefetch.

### 8.7 Post-Workout Data Availability

The Training Analyst processes workouts asynchronously via Cloud Tasks. The `analysis_insights` document may not exist immediately when the user sees the completion summary.

**Approach:**
- Show the completion summary immediately with data available from the local workout (exercises, sets, volume — all computed client-side from the workout document).
- The Consistency Map update and core metrics don't need the analyst — they use local data + rollups.
- Coach reflection and PR highlights from `analysis_insights`: attempt to read with a 2-second timeout. If not available, skip gracefully. The post-workout summary is still complete without them — they're a bonus. On subsequent Coach tab visits, the post-workout hero state can show insights that have since been computed.

---

## 9. Migration Strategy

### 9.1 Tiers

**Tier 1 — Foundation (no new services, mechanical changes):**
- Typography consolidation (raw fonts → `.textStyle()`)
- Corner radius consolidation
- Card tier system conventions
- Motion token additions (spring presets)
- Color adjustments (tab bar, chips, avatar, chart bars)
- `HapticManager` utility
- `StaggeredEntrance` view modifier
- `workoutActive` environment value
- Section label styling across all screens
- Screen header consistency
- FloatingWorkoutBanner refinements (shadow token, exercise name)

**Tier 2 — Data services (new iOS code, reads existing Firestore data):**
- New Codable models (`WeeklyReview`, `AnalysisInsight`, `AnalyticsRollup`, etc.)
- `TrainingDataService` (Firestore reads + caching)
- `CoachTabViewModel` with state machine
- In-workout PR detection (prefetch + compare)

**Tier 3 — Screen redesigns (depends on Tier 1 + Tier 2):**
- Coach tab: state-driven hero, Training Consistency Map, contextual actions, time-aware greetings
- Train tab: workout mode visual shift, set row alignment + ghost values, set completion micro-interaction, PR badge, coach half-sheet
- Post-workout completion summary: sequenced reveal, metric blocks, highlight cards, map update
- Library: routine hero with mini-week, template cards, exercise quick access
- History: trend indicators, PR badges, date header styling
- More: typography migration, section labels, avatar/sign-out refinements
- Empty states: coach-voiced copy across all screens

**Tier 4 — Personality layer (depends on Tier 3):**
- Milestone detection and display
- Coach presence breathing glow component (used in hero, workout header, completion summary)
- Agent artifact emerald edge glow
- Staggered entrance animations on all tabs

### 9.2 What Gets Deleted

- Legacy `TypographyToken` values (display, title1, title2, headline, body, subheadline, footnote, caption, button, monospaceSmall)
- Legacy `CornerRadiusToken` values (small, medium, large, card)
- `PovverTextStyle` enum (replaced by `TextStyle`)
- Emerald tint on tab bar
- `accentMuted` chip selected state
- Emerald profile avatar tint
- Inline custom shadow on FloatingWorkoutBanner
- The "What's on the agenda today?" static headline
- The 2x2 QuickActionCard grid on Coach tab

### 9.3 What Gets Added

**Design system:**
- `TextStyle.sectionLabel`
- Spring presets: `snappy`, `gentle`, `bouncy`
- `HapticManager` utility
- `StaggeredEntrance` view modifier
- `workoutActive` environment value
- Workout mode background tint color variants
- `CoachPresenceIndicator` component (breathing glow)
- `TrainingConsistencyMap` component
- `TrendDelta` component ("+2.5 kg" badge)

**Data layer:**
- `TrainingDataService`
- `CoachTabViewModel`
- Codable models: `WeeklyReview`, `AnalysisInsight`, `AnalyticsRollup`, `ExerciseTrend`, `TrainingSnapshot`, `PostWorkoutSummary`, `Milestone`, `WeekWorkoutCount`

---

## 10. Out of Scope

- Home tab with dashboards (separate design effort)
- Sound design
- Custom fonts
- Skeleton loading states
- Proactive coach nudges during workout
- New backend computation (all analytical data is pre-computed by Training Analyst)
- New Firebase Functions endpoints (existing endpoints + direct Firestore reads are sufficient)
- New Firestore collections (all data exists; milestones use UserDefaults for acknowledgment tracking)

---

## 11. Success Criteria

- Every screen uses design system tokens — zero raw `.font(.system(...))` or hardcoded spacing/radius values.
- Emerald appears only in earned-color contexts. A new user with no activity sees minimal emerald (just the coach presence glow and primary CTAs).
- The Coach tab is alive — it knows what day it is, what workout is scheduled, how your training load looks, and whether you just finished a session.
- The Training Consistency Map is the first thing a returning user's eye goes to. It should create a brief moment of recognition — "that's my training."
- The post-workout completion summary feels like a finish line, not a receipt.
- Set input during active workout is the fastest, most satisfying version possible — no motion that delays, ghost values from last session for quick repeat, real-time PR detection.
- Workout mode is perceptibly different from browsing mode — a user could describe the difference without being told what changed.
- Light and dark mode have equivalent visual quality — neither is an afterthought.
- The Library shows your training assets, not three doors to other screens.
- The data layer reads existing Firestore data through a clean service with caching. No inline Firestore queries scattered across views. No recomputing what the Training Analyst already computed.
