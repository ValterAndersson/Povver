# Architecture Redesign — Errata & Amendments

> This document captures all findings from the boundary contract audit and the 5 architectural decisions that resolve them. It serves as the authoritative reference for rewriting affected tasks in the implementation plan.

**Baseline documents:**
- Spec: `docs/plans/2026-03-17-architecture-redesign-design.md`
- Plan: `docs/plans/2026-03-17-architecture-redesign-plan.md`

---

## Architectural Decisions

### AD-1: Workout completion stays in JavaScript

The existing analytics pipeline is 2,960 lines of JS across 6 files, writes to 11 Firestore collections through 7 transaction patterns, and has 4 idempotency mechanisms. Porting to Python introduced 25+ bugs in the plan. The actual problem with the current system is *trigger reliability* (silent failures, no observability), not the language.

**Change:**
- Replace Firestore triggers (`onWorkoutCompleted`, `onWorkoutCreatedWithEnd`) with Cloud Tasks queue
- Refactor the duplicated trigger logic into a shared `processWorkoutCompletion(userId, workoutId)` callable
- Create a new Firebase Function `processWorkoutCompletionTask` triggered by Cloud Tasks
- Update `upsert-workout.js` and `completeActiveWorkout` to enqueue Cloud Tasks
- Add a watchdog scheduled function that catches un-processed completions
- **Remove** the Python workout completion worker entirely (Tasks 38, 39a from the plan)
- **Remove** the `workout_completion_jobs` Firestore collection (replaced by Cloud Tasks queue)
- Keep `workout-routine-cursor.js` trigger (142 lines, independent, low-risk) OR absorb into the refactored callable

**Files involved:**
- Modify: `firebase_functions/functions/triggers/weekly-analytics.js` — extract shared logic
- Create: `firebase_functions/functions/triggers/workout-completion-task.js` — Cloud Tasks handler
- Modify: `firebase_functions/functions/workouts/upsert-workout.js` — enqueue task
- Modify: `firebase_functions/functions/workouts/complete-active-workout.js` — enqueue task
- Create: `firebase_functions/functions/triggers/workout-completion-watchdog.js` — scheduled catch-up
- Modify: `firebase_functions/functions/index.js` — export new functions

### AD-2: Artifact & event emission in the agent service

Currently the SSE proxy detects `artifact_type` in tool responses and handles artifact persistence + SSE emission. In the new architecture the proxy is a dumb relay, so this logic moves to the agent service.

**Change:** The agent loop's tool executor gains an `_inspect_tool_result()` step:

```python
async def _execute_and_inspect(tool_name, args, ctx, fs):
    result = await execute_tool(tool_name, args, ctx)
    sse_side_effects = []

    # Artifact detection (mirrors stream-agent-normalized.js artifact handling)
    if isinstance(result, dict) and result.get("artifact_type"):
        artifact_id = str(uuid.uuid4())
        sse_side_effects.append(sse_event("artifact", {
            "artifact_type": result["artifact_type"],
            "artifact_id": artifact_id,
            "artifact_content": result.get("content", {}),
            "actions": result.get("actions", []),
            "status": result.get("status", "proposed"),
        }))
        # Persist to Firestore (async, non-blocking)
        asyncio.create_task(fs.save_artifact(
            ctx.user_id, ctx.conversation_id, artifact_id, result
        ))

    # Safety gate / clarification detection
    if isinstance(result, dict) and result.get("requires_confirmation"):
        sse_side_effects.append(sse_event("clarification", {
            "id": result.get("confirmation_id", str(uuid.uuid4())),
            "question": result.get("question", ""),
            "options": result.get("options", []),
        }))

    return result, sse_side_effects
```

The agent loop emits side-effect SSE events before passing the tool result to the LLM.

**Additional event emission:**
- `status`: emitted at tool_start based on a tool→status map (e.g., `get_training_context` → "Analyzing your training data...")
- `heartbeat`: background asyncio task during LLM streaming, every 15s
- `error`: try/catch in agent loop yields `sse_event("error", {"code": "AGENT_ERROR", "message": str(e)})`

