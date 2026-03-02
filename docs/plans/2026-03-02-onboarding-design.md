# Onboarding Design

## Overview

First-run experience from app launch through authenticated, personalized state. Collects training profile data, starts a free trial, and generates an AI-powered routine as the first "aha moment." Designed for intermediate lifters (1-3 years training) with a premium, minimal aesthetic matching the Povver landing page.

## Research Summary

Key findings that shaped this design:

- **7-8 screens** is the credibility sweet spot for fitness apps, but one-question-per-screen enables condensing without losing trust
- **Under 60 seconds to first value** — Fitbod's model of minimal questions into immediate personalized output is the retention benchmark
- **AI-generated first routine outperforms pre-built templates** by up to 50% in retention
- **80-90% of trials start Day 0** — presenting trial during onboarding drives ~50% of conversions
- **First 48 hours critical** — if first workout doesn't happen, momentum dies before habit forms
- **Premium feel** = haptics + fluid animations + design detail attention + restraint
- **AI trust** = show it working immediately + transparency about capabilities + user control

## User Flow

```
App Launch
  → Screen 1: Welcome (brand moment)
  → Screen 2: Authentication (Apple / Google / Email)
  → Screen 3: Training Profile (experience + frequency)
  → Screen 4: Equipment (where do you train)
  → Screen 5: Trial & AI Disclosure
      ├─ "Start Free Trial" → Screen 6: Routine Generation
      │     ├─ "Start training" → Coach Tab (routine active)
      │     └─ "Adjust with coach" → Coach Chat (routine artifact, conversation)
      └─ "Continue with basic logging" → Coach Tab (empty state, quick actions)
```

Total active input time: ~30 seconds. Total flow time: ~60-90 seconds including routine generation.

## Data Collected

| Field | Screen | Input Type | Required |
|-------|--------|-----------|----------|
| `fitnessLevel` | Training Profile | 3-option card select | Yes |
| `workoutFrequency` | Training Profile | Horizontal number selector (2-6) | Yes |
| `equipment` | Equipment | 3-option card select | Yes |
| `weightFormat` | Inferred | Device locale (metric → kg, imperial → lbs) | Auto |
| `heightFormat` | Inferred | Device locale (metric → cm, imperial → ft) | Auto |

Fields NOT collected during onboarding (deferred to Settings or agent conversation):
- `fitnessGoal` — irrelevant for initial routine generation; agent can ask when context-appropriate
- `height`, `weight` — optional, collected later via profile or agent prompt
- `name` — derived from auth provider display name, editable in Settings

## Design Language

### Brand Continuity with Landing Page

The onboarding inherits directly from the landing page (`landing/styles.css`) to create seamless brand perception from web to native.

| Landing Page Element | Onboarding Adaptation |
|---|---|
| `--bg: #0A0E14` | Background color on all screens (maps to `Color.bg` in dark mode) |
| Grain texture (2% SVG noise overlay) | Reproduced as a SwiftUI overlay with noise texture |
| Mesh gradient (emerald radial glows) | Persistent breathing glow layer, intensity varies per screen |
| `hero-label` pill (11px, 600w, 0.12em tracking, emerald) | "AI Strength Coach" subtitle on Welcome |
| `hero-accent` animated gradient text | Routine name on Generation screen |
| `--border: rgba(255,255,255,0.06)` | Card and button borders throughout |
| `cubic-bezier(0.16, 1, 0.3, 1)` | All transitions and animations |
| `nav-logo` (16px, 700w, 0.14em tracking) | Wordmark on Welcome screen |
| `--accent-glow: rgba(34,197,154,0.12)` | Base glow opacity (intensifies to 0.18 on Trial screen) |

### Atmospheric Glow System

A persistent radial emerald glow exists behind all content. It never disappears during transitions — it's a continuous atmospheric layer that creates spatial continuity.

- **Welcome:** Centered, breathing (scale 1.0 → 1.05, 8s loop), opacity 0.12
- **Auth:** Drifts upward, same opacity
- **Training Profile / Equipment:** Centered behind content, same opacity
- **Trial screen:** Intensifies to opacity 0.18, tighter radius — energy is building
- **Generation screen:** Flares to 0.25 on completion, settles back

### Typography Usage

- **Wordmark (Welcome):** 16pt, weight 700, letter-spacing 0.14em — matches landing `nav-logo`
- **Screen questions:** `TextStyle.screenTitle` (22pt semibold)
- **Card titles:** `TextStyle.bodyStrong` (17pt semibold)
- **Card subtitles:** `TextStyle.secondary` (15pt regular), `Color.textSecondary`
- **"Powered by AI" heading (Trial):** `TextStyle.appTitle` (34pt semibold) — the one place outside Coach tab that earns this size
- **Routine name (Generation):** `TextStyle.appTitle` with animated gradient fill
- **Legal text:** `TextStyle.micro` (12pt), `Color.textTertiary`

