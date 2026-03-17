# Architecture Redesign: Shared Data Layer, Agent Rearchitecture, MCP Server

**Date:** 2026-03-17
**Status:** Design — pending implementation plan
**Supersedes:** `docs/plans/2026-03-04-performance-scalability-implementation.md` (Phase 0 Observability retained; remaining phases replaced by this design)

---

## 1. Problem Statement

Povver's current architecture has four structural issues that limit scalability, development velocity, and coaching quality:

1. **Circular agent dependency.** The AI agent (Vertex AI Agent Engine) calls back to Firebase Functions via HTTP for every tool call. Each tool call adds 200-500ms of network overhead. A single agent response requires 2-5 round-trips through the Firebase Function layer.

2. **Vertex AI Agent Engine lock-in.** Sessions, routing, tool execution, and deployment are all managed by Google's runtime and the ADK framework. Switching LLM providers (Claude, GPT) requires rewriting the entire agent layer. ADK imposes constraints that require workarounds (ContextVar thread boundaries, callback-based usage tracking, thinking token budget conflicts).

3. **Trigger cascade fragility.** Workout completion fires 8 synchronous Firestore write operations via a single trigger. Partial failures leave data inconsistent. Concurrent completions cause transaction contention on shared documents (weekly_stats).

4. **No shared data access layer.** Business logic is embedded in Firebase Function HTTP handlers. The agent duplicates data access via HTTP calls. Adding new consumers (MCP for external LLMs) would require a third implementation of the same operations.

**Constraints:**
- No active users — breaking changes are acceptable.
- $0 revenue — no recurring monthly costs (no minInstances, no Redis). Scaling configuration is deferred to a "flip-the-switch" phase when revenue justifies spend.
- The Firebase Functions architecture is sound — patterns (auth lanes, response helpers, transactions, idempotency) are retained. This is a restructuring, not a rewrite.
- The iOS app is solid — cleanup follows, but no rearchitecture needed.

---

## 2. Architecture Overview

Three transports share a common business logic layer. The AI agent moves from a managed Vertex AI runtime to a stateless Cloud Run service with direct Firestore access.

```
┌─────────────┐     ┌──────────────────────────────────────────────┐
│  iOS App    │──HTTP──▶  Firebase Functions (Node.js)             │
└─────────────┘     │    Auth + validation + response formatting   │
                    │    Imports shared business logic modules      │
                    └──────────────┬───────────────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────────────┐
                    │       Shared Business Logic (Node.js)         │
                    │    firebase_functions/functions/shared/       │
                    │    Pure functions: validate, query, mutate    │
                    │    Firebase Admin SDK for Firestore access    │
                    │    No HTTP, no req/res, no auth middleware    │
                    └──────────────┬───────────────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────────────┐
                    │         MCP Server (Node.js, Cloud Run)       │
                    │    Imports same shared business logic          │
                    │    Per-user API key auth                      │
                    │    Multi-tenant, scale-to-zero                │
                    └──────────────────────────────────────────────┘

┌─────────────┐     ┌──────────────────────────────────────────────┐
│  iOS App    │──SSE──▶  Firebase Function (thin SSE proxy)        │
└─────────────┘     │    Auth, premium gate, rate limiting          │
                    │    SSE relay + event transformation           │
                    └──────────────┬───────────────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────────────┐
                    │     Agent Service (Python, Cloud Run)         │
                    │    Stateless — no sessions, no pre-warming    │
                    │    Direct Firestore via Firebase Admin SDK    │
                    │    Model-agnostic (Gemini / Claude / GPT)     │
                    │    Keeps: 4-lane router, skills, instruction  │
                    │    Drops: ADK, Vertex AI Agent Engine         │
                    └──────────────────────────────────────────────┘
```

**Key decisions:**

1. **Node.js shared logic** for Firebase Functions + MCP Server (same language, direct imports, zero code duplication for CRUD/query operations).
2. **Python agent with Firebase Admin SDK** for direct Firestore reads. The Firestore schema is the shared contract between the Node.js and Python layers.
3. **SSE proxy Firebase Function stays** as a thin layer — auth, premium gate, rate limiting, event transformation. It calls the Cloud Run agent service instead of Vertex AI.
4. **Model-agnostic LLM client.** Gemini, Claude, GPT — configured per lane or environment.
5. **No sessions.** Conversation history lives in Firestore. Agent memory provides cross-conversation continuity. Session pre-warming, cleanup, and version tracking are eliminated.

---

## 3. Shared Business Logic Extraction

### Pattern

Firebase Function handlers currently mix transport (auth, req/res), validation/business logic, and response formatting. The business logic is extracted into pure functions that any transport can call.

**Before:**
```javascript
// routines/get-routine.js (today)
async function getRoutineHandler(req, res) {
  const userId = req.auth.uid;
  const { routineId } = req.body;
  if (!routineId) return fail(res, 'INVALID_ARGUMENT', '...');
  const doc = await db.doc(`users/${userId}/routines/${routineId}`).get();
  if (!doc.exists) return fail(res, 'NOT_FOUND', '...');
  return ok(res, { routine: { id: doc.id, ...doc.data() } });
}
```

**After:**
```javascript
// shared/routines.js (pure business logic)
async function getRoutine(userId, routineId) {
  if (!routineId) throw new ValidationError('routineId required');
  const doc = await db.doc(`users/${userId}/routines/${routineId}`).get();
  if (!doc.exists) throw new NotFoundError('Routine not found');
  return { id: doc.id, ...doc.data() };
}

// routines/get-routine.js (thin HTTP wrapper)
async function getRoutineHandler(req, res) {
  try {
    const routine = await getRoutine(req.auth.uid, req.body.routineId);
    return ok(res, { routine });
  } catch (e) { return mapErrorToResponse(res, e); }
}
```

### Modules