**Artifact SSE shape** (must match what iOS expects):
```json
{
  "artifact_type": "session_plan",
  "artifact_id": "uuid",
  "artifact_content": { ... },
  "actions": ["start_workout", "dismiss"],
  "status": "proposed"
}
```

### AD-3: SSE proxy translates event names during Phase 3a→7

Between Phase 3a (new backend deployed) and Phase 7 (iOS cleanup), iOS expects old event names but the agent emits new ones.

**Change:** The proxy maintains a translation table that maps new→old event names:

```javascript
// Removed in Phase 7 when iOS is updated
const EVENT_COMPAT = {
  'tool_start': 'toolRunning',
  'tool_end': 'toolComplete',
  'clarification': 'clarification.request',
};

function relayEvent(event) {
  const translated = EVENT_COMPAT[event.type] || event.type;
  return { ...event, type: translated };
}
```

The proxy also continues writing `workspace_entries` for every SSE event (conversation replay for iOS). This is existing behavior that STAYS — the proxy reads SSE events from Cloud Run and persists each one as a workspace entry document. The `messages` subcollection is for structured conversation history (agent service writes), while `workspace_entries` is for timeline replay (proxy writes).

### AD-4: Phase 3c makes canvas endpoints no-ops

`openCanvas`, `bootstrapCanvas`, `initializeSession`, `preWarmSession` are called by iOS on every canvas open. Can't delete until Phase 7.

**Change:** Phase 3c replaces these with no-op stubs returning success shapes:

```javascript
exports.openCanvas = onRequest(async (req, res) => {
  const userId = getAuthenticatedUserId(req);
  return ok(res, {
    canvasId: req.body.canvasId || uuidv4(),
    sessionId: null,
    isNewSession: true,
    resumeState: { cards: [], cardCount: 0 },
  });
});

exports.initializeSession = onRequest(async (req, res) => {
  return ok(res, { sessionId: null, isReused: false });
});

// bootstrapCanvas and preWarmSession — same pattern
```

Phase 7 deletes these stubs AND removes iOS callers simultaneously.

### AD-5: Firestore reads from actual source, not spec abstractions

Every `FirestoreClient` method and `context_builder` function is rewritten to match actual field names from `FIRESTORE_SCHEMA.md` and existing Firebase Function implementations.

See the detailed field corrections in the "Per-Task Errata" section below.

---

## Per-Task Errata

### Task 11: Agent Service Makefile

**Issue:** Dockerfile missing `shared/` COPY. Makefile missing pre-build `cp` step. Env var name mismatch.

**Fix:**
1. Add to Makefile `deploy` target (before `gcloud builds submit`):
   ```makefile
   deploy:
   	cp -r ../shared shared/
   	gcloud builds submit ... ; \
   	rm -rf shared/
   ```
2. Fix env var: change `FIREBASE_FUNCTIONS_URL` in skill code to `MYON_FUNCTIONS_BASE_URL` (matching the deploy command), OR add `FIREBASE_FUNCTIONS_URL` to deploy `--set-env-vars`.
   - **Decision:** Rename the env var in skill code to `MYON_FUNCTIONS_BASE_URL` for consistency with the canvas_orchestrator pattern.

### Task 12: Agent Service Dockerfile

**Issue:** Missing `COPY shared/ shared/`.

**Fix:** Add after `COPY app/ app/`:
```dockerfile
COPY shared/ shared/
```

### Task 13: Agent Loop (`agent_loop.py`)

**Issues:**
1. Only emits 4 of 9 event types (message, tool_start, tool_end, done)
2. No artifact detection
3. No clarification handling
4. No heartbeat
5. No error event emission

**Fix:** Rewrite the loop to include:

```python
async def run_agent_loop(...) -> AsyncIterator[SSEEvent]:
    messages = _build_messages(instruction, history, message)
    turn = 0
    heartbeat_task = None

    try:
        while turn < max_tool_turns:
            tool_calls = []
            last_usage = None

            # Start heartbeat during LLM streaming
            heartbeat_task = asyncio.create_task(_heartbeat_emitter(heartbeat_queue))

            async for chunk in llm_client.stream(model, messages, tools, config):
                if chunk.usage:
                    last_usage = chunk.usage
                if chunk.is_text:
                    yield sse_event("message", chunk.text)
                elif chunk.is_tool_call:
                    tool_calls.append(chunk.tool_call)

            # Stop heartbeat
            if heartbeat_task:
                heartbeat_task.cancel()

            # Track usage
            if last_usage:
                log_tokens(model, last_usage["input_tokens"], last_usage["output_tokens"])
                track_usage(user_id=ctx.user_id, ...)

            if not tool_calls:
                yield sse_event("done", {})
                return

            # Execute tools with artifact/clarification detection
            for tc in tool_calls:
                status_msg = TOOL_STATUS_MAP.get(tc.tool_name)
                if status_msg:
                    yield sse_event("status", {"text": status_msg})
                yield sse_event("tool_start", {"tool": tc.tool_name, "call_id": tc.call_id})

                start = time.monotonic()
                try:
                    result, side_effects = await _execute_and_inspect(
                        tc.tool_name, tc.args, ctx, fs
                    )
                except Exception as e:
                    logger.warning("Tool %s failed: %s", tc.tool_name, e)
                    result = {"error": str(e)}
                    side_effects = []

                elapsed_ms = int((time.monotonic() - start) * 1000)
                yield sse_event("tool_end", {"tool": tc.tool_name, "call_id": tc.call_id, "elapsed_ms": elapsed_ms})

                # Emit side-effect events (artifacts, clarifications)
                for evt in side_effects:
                    yield evt

                messages.append({"role": "tool", ...})

            turn += 1

        yield sse_event("message", "I've reached my reasoning limit...")
        yield sse_event("done", {})

    except Exception as e:
        logger.exception("Agent loop error")
        yield sse_event("error", {"code": "AGENT_ERROR", "message": str(e)})
```

### Task 14: FirestoreClient

**Issues:** 12+ wrong field names, wrong collection paths, missing `import os`.

**Field corrections:**

| Method | Wrong | Correct |
|--------|-------|---------|
| `get_planning_context` | `user.get("display_name")` | `user.get("name")` |
| `get_planning_context` | `user.get("preferences", {})` | Read from `user_attributes/{uid}` subcollection |
| `get_planning_context` | `user.get("training_level")` | `attrs.get("fitness_level")` from user_attributes |
| `get_planning_context` | `user.get("goals", [])` | `attrs.get("fitness_goal")` from user_attributes (singular, not array) |
| `list_recent_workouts` | `.order_by("start_time")` | `.order_by("end_time", direction=DESCENDING)` |
| `get_weekly_stats` | `weekly_stats/current` | `weekly_stats/{week_start_date}` — compute from current date using user's week start preference |
| `get_active_snapshot_lite` | `user.get("streak", 0)` | Remove — field doesn't exist |
| `get_exercise_summary` | `analytics_series_exercise/{exercise_name}` | `analytics_series_exercise/{exercise_id}` — parameter should be exercise_id |
| `query_sets` | `.where("exercise_name", "==", ...)` | `.where("exercise_id", "==", ...)` — use exercise_id, matching existing index |
| `search_exercises` | `.where("status", "!=", "merged").order_by("name")` | `.where("status", "!=", "merged").order_by("status").order_by("name")` — Firestore requires orderBy on inequality field first. OR use the existing `searchExercises` Firebase Function via HTTP (which handles this correctly). |
| `get_conversation_messages` | `.order_by("timestamp")` | `.order_by("created_at")` |
| `save_message` | `role`, `timestamp` | `type` (values: `user_prompt`, `agent_response`, `artifact`), `created_at` |
| Class definition | Missing `import os` | Add `import os` at top |

**New method needed:** `get_user_attributes(user_id)` — reads `users/{uid}/user_attributes/{uid}`.

**Collection name fixes in coach_skills (bypassing FirestoreClient):**
- `muscle_group_series` → `analytics_series_muscle_group`
- `exercise_series` → `analytics_series_exercise`
- These should use `FirestoreClient` methods, not direct queries.