### Interaction Patterns

- **Card selection:** Tap → light haptic → 3pt emerald left-border appears, background shifts to `rgba(34,197,154,0.06)`, text brightens to `textPrimary`
- **Number selector (frequency):** Tap → light haptic → selected circle scales up (1.0 → 1.12, spring: mass 1, stiffness 200, damping 15), fills emerald, text goes black
- **Auto-advance (Equipment screen only):** 400ms delay after selection, card pulses with glow, screen transitions forward
- **Continue buttons:** Appear with spring animation from bottom when required selections are made
- **Screen transitions:** Current content fades out + shifts up (12pt, 0.3s), new content fades in + shifts up from below (20pt, 0.5s). Background glow layer does NOT transition.

### Haptic Choreography

| Interaction | Haptic |
|---|---|
| Card selection | `UIImpactFeedbackGenerator(style: .light)` |
| Number selector tap | `UIImpactFeedbackGenerator(style: .light)` |
| "Get Started" / CTA taps | `UIImpactFeedbackGenerator(style: .medium)` |
| Routine generation complete | `UINotificationFeedbackGenerator(.success)` |

### Progress Indicator

1pt emerald line at screen top. No step numbers, no dots. Width animates with brand easing:
- Training Profile: 50%
- Equipment: 100%
- Not shown on Welcome, Auth, Trial, or Generation screens

## Screen Specifications

### Screen 1: Welcome

The magazine cover. Establishes brand presence — no feature explanation needed.

**Layout:**
- Full dark canvas (`Color.bg`) with grain overlay
- Centered radial emerald glow, breathing animation
- Povver wordmark: centered, 16pt weight 700, 0.14em letter-spacing
- Below wordmark: "AI STRENGTH COACH" — 11pt, weight 600, 0.12em tracking, emerald color, uppercase (matches landing `hero-label`)
- Bottom: "Get Started" CTA — emerald fill, black text, pill radius, full width
- Below CTA: "Already have an account? **Sign in**" — `textTertiary` with "Sign in" in accent

**Entrance animation (1.2s total):**
1. Glow fades in (0.6s)
2. Wordmark slides up with brand easing (0.8s)
3. Subtitle fades in (0.3s delay)
4. CTA slides up from bottom (0.4s delay)

### Screen 2: Authentication

Clean SSO screen maintaining atmospheric continuity.