| Module | Operations | Consumers |
|--------|-----------|-----------|
| `shared/routines.js` | get, list, create, patch, delete, getActive, setActive, getNextWorkout | Functions, MCP |
| `shared/templates.js` | get, list, create, patch, delete, createFromPlan | Functions, MCP |
| `shared/workouts.js` | get, list (paginated), upsert, delete | Functions, MCP |
| `shared/exercises.js` | get, list, search, resolve | Functions, MCP |
| `shared/training-queries.js` | querySets, aggregateSets, getAnalysisSummary, getMuscleGroupSummary, getExerciseSummary | Functions, MCP |
| `shared/planning-context.js` | getPlanningContext (user profile + history + routine state + strength summary) | Functions, MCP |
| `shared/artifacts.js` | getArtifact, acceptArtifact, dismissArtifact, saveRoutineFromArtifact, saveTemplateFromArtifact, startWorkoutFromArtifact | Functions |
| `shared/progressions.js` | applyProgression, suggestWeightIncrease, suggestDeload (with changelog + recommendation audit trail) | Functions |
| `shared/errors.js` | ValidationError, NotFoundError, PermissionError | All |

**Note on intentional duplication:** The Python agent service has its own `FirestoreClient` with equivalent query logic for `get_planning_context`, `get_routine`, etc. This is intentional — the Node.js shared modules serve Firebase Functions and MCP; the Python equivalents serve the agent. The Firestore schema is the shared contract. Both implementations read/write the same collections with the same document shapes. This avoids a cross-language dependency while maintaining data consistency.

**Not extracted (stays Firebase Function-only):**
- Active workout mutations (log_set, complete, patch) — hot path, complex state machine with Zod validation, idempotency guards, and concurrent-set protection. Both iOS and the agent call these via HTTP.
- Subscription management — webhook verification, StoreKit sync
- SSE streaming proxy — iOS transport concern
- Firestore triggers and scheduled jobs — internal event handling
- Canvas/conversation management (open, bootstrap, purge) — see conversation lifecycle changes in Section 5

### Error Contract

Shared functions throw typed errors. Each transport maps them to its own format:

| Error Type | HTTP (Functions) | MCP |
|------------|-----------------|-----|
| `ValidationError` | 400 + `INVALID_ARGUMENT` | MCP InvalidParams |
| `NotFoundError` | 404 + `NOT_FOUND` | MCP error with code |
| `PermissionError` | 403 + `FORBIDDEN` | MCP error with code |

---

## 4. Agent Rearchitecture

### What We Keep

These are Povver's code, not ADK's — they transfer directly:

- **4-lane router** (`router.py`) — Fast/Slow/Functional/Worker routing logic
- **Skills** (`skills/*.py`) — business logic, refactored for direct Firestore access
- **Instruction** (`instruction.py`) — coaching persona, refactored for model-agnostic format
- **Safety gate** (`safety_gate.py`) — write confirmation flow
- **Tool planner** (`planner.py`) — execution planning for complex intents
- **Critic** (`critic.py`) — response validation

### What We Drop