### Task 15: Observability

**Issue:** `log_tokens` function referenced by agent_loop but not defined in the shown code.

**Fix:** Ensure `log_tokens(model, input_tokens, output_tokens)` is defined in `observability.py`. (It appears in the plan at line 2470 but the import in agent_loop references it — verify the function exists in the final code.)

### Task 16: Main.py / Stream Endpoint

**Issue:** Returns HTTP 400 JSON for validation errors, but proxy expects SSE stream.

**Fix:** All errors after SSE headers are sent must be SSE error events, not HTTP JSON responses. Validation errors before streaming starts can be HTTP 400.

### Task 21: HTTP-Retained Skills

**Critical bugs in request body shapes:**

**`copilot_skills.log_set` — complete rewrite:**
```python
async def log_set(*, ctx: RequestContext, exercise_instance_id: str,
                  set_id: str, reps: int, weight_kg: float, rir: int = 0) -> dict:
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/logSet",
            json={
                "workout_id": ctx.workout_id,
                "exercise_instance_id": exercise_instance_id,
                "set_id": set_id,
                "values": {
                    "weight": weight_kg,
                    "reps": reps,
                    "rir": rir,
                },
                "idempotency_key": str(uuid.uuid4()),
            },
            headers={
                "x-api-key": FIREBASE_API_KEY,
                "x-user-id": ctx.user_id,
            },
        )
        return resp.json()
```

**`progression_skills.apply_progression` changes shape:**
```python
# Wrong: {"path": "...", "value": new_weight}
# Correct:
changes=[{"path": f"exercises[{exercise_index}].sets[0].weight",
          "from": None, "to": new_weight, "rationale": rationale}]
```

**`FUNCTIONS_URL` env var name:**
```python
# Wrong: FIREBASE_FUNCTIONS_URL
# Correct:
FUNCTIONS_URL = os.getenv("MYON_FUNCTIONS_BASE_URL",
                          "https://us-central1-myon-53d85.cloudfunctions.net")
```

### Task 25: SSE Proxy

**Issues:**
1. No event name translation for Phase 3a→7 backward compatibility
2. No error handling for Cloud Run non-200 responses
3. Must continue writing workspace_entries

**Fix:**
1. Add `EVENT_COMPAT` translation table (see AD-3)
2. Wrap `callAgentService()` in try/catch, emit SSE error event on failure:
   ```javascript
   try {
     const stream = await callAgentService(...);
     // relay events with translation
   } catch (err) {
     sse.write({ type: 'error', error: { code: 'UPSTREAM_ERROR', message: err.message } });
     done(false);
   }
   ```
3. Keep existing workspace_entries write logic (persist each relayed event)
4. Keep existing artifact persistence logic (detect artifact_type in relayed events, write to Firestore)
   - Wait — per AD-2, artifact persistence moves to the agent service. BUT the proxy still needs to write workspace_entries. So the proxy writes workspace_entries for ALL events (including artifacts), while the agent service handles artifact-specific persistence to the `artifacts` subcollection.
5. Add `AGENT_SERVICE_URL` guard at module load:
   ```javascript
   const AGENT_SERVICE_URL = process.env.AGENT_SERVICE_URL;
   if (!AGENT_SERVICE_URL) throw new Error('AGENT_SERVICE_URL not configured');
   ```

**New npm dependencies:** Add `uuid` to `package.json`.

### Task 28: Context Builder

**Issues:**
1. Wrong field names (same as FirestoreClient)
2. Three hardcoded `"conversations"` paths

**Fix:**
1. `_load_recent_summaries`: use `fs.CONVERSATION_COLLECTION` not `"conversations"`
2. `_maybe_generate_previous_summary`: use `fs.CONVERSATION_COLLECTION`
3. Field name corrections cascade from FirestoreClient fixes

### Task 29: Memory Tools

**Issues:**
1. `search_past_conversations` uses hardcoded `"conversations"`
2. Message query uses `"timestamp"` instead of `"created_at"`

**Fix:**
1. Use `fs.CONVERSATION_COLLECTION` in `search_past_conversations`
2. Use `"created_at"` in all message queries

