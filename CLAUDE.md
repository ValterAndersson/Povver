# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Sub-Agent Configuration

When spawning sub-agents via the Task tool, always pass `model: "sonnet"` (Sonnet 4.6). The default haiku model is not available in this environment.

## Agent Working Protocol

### Task Startup Sequence

Before writing any code, execute these steps in order:

1. **Read central docs.** Start with `docs/SYSTEM_ARCHITECTURE.md` (cross-layer data flows, schema contracts, auth patterns) and `docs/SECURITY.md` (security invariants, auth model, input validation, rate limiting). Then read the module-specific doc for whichever layer you are working in:
   - iOS: `docs/IOS_ARCHITECTURE.md`
   - Firebase Functions: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
   - Agent system: `docs/SHELL_AGENT_ARCHITECTURE.md`
   - Catalog orchestrator: `docs/CATALOG_ORCHESTRATOR_ARCHITECTURE.md`
2. **Read directory-level `ARCHITECTURE.md`** files in the directories you will modify.
3. **Read the source files** you intend to change. Understand adjacent files that call into or are called by them.
4. **Identify which layers are affected.** A change that touches data shape likely spans Firestore schema, Firebase Function, iOS model, and possibly agent tools. See [Cross-Stack Checklist](#cross-stack-checklist).
5. **Create a plan.** State what changes, where, and why. Explain any significant architectural decision. If there are multiple valid approaches, pick one and state why.
6. **Self-challenge before executing:**
   - Is every change necessary, or am I adding speculative scope?
   - Am I over-engineering? Would a simpler approach work?
   - Does this align with what was actually requested?
   - Am I making assumptions about unclear requirements? If yes — **ask the user** instead of guessing.

### Implementation Rules

- **Solve only what is requested.** No speculative features, no "while we're here" refactors, no unnecessary abstractions.
- **Justify added complexity.** If introducing a third-party library or a new pattern, explain why the native/existing approach is insufficient. The simplest native solution is the default.
- **Ask, don't guess.** If requirements are ambiguous, or if a design choice has user-visible tradeoffs, ask for clarification before implementing.
- **Bias toward one-shot implementations.** Prefer slightly more upfront planning and clarification over incremental trial-and-error. If a plan is uncertain, pause and ask rather than implement a partial solution.

### Code Style

- **Python** (agent system): PEP 8, line length 100. Enforced by `flake8` and `black`. Run `make lint` and `make format` in `adk_agent/catalog_orchestrator/`.
- **JavaScript** (Firebase Functions): Standard conventions. Use `const` by default, `require()` imports, `async/await` for all async operations. Response helpers: `ok(res, data)` / `fail(res, code, message, details, httpStatus)` from `utils/response.js`.
- **Swift** (iOS): Follow existing patterns. Models use `Codable` with `decodeIfPresent` + defaults for resilience. Use `@DocumentID` for Firestore doc IDs.
- **All languages**: Functions should be modular. Names should be descriptive. Patterns should be simple. Annotate complex or security-critical sections with structured comments explaining *what* and *why* (not change history).

### Layer-Specific Conventions

These conventions address recurring inconsistencies found across the codebase. Follow them for all new code and when modifying existing files.

#### Firebase Functions

- **Responses**: Always use `ok(res, data)` / `fail(res, code, message, details, httpStatus)` from `utils/response.js`. Never use raw `res.status().json()`.
- **Logging**: Use `const { logger } = require("firebase-functions");` — never `console.log/error`. Include context: `logger.info("[functionName] action", { userId, resourceId })`.
- **Auth — userId derivation**: In bearer-lane endpoints (`requireFlexibleAuth`), derive userId from `req.auth.uid` only. Never fall back to `req.body.userId` or `req.query.userId` — that path is for API-key-lane (`withApiKey`) only.
- **Timestamps**: Use `admin.firestore.FieldValue.serverTimestamp()` for Firestore writes (`created_at`, `updated_at`). Use ISO strings (`new Date().toISOString()`) only for state history arrays or immediate-use values. Never store raw `new Date()` objects.
- **Transactions**: Any read-then-write to Firestore must be inside a `runTransaction`. Reads outside the transaction followed by writes inside it are a race condition. Structured errors from transactions: `throw { httpCode: 404, code: "NOT_FOUND", message: "..." }`.
- **Input validation**: Validate request parameters before any business logic. Prefer Zod schemas (see `log-set.js`) for structured input. At minimum, check required fields and return `fail()` with `INVALID_ARGUMENT`.
- **v2 function pattern**: Self-contained with `onRequest` from `firebase-functions/v2/https`, auth middleware built-in, exported directly from handler file (`exports.fn = fn;`).

#### Python (Agent System)

- **Logging**: Use `logger = logging.getLogger(__name__)` at module level. Use structured JSON for production events: `logger.info(json.dumps({"event": "...", "key": "value"}))`. Reserve `logger.debug()` for development-only output.
- **Exception handling**: Never use bare `except:`. Always catch specific exceptions. Return `SkillResult(success=False, error=...)` for business logic failures; raise exceptions for infrastructure/config errors.
- **Type hints**: Required on all public function signatures (arguments and return type).
- **Request state**: Use `ContextVar` for per-request state — never module-level globals. Module-level singletons (clients, config) are acceptable when they are stateless.
- **Imports**: Order: `from __future__ import annotations`, stdlib, third-party, local. Use `from __future__ import annotations` in all files.

#### Swift (iOS)

- **MVVM boundary**: All business logic, data fetching, and state mutations belong in ViewModels. Views handle only layout and forwarding user events. If a View file exceeds ~300 lines, that is a signal to extract logic into a ViewModel.
- **Task lifecycle**: Store `Task` references and cancel them in `.onDisappear`, or use the `.task { }` modifier (which auto-cancels). Never create fire-and-forget `Task { }` blocks in Views.
- **Error surfacing**: Every ViewModel that performs async work must expose `@Published var errorMessage: String?` for the View to display.
- **Singleton observation**: Use `@ObservedObject` for `.shared` singletons (they are owned elsewhere). Use `@StateObject` only when the View creates and owns the object.
- **Design tokens**: Always use `Space.*` for spacing, `Color.*` tokens for colors, and `TypographyToken.*` for fonts. No hardcoded numeric spacing, color literals, or `.system(size:)` font calls.
- **Listener cleanup**: Store `ListenerRegistration` references from Firestore snapshot listeners and call `.remove()` in a cleanup method or `deinit`.
- **Naming**: `*Screen` for full-screen navigation destinations, `*View` for reusable components, `*Service` for external API/Firebase interactions, `*Manager` for internal state management, `*Repository` for data access.

### Security Rules

These are non-negotiable. See `docs/SECURITY.md` for full details.

- **IDOR prevention**: Every endpoint must use `getAuthenticatedUserId(req)` from `utils/auth-helpers.js`. Never derive userId from `req.body.userId` in bearer-lane endpoints.
- **Subscription fields**: Only Admin SDK (webhook, Cloud Functions) writes `subscription_*` fields. Firestore rules block client writes. Never add client-write paths for subscription data.
- **Premium gates**: Premium features must call `isPremiumUser(userId)` from `utils/subscription-gate.js` server-side. Never trust client claims of premium status.
- **Input validation**: All write endpoints must validate input with upper bounds (see `utils/validators.js`). Agent streaming enforces a 10KB message limit.
- **New endpoints**: Follow the security checklist in `docs/SECURITY.md` — auth middleware, userId derivation, input validation, rate limiting, Firestore rules.
- **New Firestore collections**: Must be added to `firestore.rules` with appropriate access controls. The deny-all fallback blocks any collection not explicitly listed.
- **Token exchange scope**: `exchange-token.js` must use `cloud-platform` scope. Vertex AI Agent Engine does not accept narrower scopes.
- **Webhook verification**: App Store webhooks are JWS-verified in production. Never disable or bypass verification outside the emulator.

### Documentation Updates (Three Tiers)

When modifying code, update **all affected tiers**. All documentation describes **how the system works now** — not a changelog. Exception: major architectural shifts should be noted briefly for strategic awareness.

**Tier 1 — Central (`docs/`): System architecture and data flow.**
Update when: a change affects cross-layer interaction, adds/removes an API endpoint, or alters a shared data shape (Firestore schema, SSE event format, auth pattern).

**Tier 2 — Directory (`ARCHITECTURE.md` in module directories): Module-level architecture.**
Update when: adding/removing files, changing internal responsibilities, or altering how components within the module interact. Each major directory should have an `ARCHITECTURE.md` that lets an agent understand the module without reading every file. Covers: file structure, entry points, internal patterns, how concepts work together. When creating a new module directory, always create a Tier 2 `ARCHITECTURE.md`. These docs cover only module-internal concerns — they are not copies of central docs. Exception: project-root directories that already have `README.md` (e.g., `firebase_functions/functions/README.md`) may keep that name.

**Tier 3 — File-level (inline annotations): Code-level context.**
Focus on:
- Complex logic that isn't self-evident from the code
- Security-critical sections (auth boundaries, userId derivation)
- Cross-file dependencies (e.g., `// Called by canvas/apply-action.js when action type is SAVE_ROUTINE`)
- Intentional constraints (e.g., `// ContextVar required — module globals leak across concurrent requests on Vertex AI`)

Do not annotate trivial code.

### Finishing a Task

End every task with a clean commit. The codebase must be in a stable, buildable state after your changes.

---

## Secrets & Service Account Keys

All secrets live outside the repo at `~/.config/povver/` (chmod 600). Sourced automatically via `~/.zshrc`.

### API Keys

Loaded from `~/.config/povver/env.sh` (sourced by `~/.zshrc`):

| Env Var | Use |
|---------|-----|
| `FIREBASE_API_KEY` | Firebase Web API key — agent deploy, scripts |
| `MYON_API_KEY` | Server-to-server API key — agent calls to Firebase Functions |

### Service Account Keys

Set `GOOGLE_APPLICATION_CREDENTIALS` to the correct one before running a command:

| Env Var | Key File | Use |
|---------|----------|-----|
| `FIREBASE_SA_KEY` | `~/.config/povver/myon-53d85-firebase-adminsdk-fbsvc-ca7beb1435.json` | Firebase Admin SDK — scripts, emulators, local functions |
| `GCP_SA_KEY` | `~/.config/povver/myon-53d85-80792c186dcb.json` | GCP service account — agent deploy, Cloud Run, Vertex AI |

**How to use:** Google SDKs read `GOOGLE_APPLICATION_CREDENTIALS`. Set it to the appropriate named var:

```bash
# Firebase / Firestore work (scripts, functions, emulators)
export GOOGLE_APPLICATION_CREDENTIALS=$FIREBASE_SA_KEY

# GCP work (agent deploy, Cloud Run, Vertex AI)
export GOOGLE_APPLICATION_CREDENTIALS=$GCP_SA_KEY
```

All vars are set in `~/.zshrc` (SA key paths) and `~/.config/povver/env.sh` (API keys, sourced by `~/.zshrc`).

**Never commit key files or API keys to the repo.** `.gitignore` blocks `config/`, `.env`, and `GoogleService-Info.plist`.

---

## Build & Development Commands

### iOS
```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

### Firebase Functions
```bash
cd firebase_functions/functions
npm install                    # install dependencies
npm test                       # node --test ./tests/**/*.test.js
npm run serve                  # firebase emulators (functions:5001, firestore:8085, UI:4000)
npm run deploy                 # deploy to production
```

### Agent System (Canvas Orchestrator)

**Deploy to Vertex AI:** `make deploy` auto-resolves the GCP SA key in this order:
1. `$GOOGLE_APPLICATION_CREDENTIALS` (if set and file exists)
2. `$GCP_SA_KEY` (shell alias from `~/.zshrc`)
3. `~/.config/povver/myon-53d85-80792c186dcb.json` (hardcoded fallback)

The SA (`ai-agents@myon-53d85.iam.gserviceaccount.com`) must have `roles/aiplatform.user`.
Do NOT change ADC (`~/.config/gcloud/application_default_credentials.json`) — it's used for Claude billing.

```bash
cd adk_agent/canvas_orchestrator
make install       # pip install dependencies
make deploy        # deploy to Vertex AI Agent Engine (uses GCP SA key)
make dev           # local API server (adk api_server app)
make test          # pytest tests/ -v
make lint          # flake8 --max-line-length=100
make format        # black --line-length=100
make check         # compile-check all Python files
make chat          # interactive chat session
make deploy        # deploy to Vertex AI Agent Engine
```

### Training Analyst
```bash
cd adk_agent/training_analyst
make install       # pip install dependencies
make worker-local  # run analyst worker locally
make trigger-worker # trigger Cloud Run worker
```

### Utility Scripts
```bash
node scripts/import_strong_csv.js     # import Strong CSV workout data
node scripts/seed_simple.js           # seed Firestore test data
node scripts/purge_user_data.js       # purge user data
node scripts/backfill_set_facts.js    # backfill set_facts + series from workouts
node scripts/backfill_analysis_jobs.js # backfill training analysis (post-workout, weekly, daily)
```

---

## Cross-Stack Checklist

When adding a new field or data shape, update across all affected layers:

1. **Firestore schema** → `docs/FIRESTORE_SCHEMA.md`
2. **Firebase Function write path** → e.g., `create-routine-from-draft.js`, `stream-agent-normalized.js`
3. **Firebase Function read path** → e.g., `get-routine.js`, `get-planning-context.js`
4. **iOS Model** → `Povver/Povver/Models/*.swift` (ensure `Codable` with `decodeIfPresent` + default)
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