- ADK framework (`google-adk`, `google-cloud-aiplatform` dependencies)
- Vertex AI Agent Engine managed runtime
- `AgentEngineApp(AdkApp)` class and all ADK callback workarounds
- Session management: `initialize-session.js`, `pre-warm-session.js`, `cleanup-sessions.js`
- ContextVar thread-boundary hacks (ADK's Runner spawns separate threads)
- `SessionPreWarmer.swift` on iOS
- `users/{uid}/agent_sessions/` Firestore collection
- `AGENT_VERSION` constant and version-forced session resets

### What We Add

#### LLM Client Abstraction

```python
class LLMClient(Protocol):
    async def stream(self, model, messages, tools, config) -> AsyncIterator[LLMChunk]: ...

class GeminiClient(LLMClient): ...   # google-genai SDK
class ClaudeClient(LLMClient): ...   # anthropic SDK
class OpenAIClient(LLMClient): ...   # openai SDK
```

Lane-level model configuration:
```python
LANE_MODELS = {
    "slow": "gemini-2.5-flash",       # or "claude-sonnet-4-6"
    "functional": "gemini-2.5-flash",  # low-temp JSON mode
}
```

#### Agent Loop (replaces ADK's Runner)

```python
MAX_TOOL_TURNS = 12  # Safety limit — bail out if model loops

async def run_agent_loop(model, instruction, history, message, tools, ctx):
    messages = build_messages(instruction, history, message)
    turn = 0

    while turn < MAX_TOOL_TURNS:
        tool_calls = []
        async for chunk in llm_client.stream(model, messages, tools):
            if chunk.is_text:
                yield sse_event("message", chunk.text)
            elif chunk.is_tool_call:
                tool_calls.append(chunk)

        # No tool calls — model is done
        if not tool_calls:
            yield sse_event("done", {})
            return

        # Execute all tool calls from this turn (handles parallel tool use)
        tool_results = []
        for tc in tool_calls:
            yield sse_event("tool_start", tc.tool_name)
            try:
                result = await execute_tool(tc.tool_name, tc.args, ctx)
            except Exception as e:
                result = {"error": str(e)}  # Model sees error, can recover
            yield sse_event("tool_end", tc.tool_name)
            tool_results.append(tool_result(tc, result))

        messages.extend(tool_results)
        turn += 1

    # Exceeded max turns — send a graceful termination
    yield sse_event("message", "I've reached my reasoning limit for this request. "
                               "Please try rephrasing or breaking your question into parts.")
    yield sse_event("done", {})
```

Handles: parallel/batch tool calls, tool execution errors (returned to model for recovery), and max iteration guard. Production implementation will add request timeouts, client disconnect detection (SSE heartbeats), usage tracking, conversation persistence, structured logging, and graceful shutdown — but the core loop above is the complete control flow that replaces ADK's Runner.

**Usage tracking:** Each LLM turn extracts `usage_metadata` from the Gemini response (token counts) and calls `shared.usage_tracker.track_usage()` to persist to Firestore — directly replacing ADK's `after_model_callback` pattern. The `LLMChunk` protocol carries an optional `usage` field so the agent loop receives token counts without coupling to Gemini-specific APIs.

#### Context Window Management

The auto-loaded system context (Section 5) consumes ~2-4KB. Conversation history and tool results can grow unbounded. Strategy:

1. **Conversation history:** Load last 20 messages. If total context exceeds 80% of model's window, truncate oldest messages first.
2. **Tool results:** Large results (>4KB) are summarized before appending to messages. The full result is still available to the current tool handler.
3. **Agent memories:** Capped at 50 most recent active memories (see Section 5). At ~50 bytes per memory, this is ~2.5KB.
4. **Model-specific limits:** The LLM client abstraction reports `max_context_tokens` per model. The message builder truncates to fit.

#### Direct Firestore Access

Uses `google-cloud-firestore` **AsyncClient** to avoid blocking the event loop (the sync client would block on every Firestore call, defeating the async agent loop):

```python
from google.cloud.firestore import AsyncClient

class FirestoreClient:
    def __init__(self):
        self.db = AsyncClient()

    async def get_planning_context(self, user_id: str) -> dict:
        user_doc = await self.db.document(f"users/{user_id}").get()
        routines = self.db.collection(f"users/{user_id}/routines").stream()
        templates = self.db.collection(f"users/{user_id}/templates").stream()
        # ... assemble context

    async def get_routine(self, user_id: str, routine_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}/routines/{routine_id}").get()
        if not doc.exists: raise NotFoundError("Routine not found")
        return {"id": doc.id, **doc.to_dict()}

    async def get_active_snapshot_lite(self, user_id: str) -> dict:
        # Active routine, streak, week summary — lightweight context
        ...

    async def get_active_events(self, user_id: str, limit: int = 10) -> list:
        # Recent training events (workout completed, PR achieved, etc.)
        ...
```

Replaces `CanvasFunctionsClient` (HTTP client to Firebase Functions, 31 methods). All 31 methods are reimplemented as direct Firestore queries except active workout mutations (retained as HTTP).

#### Cloud Run API Contract

**Endpoint:** `POST /stream`

**Request body:**
```json
{
  "user_id": "string",
  "conversation_id": "string",
  "message": "string",
  "correlation_id": "string",
  "workout_id": "string | null"
}
```

- `correlation_id` — end-to-end request tracing (proxy generates UUID if iOS doesn't provide one)
- `workout_id` — present when user has an active workout; enables workout mode context loading

**Auth:** IAM-authenticated. The SSE proxy Firebase Function calls Cloud Run with an identity token (`Authorization: Bearer <id_token>`). The Cloud Run service validates the token via IAM — no custom auth logic needed.

**SSE event types emitted:**

| Event | Data | Purpose |
|-------|------|---------|
| `message` | `{ "text": "..." }` | Streamed text chunk |
| `tool_start` | `{ "tool": "get_routine", "call_id": "..." }` | Tool execution began |
| `tool_end` | `{ "tool": "get_routine", "call_id": "..." }` | Tool execution completed |
| `artifact` | `{ "type": "routine", "data": {...} }` | Artifact for iOS to render |
| `clarification` | `{ "question": "...", "options": [...] }` | Safety gate confirmation request |
| `status` | `{ "text": "..." }` | Non-streamed status update (e.g., "Analyzing your training data...") |
| `heartbeat` | `{}` | Connection keepalive (every 15s during long tool calls) |
| `done` | `{}` | Stream complete |
| `error` | `{ "code": "...", "message": "..." }` | Unrecoverable error |

**Event contract cleanup:** iOS currently handles 15 event types from the ADK/Vertex AI era. This redesign standardizes to 9 types. Dropped types: `thinking`, `thought` (ADK thinking indicators), `toolRunning`/`toolComplete` (renamed to `tool_start`/`tool_end`), `agentResponse` (redundant with `message`), `userPrompt`/`userResponse` (echo events), `pipeline` (ADK pipeline state), `card` (replaced by `artifact`). iOS `StreamEvent.swift` is updated in Phase 7 to match.

The SSE proxy relays these events to iOS with no transformation — the Cloud Run agent emits the exact format iOS expects.

#### Cloud Run Deployment

- Dockerfile + `make deploy` (same pattern as training_analyst)
- Region: `us-central1` (same as everything else)
- Scales to zero when idle — no cost when unused
- IAM-authenticated by the SSE proxy Firebase Function

### Skill Migration

Every skill is refactored, not just moved:

| Skill File | Current Backend | New Backend | Key Changes |
|-----------|----------------|-------------|-------------|
| `copilot_skills.py` | HTTP POST to Firebase Functions | HTTP POST to Firebase Functions (retained) | Active workout mutations are the one path where correctness > latency. The Firebase Functions have Zod validation, state machine logic, idempotency guards, and concurrent-set protection. The ~200ms HTTP overhead is invisible during workout rest periods. |
| `coach_skills.py` | HTTP to Firebase analysis endpoints | Direct Firestore queries | Same query logic, no HTTP serialization overhead |
| `planner_skills.py` | Returns artifact data in SkillResult | Writes artifact to `conversations/{id}/artifacts` + yields SSE event | More explicit, no proxy-side artifact detection |
| `workout_skills.py` | Singleton HTTP client (`_client_instance`) | Injected `FirestoreClient` | No singleton, no module-level state |
| `progression_skills.py` | HTTP POST to `applyProgression` Firebase Function | HTTP POST retained | Background progression (auto-apply, deload). Uses `MYON_API_KEY`. Called by agent for user-requested changes, by training analyst for automated progressions. |
| `tools.py` | ContextVar workarounds for ADK threads | Context passed as function args | Simpler, no ContextVar needed |
| `gated_planner.py` | Reads ContextVar for confirmation | Reads message from function args | Same logic, simpler implementation |

### Instruction Migration

The instruction (`instruction.py`, ~700 lines) is refactored:

1. **Remove Gemini-specific formatting** — make model-agnostic (no references to Gemini's extended thinking format)
2. **Simplify tool documentation** — instruction defines *when/why* to use tools; schemas define *how*
3. **Update examples** — match new tool call format, remove ADK-specific patterns
4. **Remove session-awareness** — no references to session state, agent version
5. **Add memory usage guidance** — when to save/retire memories, how to use conversation summaries
6. **Keep core coaching principles** — persona, response craft, weight prescription, workout mode rules

### SSE Proxy Changes

`stream-agent-normalized.js` changes:

- Calls Cloud Run agent service instead of Vertex AI Agent Engine `:streamQuery`
- Token exchange simplifies (Cloud Run IAM auth, not Vertex AI session auth)
- Session creation/reuse logic removed entirely
- Event relay simplifies (Cloud Run emits the 9-event contract directly, no transformation needed)
- Auth, premium gate, rate limiting all stay in the proxy

**Conversation initialization moves into the proxy:** The proxy now handles `conversation_id` resolution. If iOS sends no `conversation_id` (new chat), the proxy creates a `conversations/{id}` document and includes the ID in the Cloud Run request. This replaces `openCanvas`, `bootstrapCanvas`, and `initializeSession` — all deleted. The proxy also checks the 4-hour inactivity timeout: if the existing conversation's last message is >4 hours old and no active workout exists, it creates a new conversation instead.

**Deleted endpoints:** `openCanvas`, `bootstrapCanvas`, `initializeSession`, `preWarmSession`, `invokeCanvasOrchestrator`, `getServiceToken` — all obsoleted by the stateless architecture.

### Latency Impact

| Operation | Before (Vertex AI) | After (Cloud Run) |
|-----------|-------------------|-------------------|
| Tool call (e.g., get_planning_context) | ~400ms (HTTP to Firebase Function) | ~50ms (direct Firestore read) |
| Session setup | ~2s (create/reuse) | 0ms (stateless) |
| Cold start | ~5s (Vertex AI instance) | ~2s (Cloud Run container) |
| Pre-warming | Required | Eliminated |

---

## 5. Agent Memory System

### Problem

Without Vertex AI sessions, every request starts cold. The agent needs cross-conversation continuity — remembering who the user is, what they've discussed, and how their training evolves over time.

### Four Memory Tiers

#### Tier 1: Conversation Context (ephemeral, per-conversation)

Messages in the current conversation, loaded on each request.

**Storage:** `conversations/{id}/messages` (already exists)
**Loading:** Last 20 messages, ordered by timestamp.

**Session variables** for working state within a conversation:

```
conversations/{id}:
  session_vars: {
    "building_routine": true,
    "completed_days": ["push", "pull"],
    "working_on": "legs"
  }
```

Tools: `set_session_var(key, value)`, `delete_session_var(key)`. Scoped to the conversation — gone when the user starts a new one.

#### Tier 2: User Profile Context (structured, data-driven)

Factual data assembled from Firestore collections — training history, active routine, goals, strength summary, equipment. This is what `getPlanningContext()` already provides.

**Storage:** Existing collections (`users/{uid}`, routines, templates, workouts, set_facts, series).
**Loading:** Assembled on each request. No changes needed.

#### Tier 3: Agent Memory (persistent, cross-conversation)

The agent's learned understanding of the user as a person — things not in structured data but valuable for coaching.

**Storage:** New Firestore subcollection:

```
users/{uid}/agent_memory/{auto-id}:
  content: string            // "Has left shoulder impingement — avoids overhead pressing"
  category: string           // "preference" | "goal" | "constraint" | "personality" | "medical"
  created_at: timestamp
  source_conversation_id: string
  active: boolean            // Can be retired if contradicted
```

**Tools:**
- `save_memory(content, category)` — persist a learned fact
- `list_memories()` — read current memories (also auto-loaded in system context)
- `retire_memory(memory_id, reason)` — mark outdated or corrected

**Memory limits:** Cap at 50 most recent active memories loaded into the system prompt. At ~50 bytes per memory, this is ~2.5KB — well within budget. If a user accumulates >50 active memories, oldest are excluded from auto-load but remain queryable via `list_memories(offset, limit)`. A future enhancement could consolidate related memories (e.g., merge 3 shoulder-related memories into one), but this is not in scope for the initial implementation.

**Instruction guidance:** "When you learn something new about the user that would be valuable in future conversations — a goal, a constraint, an injury, a preference, a life context — save it with the memory tool. Don't save transient details ('user wants to train chest today'). Save durable facts ('user prefers 4-day upper/lower splits')."

#### Tier 4: Conversation Summaries (cross-conversation awareness)

Brief summaries of past conversations for cross-conversation awareness without loading full histories.

**Storage:** Field on the conversation document:

```
conversations/{id}:
  summary: string            // "Helped user design a 4-day Upper/Lower routine.
                             //  Discussed progressive overload strategy for squat."
  completed_at: timestamp
```

**Generation mechanism:** Summaries are generated lazily — at the start of a *new* conversation, the agent service checks whether the user's most recent conversation lacks a summary. If so, it loads the last 10 messages from that conversation, makes a lightweight LLM call (single-shot, no tools, ~100 output tokens) to generate a summary, and writes it to the conversation doc. This avoids background polling infrastructure while ensuring summaries exist before they're needed. Cost: one cheap LLM call per conversation transition.

**Loading:** Last 5 conversation summaries included in system prompt.

### Firestore Collection: `canvases` → `conversations`

The iOS app and Firestore currently use the collection name `canvases` (a legacy UI concept). This redesign renames to `conversations` — the universally understood term. With no active users, the rename has zero migration cost.

**Sequencing constraint:** The rename must be **atomic across all layers** — proxy, agent service, iOS, and Firestore rules all switch simultaneously in Phase 7. Until Phase 7, all new components (SSE proxy conversation init, agent service, context builder) write to `canvases/{id}` to maintain iOS compatibility. The agent service uses `CONVERSATION_COLLECTION` config (defaults to `"canvases"`, switched to `"conversations"` in Phase 7). This prevents a data visibility gap where the proxy writes to `conversations` but iOS reads from `canvases`.

**Subcollection migration:** The old model uses `canvases/{id}/cards`, `canvases/{id}/events`, `canvases/{id}/workspace_entries`, `canvases/{id}/up_next`. The new model uses `canvases/{id}/messages` and `canvases/{id}/artifacts` (renamed to `conversations/{id}/messages` and `conversations/{id}/artifacts` in Phase 7). Old subcollections (`cards`, `events`, `workspace_entries`, `up_next`) become dead data.

### Conversation Lifecycle

A new conversation starts when:
1. **User taps "New Chat"** in the iOS app (explicit)
2. **Inactivity timeout:** If 4+ hours have passed since the last message in the current conversation, the next message starts a new conversation. This is checked on message arrival — no background job needed.

When a new conversation starts:
- A new `conversations/{id}` document is created
- Session vars from the previous conversation are discarded (not carried over)
- The previous conversation's summary is generated lazily (see Tier 4 above)
- The new conversation loads the auto-loaded system context fresh

**Workout mode exception:** During an active workout, conversations do not auto-close. The inactivity timeout only applies when no active workout exists.

### Auto-Loaded System Context

Assembled before the LLM sees anything — no tool call needed:

```
1. INSTRUCTION (coaching persona, response craft, tool usage)
2. AGENT MEMORIES (all active memories for this user)
   "You know the following about this user: ..."
3. RECENT CONVERSATIONS (last 5 summaries)
   "Your recent interactions: ..."
4. USER PROFILE + TRAINING SNAPSHOT
   Active routine, last workout, this week's progress, streak, flags
5. ACTIVE ALERTS (from training analyst)
   Plateau warnings, volume deficits, progression candidates
6. SESSION VARS (current conversation working state)
7. CONVERSATION HISTORY (last 20 messages)
```

### How the 360 View Evolves

| Timeframe | Agent Behavior |
|-----------|---------------|
| **Week 1** | Asks more questions, learns preferences, saves memories frequently. Sparse training data. |
| **Month 1** | Knows preferences, references past discussions, spots early trends. 10-20 memories. |
| **Month 6** | Proactively suggests changes, predicts plateaus, adapts coaching style. 30-50 memories, rich trend data. |

---

## 6. Redesigned Agent Tool Surface

### Principle

The agent shouldn't need to call a tool to know who it's talking to. The 360 view loads automatically (Section 5). Tools are for going deeper.

### Context & Memory Tools

| Tool | Purpose | New/Existing |
|------|---------|-------------|
| `save_memory(content, category)` | Persist a learned fact about the user | New |
| `retire_memory(memory_id, reason)` | Mark a memory as outdated or corrected | New |
| `set_session_var(key, value)` | Set conversation-scoped working state | New |
| `delete_session_var(key)` | Remove a session variable | New |
| `search_past_conversations(query, limit)` | Search past conversation messages by keyword/topic | New |

### Analysis Tools (deep dives, on-demand)

| Tool | Purpose | New/Existing |
|------|---------|-------------|
| `get_training_analysis(sections, date)` | Pre-computed insights from training analyst (enhanced sections) | Existing, enhanced |
| `get_muscle_group_progress(group, weeks)` | Weekly series for a muscle group | Existing |
| `get_muscle_progress(muscle, weeks)` | Weekly series for a specific muscle | Existing |
| `get_exercise_progress(exercise, weeks)` | Weekly series + plateau detection flag | Existing, enhanced |
| `query_sets(target, filters)` | Raw set-level drilldown | Existing |

### Enhanced Training Analysis Sections

Computed by the training analyst worker (post-workout and weekly):

| Section | Content | Use Case |
|---------|---------|----------|
| `insights` | Post-workout observations | "How was my last workout?" |
| `weekly_review` | Weekly training summary | "How's my week going?" |
| `plateau_report` | Exercises stalled >3 weeks, suggested interventions | Agent proactively addresses plateaus |
| `periodization_status` | ACWR, deload recommendation, mesocycle position | "Should I deload?" |
| `volume_optimization` | Per-muscle actual vs target (MEV/MRV), surplus/deficit | "Am I training chest enough?" |
| `consistency_trends` | Training frequency over 4/8/12 weeks, dropout risk | Agent adjusts expectations if consistency drops |
| `progression_candidates` | Exercises ready for weight increase (hit reps with RIR >= 2) | Agent suggests progressive overload |

### Action Tools (creating/modifying)

| Tool | Purpose | New/Existing |
|------|---------|-------------|
| `propose_workout(...)` | Create workout artifact, write to Firestore | Existing, refactored |
| `propose_routine(...)` | Create routine artifact | Existing, refactored |
| `propose_routine_update(...)` | Update existing routine | Existing, refactored |
| `propose_template_update(...)` | Update existing template | Existing, refactored |
| `search_exercises(query, filters)` | Exercise catalog search | Existing |
| `get_routine(routine_id)` | Fetch full routine for editing | Existing |

### Workout Tools (live session, Fast Lane)

These tools call Firebase Functions via HTTP (not direct Firestore) — the active workout state machine is too critical to reimplement. See Section 10.

| Tool | Purpose | New/Existing |
|------|---------|-------------|
| `log_set(reps, weight_kg)` / shorthand | Log completed set — HTTP to Firebase Function | Existing, HTTP retained |
| `get_next_set()` | Get next planned set | Existing |
| `acknowledge_rest()` | Confirm readiness | Existing |
| `swap_exercise(instance_id, replacement)` | Swap exercise in active workout — HTTP to Firebase Function | Existing, HTTP retained |
| `add_exercise(exercise_id, position)` | Add exercise to active workout — HTTP to Firebase Function | Existing, HTTP retained |

### Removed Tools

| Tool | Reason |
|------|--------|
| `tool_get_training_context` | Absorbed into auto-loaded Training Snapshot (Section 5) |

---

## 7. MCP Server

### Purpose

Multi-tenant MCP server enabling end users to connect Claude Desktop, ChatGPT, or any MCP-compatible client to their Povver training data.

### Runtime

Node.js Cloud Run service. Imports the shared business logic from Section 3 directly — zero code duplication for data operations.

### Transport Protocol

Uses **Streamable HTTP** transport (the current MCP standard for remote servers). The Cloud Run service exposes an HTTP endpoint that speaks the MCP Streamable HTTP protocol. Claude Desktop, ChatGPT, and other MCP clients connect via this URL + API key. Built with the `@modelcontextprotocol/sdk` TypeScript SDK.

### Access Control

MCP access is **premium-only** — consistent with the agent's premium gate. Free users see a "Connected Apps" section in Settings but the "Generate API Key" action requires an active subscription. The MCP server validates premium status on connection establishment (not per-tool-call, to avoid latency).

### Authentication

Per-user API key generated from the iOS app.

**Key lifecycle:**
1. User navigates to Settings > Connected Apps
2. Taps "Generate API Key" — key shown once
3. Key stored in top-level Firestore collection: `mcp_api_keys/{key_hash}` with `user_id`, `name`, `created_at`, `last_used_at`
4. Server-side storage: SHA-256 hash only
5. Revocable from the app (also listed via `user_id` index)
6. Rate limited: 100 requests/hour per key

**Why top-level collection (not subcollection):** A subcollection at `users/{uid}/api_keys/{hash}` would require a collection group query on every auth check — scanning across all users. A top-level `mcp_api_keys` collection with a `user_id` field allows direct document lookup by hash (O(1)) and listing by user via a simple `where("user_id", "==", uid)` query.

**MCP auth flow:**
1. Client sends API key in MCP connection config
2. MCP server hashes key, looks up `mcp_api_keys/{key_hash}` (single document read)
3. Reads `user_id` field from the document
4. All subsequent tool calls scoped to that userId

**Firestore security rules:** `mcp_api_keys` collection must be added to `firestore.rules` — server-only access (Admin SDK), no client reads/writes.

### Exposed Tools

| MCP Tool | Shared Module | Category |
|----------|--------------|----------|
| `get_training_snapshot` | `planning-context.js` | Read |
| `get_training_analysis` | `training-queries.js` | Read |
| `get_muscle_group_progress` | `training-queries.js` | Read |
| `get_exercise_progress` | `training-queries.js` | Read |
| `query_sets` | `training-queries.js` | Read |
| `list_routines` | `routines.js` | Read |
| `get_routine` | `routines.js` | Read |
| `list_templates` | `templates.js` | Read |
| `get_template` | `templates.js` | Read |
| `list_workouts` | `workouts.js` | Read |
| `get_workout` | `workouts.js` | Read |
| `search_exercises` | `exercises.js` | Read |
| `create_routine` | `routines.js` | Write |
| `update_routine` | `routines.js` | Write |
| `create_template` | `templates.js` | Write |
| `update_template` | `templates.js` | Write |
| `list_memories` | agent_memory collection | Read |

**Not exposed via MCP:**
- Active workout operations (log_set, start, complete) — iOS-only, real-time
- Subscription management — internal
- Account management — internal

### Deployment

Cloud Run with scale-to-zero. Users configure their MCP client with the Cloud Run URL + API key.

---

## 8. Trigger Cascade to Job Queue

### Problem

Workout completion fires 8 synchronous Firestore writes via a single trigger. Partial failures leave inconsistent state. Concurrent completions cause transaction contention.

### Solution

The trigger enqueues a single job. A worker processes it atomically with lease-based concurrency (same pattern as training_analyst).

**Before:**
```
onWorkoutCompleted trigger
  ├── updateWeeklyStats (transaction, 3 retries)
  ├── upsertRollup
  ├── appendMuscleSeries
  ├── updateWatermark
  ├── generateSetFacts + updateSeries (3 collections)
  ├── enqueueTrainingAnalysis
  └── updateExerciseUsageStats
```

**After:**
```
onWorkoutCompleted trigger
  └── enqueue job to workout_completion_jobs/{auto-id}

Workout Completion Worker
  1. Claim job (lease-based)
  2. Generate set_facts
  3. Update all series (exercises, muscle_groups, muscles)
  4. Update rollups
  5. Update weekly_stats
  6. Update exercise usage stats
  7. Update watermark
  8. Advance routine cursor (if source_routine_id present)
  9. Enqueue training analysis (if premium)
  10. Mark job complete
```

**Benefits:**
- **Atomic:** Worker crash → lease expires → retry from scratch. No partial state.
- **No contention:** One job at a time per user.
- **Observable:** Jobs have status (pending, processing, complete, failed). Queue depth and failure rate are measurable.
- **Backpressure:** Jobs queue instead of overwhelming Firestore with concurrent triggers.

**Implementation:** The workout completion worker is a **separate Cloud Run Job** (not shared with the training analyst). It reuses the same lease-based job queue pattern from the training analyst but runs independently — different trigger, different processing logic, different scaling characteristics.

**Triggering:** A lightweight Firestore `onCreate` trigger on the `workout_completion_jobs` collection invokes the Cloud Run Job via Cloud Tasks (same pattern as the training analyst's job enqueueing). This provides at-least-once delivery with automatic retries.

**Both workout completion triggers become trivial enqueues:**
```javascript
// Fires when an active workout is completed (end_time added via update)
exports.onWorkoutCompleted = onDocumentUpdated(
  "users/{userId}/workouts/{workoutId}",
  async (event) => {
    if (!event.data.after.data().end_time || event.data.before.data().end_time) return;
    await enqueueWorkoutCompletionJob(event.params.userId, event.params.workoutId);
  }
);

// Fires when an imported workout is created with end_time already present
exports.onWorkoutCreatedWithEnd = onDocumentCreated(
  "users/{userId}/workouts/{workoutId}",
  async (event) => {
    const data = event.data.data();
    if (!data.end_time) return;
    await enqueueWorkoutCompletionJob(event.params.userId, event.params.workoutId);
  }
);

async function enqueueWorkoutCompletionJob(userId, workoutId) {
  await db.collection("workout_completion_jobs").add({
    user_id: userId,
    workout_id: workoutId,
    status: "pending",
    created_at: FieldValue.serverTimestamp(),
  });
}
```

**Routine cursor update folded into worker:** `onWorkoutCreatedUpdateRoutineCursor` (from `workout-routine-cursor.js`) is absorbed into the workout completion worker as step 9. The cursor advance is part of the same logical event — not a separate trigger. This eliminates a race condition where the cursor could update before analytics are written.

---

## 9. Phasing

| Phase | Scope | Dependency | Cost Impact |
|-------|-------|------------|-------------|
| **Phase 1: Observability** | Cloud Monitoring dashboards, alerting, cost tracking. Retained from existing performance plan — no code changes. | None | $0 (free tier) |
| **Phase 2: Shared Business Logic** | Extract pure functions from Firebase Functions into `shared/` modules (routines, templates, workouts, exercises, training-queries, planning-context, artifacts, progressions). Typed errors. Unit tests. Functions become thin HTTP wrappers. `agents/get-planning-context.js` becomes thin wrapper over `shared/planning-context.js`. | None | $0 |
| **Phase 3a: Agent Core** | Cloud Run agent service. LLM client abstraction (Gemini first). Agent loop. Direct Firestore access via AsyncClient (all 31 CanvasFunctionsClient methods including `get_active_snapshot_lite`, `get_active_events`). Full skill migration: copilot_skills + workout_skills retain HTTP, coach_skills → direct Firestore, planner_skills → direct Firestore, progression_skills → HTTP retained. Instruction migration. SSE proxy update: call Cloud Run, add conversation initialization (replaces `openCanvas`/`bootstrapCanvas`/`initializeSession`), implement 4-hour inactivity timeout. Structured observability. | None (can start immediately) | Cloud Run: pay-per-request |
| **Phase 3b: Agent Memory** | All 4 memory tiers: conversation history loading, session vars, agent memory (save/retire/list), conversation summaries (lazy generation). Auto-loaded system context assembly. Instruction updates for memory usage guidance. | Phase 3a | $0 (Firestore writes only) |
| **Phase 3c: Session Elimination + Dead Code Removal** | Remove: session management from SSE proxy, iOS `SessionPreWarmer`, Firestore `agent_sessions` collection, `getServiceToken` endpoint + iOS caller, `cleanupStaleSessions` scheduled function, `expireProposalsScheduled` scheduled function, `invokeCanvasOrchestrator` endpoint, dead index.js exports (`onWorkoutCreatedWeekly`, `onWorkoutFinalizedForUser`). | Phase 3a | $0 |
| **Phase 4: MCP Server** | Node.js Cloud Run service. Per-user API keys (generation endpoint in Firebase Functions, UI in iOS, Firestore storage, premium gate). Imports shared business logic. Streamable HTTP transport. | Phase 2 | Cloud Run: pay-per-request |
| **Phase 5: Trigger Cascade → Job Queue** | Workout completion worker (Cloud Run Job). Lease-based job queue. Both `onWorkoutCompleted` and `onWorkoutCreatedWithEnd` simplified to enqueue. Routine cursor update (`onWorkoutCreatedUpdateRoutineCursor`) absorbed into worker. Cloud Tasks integration. Move `post_workout_analyst.py` from `canvas_orchestrator` to `training_analyst`. | Independent | Cloud Run: pay-per-request |
| **Phase 6: Training Analyst Enhancement** | New analysis sections: plateau_report, periodization_status, volume_optimization, consistency_trends, progression_candidates. These feed the agent's auto-loaded Active Alerts context. | Phase 3b (agent must be able to consume the new sections) | $0 (existing Cloud Run Job) |
| **Phase 7: iOS Cleanup** | Rename `canvases` → `conversations` in all Firestore collection paths (5 files). Rename iOS classes: `CanvasViewModel` → `ConversationViewModel`, `CanvasService` → `ConversationService`, etc. Update `StreamEvent.swift` to 9-event contract (drop 6 legacy types). Split oversized files (FocusModeWorkoutScreen). Remove dead code (`SessionPreWarmer`, `CanvasRepository`, `getServiceToken` caller). | Phase 3c | $0 |
| **Scaling (deferred)** | `minInstances` on hot-path functions. Increase `maxInstances` on SSE proxy. Cloud Run scaling config. Flip-the-switch when revenue justifies monthly cost. | Post-Phase 1 | Monthly cost |

**Parallelism:** Phase 2 and Phases 3a-c can run in parallel (the Python agent has its own FirestoreClient — it does not import Node.js shared modules). Phases 3a-c are sequential among themselves. Phase 4 depends on Phase 2 (MCP imports shared modules). Phase 5 is fully independent. Phase 6 depends on Phase 3b. Phase 7 follows Phase 3c.

```
Phase 1 (Observability) ─────────────────────────────────────────────────▶
Phase 2 (Shared Logic)  ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
Phase 3a (Agent Core)   ████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
Phase 3b (Memory)                       ████████░░░░░░░░░░░░░░░░░░░░░░░░░
Phase 3c (Session Kill)                         ████░░░░░░░░░░░░░░░░░░░░░
Phase 4 (MCP)           ─── waits for Phase 2 ──████████████░░░░░░░░░░░░░
Phase 5 (Job Queue)     ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
Phase 6 (Analyst)       ─── waits for Phase 3b ─────────████████░░░░░░░░░
Phase 7 (iOS Cleanup)   ─── waits for Phase 3c ─────────────████████░░░░░
```

---

## 10. Decisions and Tradeoffs

| Decision | Rationale | Alternative Considered |
|----------|-----------|----------------------|
| Node.js shared logic (not Python) | Same language as Firebase Functions — direct imports, no duplication | Python shared lib would require Node.js wrappers or code duplication |
| SSE proxy stays as Firebase Function (not merged into Cloud Run) | Auth, premium gate, and rate limiting infrastructure is battle-tested in Firebase Functions. Keeps the agent service focused on agent logic. The extra network hop adds ~10-20ms — negligible on a streamed response. | Moving auth into Cloud Run middleware would eliminate the hop but requires reimplementing auth patterns in Python and mixing transport concerns with agent logic |
| Cloud Run agent (not Firebase Function) | 9-min timeout limit on Functions; Cloud Run supports long-running streams | Firebase Function agent would be simpler but limited |
| Per-user API key (not OAuth) | Simplest UX (paste one string); maps to existing `withApiKey` pattern | OAuth is more "correct" but significant implementation overhead |
| Stateless agent (not session-based) | Eliminates session management, pre-warming, cleanup; conversation history already in Firestore | Sessions provide implicit context but add operational complexity |
| LLM client abstraction (not direct SDK) | Enables model switching without code changes; different models for different lanes | Direct SDK is simpler but locks to one provider |
| Gemini as initial LLM provider | Already tested with current agent; cheapest for high-volume coaching; Flash is fast enough for all lanes | Claude has better coaching quality but higher cost; start with Gemini, evaluate Claude once abstraction is in place |
| Agent retains HTTP for active workout mutations (not direct Firestore) | Active workout Firebase Functions have Zod validation, state machine logic, idempotency guards, and concurrent-set protection. Reimplementing in Python doubles maintenance surface on the most critical data path. ~200ms overhead is invisible during workout rest periods. | Direct Firestore writes from agent would be faster but requires maintaining two implementations of complex state machine logic |
| Job queue (not triggers) | Atomic processing, no contention, observable, retriable | Triggers are simpler but fragile under load |
| Agent memory as explicit tool (not post-conversation extraction) | Simpler, more reliable, no background process needed | Post-conversation extraction catches things agent misses but adds latency and complexity |
| MCP server as Cloud Run (not local-only) | Multi-tenant, always available, user doesn't need local setup | Local MCP is simpler but limits to developer use |
| Rename `canvases` → `conversations` in iOS + Firestore (not keep legacy name) | No active users means zero migration cost. "Canvas" is a confusing abstraction — "conversation" is universally understood. 5 Swift files to update. Clean break. | Keeping `canvases` avoids any risk but perpetuates confusing naming indefinitely |
| Clean 9-event SSE contract (not backward-compat 15 types) | 6 of the 15 iOS event types are ADK/Vertex AI artifacts (`thinking`, `thought`, `pipeline`, `agentResponse`, `toolRunning`/`toolComplete`). Cleaning now prevents future confusion. No active users = no backward compat needed. | Keeping all 15 types means the new agent must emit legacy events it doesn't naturally produce |
| Fold routine cursor into workout completion worker (not keep as separate trigger) | Same logical event (workout completed). Eliminates race condition where cursor updates before analytics. One fewer trigger to maintain. | Separate trigger is simpler initially but adds a race condition and operational surface |
| Conversation init in SSE proxy (not separate endpoints) | Eliminates 4 endpoints (`openCanvas`, `bootstrapCanvas`, `initializeSession`, `preWarmSession`). Single code path for conversation lifecycle. | Separate endpoints give iOS more control but add complexity that sessions no longer justify |

---

## 11. What This Supersedes

- **Vertex AI Agent Engine deployment** — replaced by Cloud Run agent service
- **ADK framework** — replaced by focused agent loop + LLM client abstraction
- **Session management** (initialize, pre-warm, cleanup) — eliminated entirely
- **CanvasFunctionsClient** (agent HTTP client, 31 methods) — replaced by `FirestoreClient` (direct Firestore) + retained HTTP for active workout mutations
- **`getServiceToken` endpoint** — eliminated (no more Vertex AI token exchange)
- **`invokeCanvasOrchestrator` endpoint** — replaced by SSE proxy → Cloud Run
- **`openCanvas` / `bootstrapCanvas` / `initializeSession` / `preWarmSession` endpoints** — replaced by conversation initialization in SSE proxy
- **`cleanupStaleSessions` scheduled function** — no more sessions to clean
- **`expireProposalsScheduled` scheduled function** — no more canvas proposals (replaced by artifacts)
- **`onWorkoutCreatedUpdateRoutineCursor` trigger** — absorbed into workout completion worker
- **Dead exports** (`onWorkoutCreatedWeekly`, `onWorkoutFinalizedForUser`) — removed from index.js
- **15-event SSE contract** — replaced by 9-event clean contract
- **Performance plan Phases 1-3** (from `2026-03-04`) — replaced by this design. Phase 0 (Observability) is retained as Phase 1.
- **`agent_engine_requirements.txt`** — replaced by standard `requirements.txt`
- **`post_workout_analyst.py` in `canvas_orchestrator/`** — moved to `training_analyst/` where it belongs

## 12. What This Does NOT Change

- **Firebase Functions HTTP API** — same endpoints, same auth, same behavior for iOS (active workout, routines, templates, workouts, exercises, training queries all unchanged)
- **Firestore schema** — no migrations needed. New collections added (`conversations`, `agent_memory`, `mcp_api_keys`, `workout_completion_jobs`). `canvases` collection will be renamed to `conversations` in iOS but data shape is compatible.
- **iOS app architecture** — MVVM, repositories, services all stay (Phase 7 is cleanup + naming)
- **Firestore security rules** — unchanged for existing collections. New collections added with appropriate rules.
- **Active workout state machine** — all 12 active workout Firebase Functions unchanged (log_set, complete, patch, swap, add, autofill, propose, start, get, cancel, completeCurrentSet)
- **Exercise catalog orchestrator** — independent system, unchanged
- **Subscription system** — webhooks, StoreKit sync, premium gates all stay
- **Training analyst core architecture** — same Cloud Run Jobs, same lease-based queue. Phase 6 adds new analysis sections.
- **Template analytics triggers** (`onTemplateCreated`, `onTemplateUpdated`, `onWorkoutCreated`) — simple, independent, rarely fire. Unchanged.
- **Recommendation system triggers** (`onAnalysisInsightCreated`, `onWeeklyReviewCreated`) — event-driven, cleanly isolated. Unchanged.
- **Three scheduled functions** — `weeklyStatsRecalculation` (daily 2 AM), `analyticsCompactionScheduled` (daily 3 AM), `expireStaleRecommendations` (daily midnight). All unchanged.
- **`artifactAction` endpoint** — stays as Firebase Function (user-facing write with premium gates). Business logic extracted to `shared/artifacts.js`.
- **`applyProgression` endpoint** — stays as Firebase Function. Business logic extracted to `shared/progressions.js`.
- **Dual API key pattern** — `FIREBASE_API_KEY` (workout endpoints, x-user-id header auth) and `MYON_API_KEY` (planning/analytics, userId in body). Both retained. Consolidation is a separate follow-up.