### Task 31: Dead Code Removal (Phase 3c)

**Issue:** Plan deletes `openCanvas`, `bootstrapCanvas`, `initializeSession`, `preWarmSession` from index.js. iOS still calls these until Phase 7.

**Fix per AD-4:** Replace with no-op stubs returning expected response shapes. Delete the actual implementation files but keep stub exports in index.js.

### Task 33: MCP Authentication

**Issue:** `subscription_status?.is_premium` is wrong — `subscription_status` is a string, not an object.

**Fix:**
```javascript
// Wrong:
if (!userData.subscription_status?.is_premium) { ... }

// Correct (mirrors isPremiumUser logic):
const isPremium = userData.subscription_override === 'premium'
                || userData.subscription_tier === 'premium';
if (!isPremium) {
  throw new Error('Premium subscription required for MCP access');
}
```

### Task 33: MCP Server Deploy

**Issues:**
1. Missing `--service-account`
2. Missing `--set-env-vars`
3. Wrong `require()` path in `tools.ts`

**Fix:**
1. Add `--service-account ai-agents@$(PROJECT_ID).iam.gserviceaccount.com`
2. Add `--set-env-vars "GOOGLE_CLOUD_PROJECT=$(PROJECT_ID)"`
3. Fix require path: `require('../../shared/routines')` → `require('../shared/routines')` (from `dist/`)

### Task 35: Firestore Rules

**Issue:** `agent_memory` and `workout_completion_jobs` not added to rules.

**Fix:** Add rules for `agent_memory`:
```
match /users/{userId}/agent_memory/{memoryId} {
  allow read, write: if request.auth != null && request.auth.uid == userId;
}
```

Remove `workout_completion_jobs` from plan (replaced by Cloud Tasks queue per AD-1).

### Tasks 38, 39a: Workout Completion Worker (REMOVED)

**Per AD-1:** The entire Python workout completion worker and Firestore trigger replacement are removed from the plan. Replaced by:

**New Task: Refactor JS Workout Triggers to Cloud Tasks**

Files:
- Create: `firebase_functions/functions/training/process-workout-completion.js` — shared callable extracted from `weekly-analytics.js`
- Create: `firebase_functions/functions/triggers/workout-completion-task.js` — Cloud Tasks handler
- Modify: `firebase_functions/functions/triggers/weekly-analytics.js` — remove `onWorkoutCompleted` and `onWorkoutCreatedWithEnd` triggers
- Modify: `firebase_functions/functions/workouts/upsert-workout.js` — enqueue Cloud Task on completion
- Modify: `firebase_functions/functions/workouts/complete-active-workout.js` — enqueue Cloud Task
- Modify: `firebase_functions/functions/index.js` — export new functions, remove old triggers

Steps:
1. Extract `processWorkoutCompletion(db, userId, workoutId, workoutData)` from the duplicated logic in `onWorkoutCompleted`/`onWorkoutCreatedWithEnd`
2. Create Cloud Tasks handler that calls the extracted function
3. Set up Cloud Tasks queue: `gcloud tasks queues create workout-completion --location=us-central1`
4. Update `upsert-workout.js`: after workout with `end_time` is created/updated, enqueue Cloud Task
5. Update `complete-active-workout.js`: after setting `end_time`, enqueue Cloud Task
6. Add watchdog: scheduled function (daily) that queries workouts with `end_time` set but no corresponding `set_facts`, and re-enqueues them
7. Remove `onWorkoutCompleted` and `onWorkoutCreatedWithEnd` triggers
8. Test: create a workout, verify Cloud Task fires and all 11 collections are written correctly
9. npm dependency: add `@google-cloud/tasks` to package.json

### Task 39b: Training Analyst `post_workout_analyst.py`

**Issue:** The moved file calls `apply_progression` with `changes` not in request body.

**Fix:**
```python
# Wrong:
async def apply_progression(user_id, changes, **kwargs):
    resp = await client.post(url, json={"userId": user_id, **kwargs}, ...)

# Correct:
async def apply_progression(user_id, changes, **kwargs):
    resp = await client.post(url, json={
        "userId": user_id,
        "changes": changes,
        **kwargs,
    }, ...)
```