**Layout:**
- Glow shifted upward
- "Create account" — `screenTitle` at top
- Three full-width buttons, 56pt height, `radiusControl` (12pt):
  - "Continue with Apple" — white fill, black text (Apple HIG)
  - "Continue with Google" — `bg-elevated` (#111820) with `rgba(255,255,255,0.06)` border
  - "Sign up with email" — same surface treatment as Google
- Bottom: "By continuing you agree to our Terms & Privacy" — `micro`, `textTertiary`

### Screen 3: Training Profile

Two questions, one screen. All tap-based, zero typing.

**Question 1 — Experience:**
- "Training experience" — `screenTitle`
- Three full-width cards:
  - "Under a year"
  - "1 – 3 years"
  - "3+ years"
- Time-based labels (not beginner/intermediate/advanced — those feel judgmental)
- Card style: `bg-elevated` background, `rgba(255,255,255,0.06)` border, `radiusControl` corners

**Question 2 — Frequency:**
- "Days per week" — `screenTitle`
- Five circular selectors in a row (48pt diameter): 2, 3, 4, 5, 6
- Default: surface + border. Selected: emerald fill, black text, spring scale-up

**Continue button:** Hidden until both selections are made. Slides up with spring animation.

**Progress bar:** 50% emerald fill.

### Screen 4: Equipment

Single question. Auto-advances after selection.

**Layout:**
- "Where do you train?" — `screenTitle`
- Three cards, taller (80pt) with two lines of text each:
  - "Commercial gym" / "Full equipment"
  - "Home gym" / "Barbell & dumbbells"
  - "Minimal setup" / "Bodyweight focused"
- Title line: `bodyStrong`. Subtitle: `secondary`, `textSecondary` color.

**Behavior:** Auto-advance 400ms after selection. No Continue button. Light haptic, selected card pulses with emerald glow, screen transitions forward.

**Progress bar:** 100% emerald fill.

### Screen 5: Trial & AI Disclosure

The threshold before the magic. Glow intensifies.

**Layout:**
- Glow at 0.18 opacity (stronger than previous screens)
- "Powered by AI" — `appTitle` (34pt semibold)
- Body text (3 lines max, `body`, `textSecondary`): "Povver uses AI to build your programs and coach your sessions. A free trial starts today."
- Feature list with emerald checkmarks (staggered fade-in, 100ms each):
  - Program generation
  - Session analysis
  - Progressive overload tracking
  - 900+ exercises
- After-trial note (`secondary`, `textTertiary`): "After your trial, logging stays free."
- Primary CTA: "Start Free Trial" — emerald fill, 52pt height (slightly larger than standard CTAs)
- Legal note (`micro`, `textTertiary`): "Cancel anytime in App Store settings"
- Skip option (`secondary`, `textTertiary`): "Continue with basic logging"

**"Continue with basic logging" behavior:**
- No StoreKit prompt, no trial started
- Skips routine generation entirely
- Lands on Coach tab with empty state and quick action cards
- First Coach message: "Welcome to Povver. Start logging your workouts in Train, or tap below to see what AI coaching can do."

### Screen 6: Routine Generation

The aha moment. Two-phase animation sequence.

**Phase 1 — The Build (0-2 seconds):**
- Dark canvas
- "Building your program" fades in, centered (`screenTitle`)
- Thinking indicator appears (reuse `ThinkingBubble` pulsing aesthetic)
- User's parameters stream in below: "Hypertrophy · 4 days · full equipment" (`secondary`, `textSecondary`)

**Phase 2 — The Reveal (2-6 seconds):**
- Title slides up, becomes "Your program"
- Routine name materializes in center — `appTitle` (34pt) with animated gradient text (landing page `hero-accent` treatment: `linear-gradient(135deg, #22C59A, #7CEFCE, #22C59A)` with `background-size: 200%`)
- Day cards stagger in from below (200ms delays, spring physics)
- Each card: day label + exercise count + estimated duration
- Standard `SurfaceCard` treatment

**Completion moment:**
- Emerald glow flares to 0.25 opacity for 300ms, settles back
- Haptic: `UINotificationFeedbackGenerator(.success)`
- Dual CTA appears:
  - Primary: "Start training" — emerald fill. Accepts routine, lands on Coach tab with routine confirmed and AI intro message.
  - Secondary: "Adjust with coach" — text link, accent color. Opens `CanvasScreen` with routine artifact visible. AI's first message: "Here's what I built. What would you change?"

**Behind the scenes:**
- API call to agent fires when screen appears
- Animation paced to minimum 5 seconds even if API returns faster
- If API takes longer, Phase 1 thinking indicator continues naturally
- Creates: 1 `Routine` (active) + 3-5 `WorkoutTemplate` documents with exercises from global catalog, sets/reps/RIR appropriate to experience level and frequency

## Post-Onboarding States

### Path A: Trial + Start Training
- Coach tab with AI intro message referencing their profile
- Routine artifact visible in conversation
- Quick actions available
- First message: "Your program is ready. [Routine name] — [X] days per week. When you're ready for your first session, head to Train. I'll be here if you want to adjust anything."

### Path B: Trial + Adjust with Coach
- `CanvasScreen` opens directly with routine artifact
- AI's first message: "Here's what I built. What would you change?"
- User iterates through conversation (swap exercises, change split, adjust volume)
- When satisfied, they're already in the Coach tab — no additional transition

### Path C: Basic Logging (no trial)
- Coach tab with empty state, quick action cards visible
- Quick actions surface paywall when tapped
- First message: "Welcome to Povver. Start logging your workouts in Train, or tap below to see what AI coaching can do."
- Train tab is immediately usable for manual workout logging

## Architecture Notes

### New Files Required
- `OnboardingView.swift` — Root onboarding coordinator
- `OnboardingViewModel.swift` — State management, API calls, StoreKit integration
- `WelcomeScreen.swift` — Screen 1
- `AuthScreen.swift` — Screen 2 (may wrap existing `LoginView`/`RegisterView` with new styling)
- `TrainingProfileScreen.swift` — Screen 3
- `EquipmentScreen.swift` — Screen 4
- `TrialScreen.swift` — Screen 5
- `RoutineGenerationScreen.swift` — Screen 6
- `OnboardingGlowLayer.swift` — Persistent atmospheric glow component
- `GrainTextureOverlay.swift` — Noise texture overlay

### Data Flow
1. Onboarding selections stored in `OnboardingViewModel` state
2. On "Start Free Trial" → StoreKit subscription flow
3. On trial confirmation → write `UserAttributes` to Firestore
4. On routine generation screen → call agent API with profile data
5. Agent creates `Routine` + `WorkoutTemplate` documents server-side
6. Device syncs via existing Firestore listeners
7. `AppFlow` transitions from `.onboarding` to `.main`

### Navigation Integration
- Add `.onboarding` case to `AppFlow` enum in `RootView.swift`
- After successful auth, check if `UserAttributes` exists and is populated
- If not populated → show onboarding. If populated → go to `.main`
- This handles returning users who reinstall — they skip onboarding

### Unit Inference
- `Locale.current.measurementSystem` → `.metric` = kg/cm, `.us`/`.uk` = lbs/ft
- Stored in `UserAttributes.weightFormat` and `heightFormat`
- Overridable in Settings
