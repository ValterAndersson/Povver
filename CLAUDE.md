# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Sub-Agent Configuration

When spawning sub-agents via the Task tool, always pass `model: "opus"` (Opus 4.6). The default model is not available in this environment.

---

## Engineering Philosophy

You have strong reasoning capabilities. This document is not a checklist to execute — it is a framework for thinking. The goal is good judgment, not compliance.

**The core tension you must hold:** Move fast enough to be useful. Move carefully enough not to create debt that costs more than the feature was worth.

When in doubt, ask yourself: *if a senior engineer reviewed this tomorrow, would they understand why every decision was made — and would they agree it was the right call given the constraints?*

---

## Task Startup Sequence

Before writing any code:

1. **Read central docs.** Start with `docs/SYSTEM_ARCHITECTURE.md` and `docs/SECURITY.md`. Then read the module-specific doc for the layer you are working in:
   - iOS: `docs/IOS_ARCHITECTURE.md`
   - Firebase Functions: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
   - Agent system: `docs/SHELL_AGENT_ARCHITECTURE.md`
   - Catalog orchestrator: `docs/CATALOG_ORCHESTRATOR_ARCHITECTURE.md`
2. **Read directory-level `ARCHITECTURE.md`** files in the directories you will modify.
3. **Read the source files** you intend to change, and the adjacent files that call into or are called by them.
4. **Identify cross-layer impact.** A change that touches data shape likely spans Firestore schema, Firebase Function, iOS model, and possibly agent tools. See [Cross-Stack Checklist](#cross-stack-checklist).
5. **Create a plan.** State what changes, where, and why. Pick one approach and justify it — don't present a menu.
6. **Self-challenge before executing:** Is every change necessary? Am I solving the actual problem or a generalized version of it? Am I making assumptions I should instead ask about?

---

## How to Think About Implementation

### Scope
Solve what was requested — not a simplified version, not an extended version. If you spot a related problem while working, **name it, don't fix it silently.** One sentence is enough: *"Note: X is also doing Y incorrectly — out of scope here, but worth a follow-up."* Surface debt without accumulating it.

### Complexity
The right amount of complexity is the minimum required for the system to work correctly, be understood by the next reader, and be changed safely later. Everything beyond that is a liability. Before adding a library, an abstraction, or a new pattern — ask whether the existing approach is genuinely insufficient. If it is, say why.

### Ambiguity
If a requirement is unclear or a design choice has user-visible tradeoffs, **ask before implementing.** A one-shot implementation with upfront clarification is almost always better than rework. Partial implementations that need correction cost more than the time saved by starting.

### Error Handling
Catching an error and logging it is not error handling — it is deferred failure with a paper trail. For every external call (Firestore, API, file system), ask: *what does the system do when this fails at 2am with no one watching?* The answer must be intentional. The appropriate response varies by context; the requirement to have one does not.

### Configuration
If a value could vary by environment, user, or time — it is configuration, not code. Use environment variables. Name your constants. Magic strings and numbers buried in implementation are future bugs waiting for the worst moment.

### Production Readiness
Not everything needs to be production-ready. But always be honest about the difference. If an implementation has known failure modes under real conditions — concurrency, data volume, concurrent writes — say so in a comment or task summary. The user can decide whether the tradeoff is acceptable; they cannot decide if they don't know the tradeoff exists.

For Firestore: queries filtering or ordering on non-default fields need an index. Queries that could return unbounded results need a `LIMIT`. Collections that grow with user data need pagination. Flag these if they are missing.

### Refactoring
If the cleanest correct implementation requires touching something adjacent that is currently wrong, flag the tradeoff. Don't refactor unrequested — but don't pretend the problem isn't there. Give the user the choice; they may have context you don't.

---

## How to Think About Documentation

Documentation is code for humans. Apply the same standards.

**Write what is true now.** Docs that describe a past or aspirational state are actively harmful — they mislead the next agent or engineer. If you change behavior, update the docs in the same task.

**Explain decisions, not just outcomes.** A doc that says "we use X" is less useful than one that says "we use X because Y — the alternative was Z but it has this tradeoff." Future readers need to know whether the constraint still applies before they change anything.

**Write for the next agent reading cold.** Every architecture doc should let a capable agent understand the module without reading every file. If it doesn't, it isn't doing its job.

**Don't over-document.** Annotate what isn't obvious — the constraint, the tradeoff, the non-obvious dependency. A long doc that covers everything equally is harder to use than a shorter one that emphasizes what matters.

**Documentation tiers — update all affected tiers when modifying code:**

- **Tier 1 — Central (`docs/`):** System architecture and cross-layer data flow. Update when a change affects cross-layer interaction, adds/removes an endpoint, or alters a shared data shape.
- **Tier 2 — Directory (`ARCHITECTURE.md`):** Module-level architecture. Update when adding/removing files or changing how components within a module interact. Create one whenever you create a new module directory.
- **Tier 3 — Inline annotations:** Code-level context. Focus on: complex logic, security-critical paths, cross-file dependencies, intentional constraints. Skip the obvious.

---

## Code Style and Conventions

Layer-specific conventions are the authoritative source for how to write code in each part of the stack. Read them before modifying any layer.

**Quick reference — highest-stakes rules:**

- **Firebase Functions:** Use `ok()`/`fail()` from `utils/response.js`. Derive userId from `req.auth.uid` only in bearer-lane endpoints. Wrap all read-then-write in `runTransaction`. Use `serverTimestamp()` for Firestore writes.
- **Python:** No bare `except:`. `ContextVar` for request state, never module globals. Type hints on all public signatures.
- **Swift:** Business logic in ViewModels, not Views. Cancel Tasks in `.onDisappear`. Design tokens for all spacing, color, and typography.
- **All layers:** Introduce new patterns only when existing ones are genuinely insufficient — and document why.

**On comments:** Annotate *why*, not *what*. The constraint, the tradeoff, the non-obvious dependency — not what the code already shows.

---

## Security

These are non-negotiable. When in doubt, read `docs/SECURITY.md` before proceeding. Security mistakes in this system are potential data breaches or revenue integrity failures — not just bugs.

- **IDOR:** Every endpoint uses `getAuthenticatedUserId(req)` from `utils/auth-helpers.js`. Never derive userId from `req.body` in bearer-lane endpoints.
- **Subscription fields:** Only Admin SDK writes `subscription_*` fields. Never add client-write paths for subscription data.
- **Premium gates:** Always call `isPremiumUser(userId)` server-side. Never trust client claims.
- **Input validation:** Validate all inputs with upper bounds before any business logic. See `utils/validators.js`.
- **New endpoints:** Auth middleware, userId derivation, input validation, rate limiting, Firestore rules — all required. See `docs/SECURITY.md`.
- **New Firestore collections:** Must be added to `firestore.rules`. The deny-all fallback blocks anything not explicitly listed.
- **Webhook verification:** App Store webhooks are JWS-verified in production. Never bypass outside the emulator.

---

## Finishing a Task

End every task with a clean commit. The codebase must be in a stable, buildable state. If you identified out-of-scope issues during the task, note them briefly in the commit message so they aren't lost.

---

## Secrets & Service Account Keys

All secrets live outside the repo at `~/.config/povver/` (chmod 600). Sourced automatically via `~/.zshrc`.

| Env Var | Use |
|---------|-----|
| `FIREBASE_API_KEY` | Firebase Web API key |
| `MYON_API_KEY` | Server-to-server API key |
| `FIREBASE_SA_KEY` | Firebase Admin SDK — scripts, emulators, local functions |
| `GCP_SA_KEY` | GCP service account — agent deploy, Cloud Run, Vertex AI |

```bash
export GOOGLE_APPLICATION_CREDENTIALS=$FIREBASE_SA_KEY  # Firebase/Firestore work
export GOOGLE_APPLICATION_CREDENTIALS=$GCP_SA_KEY       # GCP/Vertex AI work
```

Do NOT change ADC (`~/.config/gcloud/application_default_credentials.json`) — it is used for Claude billing.

**Never commit key files or API keys.** `.gitignore` blocks `config/`, `.env`, and `GoogleService-Info.plist`.

---

## Build & Development Commands

### iOS
```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

### Firebase Functions
```bash
cd firebase_functions/functions
npm install && npm test
npm run serve   # emulators: functions:5001, firestore:8085, UI:4000
npm run deploy
```

### Agent System (Canvas Orchestrator)
```bash
cd adk_agent/canvas_orchestrator
make install | deploy | dev | test | lint | format | check | chat
```
`make deploy` resolves the GCP SA key from `$GOOGLE_APPLICATION_CREDENTIALS` → `$GCP_SA_KEY` → hardcoded fallback. The SA (`ai-agents@myon-53d85.iam.gserviceaccount.com`) must have `roles/aiplatform.user`.

### Training Analyst
```bash
cd adk_agent/training_analyst
make install | worker-local | trigger-worker
```

### Utility Scripts
```bash
node scripts/import_strong_csv.js      # import Strong CSV workout data
node scripts/seed_simple.js            # seed Firestore test data
node scripts/purge_user_data.js        # purge user data
node scripts/backfill_set_facts.js     # backfill set_facts + series from workouts
node scripts/backfill_analysis_jobs.js # backfill training analysis
```

---

## Cross-Stack Checklist

When adding a new field or data shape, update all affected layers:

1. **Firestore schema** → `docs/FIRESTORE_SCHEMA.md`
2. **Firebase Function write path** → e.g., `create-routine-from-draft.js`
3. **Firebase Function read path** → e.g., `get-routine.js`
4. **iOS Model** → `Povver/Povver/Models/*.swift` (`Codable` with `decodeIfPresent` + default)
5. **iOS UI** → relevant views
6. **Agent tools** → `app/skills/*.py` (if agent reads/writes the field)
7. **Documentation** → all three tiers as applicable

---

## Deprecated (Do Not Use)

| Deprecated | Replacement |
|------------|-------------|
| `adk_agent/canvas_orchestrator/_archived/` | Shell Agent (`app/shell/`) |
| `canvas/apply-action.js` and all `canvas/*.js` | Artifacts via `stream-agent-normalized.js` + `artifacts/artifact-action.js` |
| `CanvasRepository.swift` | Artifacts from SSE events in `CanvasViewModel` |
| `routines/update-routine.js` | `routines/patch-routine.js` |
| `templates/update-template.js` | `templates/patch-template.js` |
| Field `templateIds` | `template_ids` (snake_case everywhere) |
| Field `weight` in workout sets | `weight_kg` (templates still use `weight` as a prescription value) |
| `docs/platformvision.md` | `SYSTEM_ARCHITECTURE.md`, `IOS_ARCHITECTURE.md`, `SHELL_AGENT_ARCHITECTURE.md` |