### Task 41: Coordinated Rename (Phase 7)

**Additional items for Phase 7 iOS update:**
1. Update `StreamEvent.EventType` enum cases:
   - `toolRunning` → `toolStart = "tool_start"`
   - `toolComplete` → `toolEnd = "tool_end"`
   - `clarificationRequest` → `clarification = "clarification"`
2. Update `handleIncomingStreamEvent` for new event names
3. Remove `thinking`, `thought`, `pipeline`, `card`, `agentResponse`, `userPrompt`, `userResponse` event type cases (no longer emitted)
4. Update or remove `ThinkingProcessState` — no longer driven by `pipeline` events. Replace with a simpler progress indicator based on `tool_start`/`tool_end` events.
5. Remove `workspace_entries` listener, replace with `messages` listener
6. Remove `CanvasService.openCanvas()`, `bootstrapCanvas()`, `initializeSession()`, `preWarmSession()` calls
7. Remove no-op stub exports from `index.js`
8. Remove `EVENT_COMPAT` translation table from SSE proxy
9. Update `buildCardFromArtifact` if the artifact event shape changes (verify — with AD-2, the agent service emits the SAME shape iOS already expects, so no change needed in Phase 7)

### Task 42: Schema Documentation Update

**Additional items:**
1. Document `agent_memory` collection with full field list: `content`, `category`, `active`, `created_at`, `source_conversation_id`, `retired_at`, `retire_reason`
2. Document new conversation fields: `summary`, `completed_at`, `session_vars`, `last_message_at`
3. Document composite index: `agent_memory(active ASC, created_at DESC)`
4. Remove `workout_completion_jobs` (replaced by Cloud Tasks)
5. Document `mcp_api_keys` collection fields

### New Dependencies (package.json)

Add to `firebase_functions/functions/package.json`:
- `"uuid": "^9.0.0"` — used in SSE proxy conversation init
- `"@google-cloud/tasks": "^5.0.0"` — used by workout completion task enqueue

Remove from plan:
- `"@google-cloud/run"` — no longer needed (was for triggering Cloud Run Job, now using Cloud Tasks)

### IAM / Permissions

1. Firebase Functions service account needs `roles/run.invoker` on the agent service Cloud Run
2. Firebase Functions service account needs `roles/cloudtasks.enqueuer` for workout completion queue
3. Agent service SA (`ai-agents@`) needs Firestore read/write (`roles/datastore.user`)

---

## Summary of Task Impact

| Task | Impact | Description |
|------|--------|-------------|
| 11 | MODIFY | Add shared/ copy to Makefile |
| 12 | MODIFY | Add `COPY shared/` to Dockerfile |
| 13 | REWRITE | Agent loop with full 9-event emission |
| 14 | REWRITE | FirestoreClient — all field names corrected |
| 15 | MINOR | Verify log_tokens exists, add import os |
| 16 | MODIFY | Error handling in stream endpoint |
| 21 | REWRITE | HTTP skills — correct request body shapes |
| 25 | REWRITE | SSE proxy — event translation, error handling, workspace_entries |
| 28 | MODIFY | Context builder — field names, hardcoded paths |
| 29 | MODIFY | Memory tools — hardcoded paths, field names |
| 31 | MODIFY | Phase 3c — no-op stubs instead of deletion |
| 33 | MODIFY | MCP auth — premium check fix, deploy config |
| 35 | MODIFY | Firestore rules — add agent_memory |
| 38 | REMOVE | Python workout completion worker |
| 39a | REPLACE | JS Cloud Tasks refactor instead of Python trigger replacement |
| 39b | MODIFY | Fix apply_progression request body |
| 41 | MODIFY | Phase 7 — expanded iOS update scope |
| 42 | MODIFY | Schema doc — additional items |

**New tasks to add:**
- Refactor JS workout triggers to Cloud Tasks (replaces Tasks 38+39a)
- npm dependency additions (uuid, @google-cloud/tasks)
- IAM grants (run.invoker, cloudtasks.enqueuer)
