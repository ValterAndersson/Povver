# MCP Server Optimization Report

**Date:** 2026-03-18
**Author:** Claude (AI agent consumer perspective)
**Context:** Full conversation exercising all Povver MCP endpoints against real user data, evaluating fitness for AI agent consumption.

---

## 1. Use-Case Analysis

### Who is the user?

A fitness enthusiast who tracks workouts (imported from Strong), follows a structured routine, and wants an AI assistant to help them understand their training. They are not a data analyst — they want *insights*, not spreadsheets.

### What do they ask?

Analyzing the typical fitness AI assistant interaction, questions cluster into **5 categories** ordered by frequency:

| Category | Example Questions | Frequency |
|----------|------------------|-----------|
| **Status** | "What should I do today?" / "What's my next workout?" / "What did I do last time?" | Very High |
| **Progress** | "Am I getting stronger?" / "How's my bench progressing?" / "Am I overtraining?" | High |
| **Understanding** | "What does my routine look like?" / "How much chest work am I doing?" / "What exercises hit rear delts?" | Medium |
| **Modification** | "Add more chest volume" / "Swap squats for leg press" / "Make it a 4-day split" | Medium |
| **Planning** | "Create me a new PPL routine" / "Design a peaking program for my deadlift" | Low |

### What does the agent need to answer them?

For **80% of questions**, the agent needs:
1. The user's current routine with exercise names and prescriptions
2. Their last few workouts with exercise names and key metrics
3. Progression trends (e1RM over time, volume trends)
4. Pre-computed analysis (stalls, recommendations, fatigue status)

For the remaining 20%, the agent needs:
5. Exercise catalog search (compact)
6. Mutation capabilities (template/routine updates)

---

## 2. Current Endpoint Audit

### 2.1 Token Budget Reality

An MCP tool call response that an LLM can process in-context is roughly **4,000–8,000 tokens** (~12–25KB of JSON). Anything larger gets truncated or saved to a file, requiring the agent to shell out to parse it — destroying the workflow.

| Endpoint | Payload Size | Fits in Context? | Agent Experience |
|----------|-------------|-----------------|------------------|
| `list_workouts(5)` | **141 KB** | No | Saved to file, required python/jq parsing |
| `get_training_snapshot` | **129 KB** | No | Saved to file, required python/jq parsing |
| `search_exercises("rear delt")` | **59 KB** (15 items) | No | Saved to file |
| `search_exercises("seated row")` | **108 KB** | No | Saved to file |
| `search_exercises("incline bench")` | **176 KB** | No | Saved to file |
| `get_template` | **3–5 KB** | Yes | But no exercise names |
| `get_routine` | **0.5 KB** | Yes | But only template IDs, no names |
| `get_training_analysis` | **12 KB** | Borderline | Recommendation history is bloated |
| `get_exercise_progress` | **0.8 KB** | Yes | But `weekly_points` always empty |
| `get_muscle_group_progress` | **0.6 KB** | Yes | But `weekly_points` always empty |
| `query_sets(limit=50)` | **8 KB** | Yes | Best endpoint for raw drill-down |
| `list_routines` | **0.5 KB** | Yes | Fine |
| `list_templates` | **59 KB** | No | Returns full template objects with all sets |
| `get_workout` | **8–15 KB** | Borderline | Full analytics per exercise is heavy |
| `list_memories` | **0.01 KB** | Yes | Empty |

**Verdict:** 6 of 15 data endpoints exceed agent context limits. These are the most commonly needed endpoints.

### 2.2 Endpoint-by-Endpoint Issues

#### `list_workouts`
- **Problem:** Returns complete workout objects including every set, every per-muscle analytics breakdown, and every intensity metric. Requesting 5 workouts produces 141KB.
- **What the agent actually needs:** Date, name/template name, exercise names, total sets, total volume, duration. ~200 bytes per workout.
- **Waste factor:** ~140x

#### `get_training_snapshot`
- **Problem:** Embeds full template objects (with all sets and analytics), full recent workout summaries, and full user profile. 129KB.
- **What the agent actually needs:** User name, active routine name + template names, next workout name, recent workout summaries (date + name + key metrics), strength summary table. ~2KB.
- **Waste factor:** ~65x

#### `search_exercises`
- **Problem:** Returns full exercise catalog entries including execution_notes (multi-paragraph), common_mistakes (multi-paragraph), programming_use_cases, suitability_notes, stimulus_tags, review_metadata, and full contribution maps. Each exercise is 2.7–4.5KB. A search for "incline bench" returns 176KB.
- **What the agent usually needs:** Name, ID, equipment, primary muscles, muscle contribution map. ~200 bytes per exercise.
- **Waste factor:** ~50x
- **Additional problem:** Search for "rear delt" returns "Back Squat (Barbell)" as the first result. Search relevance needs work.

#### `get_template`
- **Problem:** Exercise names are not included — only `exercise_id` (e.g., `K21gndDYgWE25mFmPamH`). To present a template to the user, the agent must resolve every exercise ID via `search_exercises` (which itself overflows context) or `query_sets` (hoping the exercise appears in workout history).
- **Impact:** In this conversation, I made 6 `get_template` calls + 3 `search_exercises` calls + multiple `query_sets` calls and **still couldn't fully resolve all exercise names**. I had to infer from muscle group analytics.
- **What the agent needs:** Exercise name alongside exercise_id. A simple server-side join.

#### `get_routine`
- **Problem:** Returns only template IDs, not template names or exercise summaries.
- **What the agent needs for "what's my routine?":** Routine name, description, template names in order, and ideally exercise names per template. One call should answer this question.

#### `list_templates`
- **Problem:** Returns all templates with full set prescriptions, full analytics. 59KB for 6 templates.
- **What the agent usually needs:** Template name, exercise names, set/rep scheme summary. ~300 bytes per template.

#### `get_exercise_progress` and `get_muscle_group_progress`
- **Problem:** `weekly_points` is always an empty array. The `summary` object has all zeros. The only useful data is `last_session` and `top_exercises`.
- **Impact:** These endpoints *should* be the primary way to answer "how am I progressing?" but they return no trend data. The agent must fall back to `query_sets` and manually reconstruct week-by-week progression — burning tokens on data aggregation that the server should do.
- **PR markers:** `all_time_e1rm` and `window_e1rm` are always null.

#### `get_training_analysis`
- **Best endpoint in the server.** Returns pre-computed insights, exercise trends with e1RM slopes, stall detection, progression candidates, muscle balance assessment, fatigue status, and periodization recommendations.
- **Problem:** The `recommendation_history` array is bloated — in this user's case, it contained **21 recommendations**, most of which were expired duplicates of the same "increase your ACWR" message. This added ~8KB of noise.
- **Fix:** Filter to only `pending_review` recommendations by default. Add a `include_expired: true` flag for the full history.

#### `query_sets`
- **Best raw data endpoint.** Returns flat, compact set-level data. Supports filtering by exercise_name, muscle_group, or muscle. Paginated with cursor.
- **Problem 1:** The parameter schema says `target: object` with a vague description. I got an error on first attempt using `{"exercise": "..."}` — it needed `{"exercise_name": "..."}`. The accepted keys (`exercise_name`, `muscle_group`, `muscle`, `exercise_ids`) should be explicit in the schema.
- **Problem 2:** Filtering by `muscle_group: "shoulders"` returns sets for exercises that *contribute to* shoulders (like Incline Bench Press, Face Pull) — not just "shoulder exercises." This is actually correct behavior, but surprising when you expect only lateral raises and OHP. A note in the description would help.

#### `create_template` / `update_template` / `create_routine` / `update_routine`
- **Not tested deeply**, but the schemas for `exercises` (array) and `updates` (object) are untyped — `"type": "array"` and `"type": "object"` with no inner schema. An agent cannot know the expected shape without reading source code or guessing from GET responses.
- **Impact:** An agent attempting to create a template must guess the exercise object structure: Does it need `exercise_id` or `name`? What's the set object shape? Is `position` required? This will cause errors and retry loops.

---

## 3. Simulated Question Walkthrough

### Q1: "What should I do today?"
**Ideal:** 1 tool call → answer
**Current:** `get_training_snapshot` (129KB, overflows) → parse with bash → extract `nextWorkout`
**Calls needed:** 1 MCP + 1 bash = answer is buried in 129KB

### Q2: "How's my bench press progressing?"
**Ideal:** 1 tool call → trend table + insight
**Current:** `get_exercise_progress("bench press")` → weekly_points empty, only last_session → fall back to `query_sets(exercise_name="bench press", limit=50)` → manually reconstruct trend
**Calls needed:** 2 MCP calls, manual aggregation in response

### Q3: "What does my routine look like?"
**Ideal:** 1 tool call → routine with template names and exercise names
**Current:** `get_routine` → only template IDs → 6× `get_template` → only exercise IDs → N× `search_exercises` (overflow) or guess from analytics
**Calls needed:** 7–15 MCP calls, never fully resolved

### Q4: "What exercises hit my rear delts?"
**Ideal:** 1 tool call → compact list of exercise names + equipment
**Current:** `search_exercises("rear delt")` → 59KB overflow → bash parse → 15 results including Back Squat (irrelevant)
**Calls needed:** 1 MCP + 1 bash, poor relevance

### Q5: "Am I overtraining?"
**Ideal:** 1 tool call → fatigue status + ACWR + muscle-level risk
**Current:** `get_training_analysis` → 12KB, mostly good, but bloated recommendation_history
**Calls needed:** 1 MCP call — this is the best-served question

### Q6: "Add rear delt flyes to my push day"
**Ideal:** `search_exercises("rear delt fly", limit=3, fields=compact)` → pick one → `update_template(id, add_exercise={...})`
**Current:** `search_exercises` overflows → parse → `update_template` but unknown schema for exercise objects → likely error → retry
**Calls needed:** 3–5 MCP + bash + trial-and-error

---

## 4. Structural Problems

### 4.1 Duplicate Exercise Identity
The same exercise exists under multiple IDs:
- Seated Row: `close_grip_seated_row__close-grip-seated-row-cable` AND `EmwLvaNmqfnGgZEMHaw7`
- Romanian Deadlift: `romanian_deadlift__romanian-deadlift-barbell` AND `sjlaDW7zPtuCGF2AKS2m`
- Incline Bench Press: `incline_bench_press__incline-bench-press` AND `Ge9pY2HahgSfaNLhy9s3`
- Chest Press: `chest_press__bench-press-machine` AND `K21gndDYgWE25mFmPamH`

This appears to be a catalog-ID vs template-exercise-ID distinction, but the agent cannot easily aggregate data across them. `get_muscle_group_progress` returns both as separate top_exercises entries, making the user's data look fragmented.

### 4.2 Inconsistent Muscle Group Casing
Template analytics mix cased and lowercase muscle group keys:
```json
"sets_per_muscle_group": {
  "shoulders": 3,     // lowercase
  "Chest": 4,         // Capitalized
  "Shoulders": 4,     // Capitalized (duplicate of "shoulders"!)
  "back": 4,
  "arms": 3
}
```
"shoulders" and "Shoulders" appear as separate entries in the same object. Similarly "Pectoralis Major" vs "pectoralis major", "Anterior Deltoid" vs "anterior deltoid" in muscle-level analytics.

### 4.3 No Denormalization on References
Every foreign key relationship requires a separate call to resolve:
- Routine → template_ids (no names)
- Template → exercise_id (no names)
- Workout → source_template_id (no name)

This is a normalized database pattern exposed directly to the API consumer. For a human developer building a UI, this is fine — they batch-resolve once and cache. For a stateless AI agent, every conversation requires re-resolving everything from scratch.

---

## 5. Recommendations: Best-in-Class MCP Server

### 5.1 Design Principles

1. **Conclusions over data.** The server should compute what the agent would otherwise have to derive. Trends, comparisons, summaries — these should be server-side.
2. **Summary by default, detail on demand.** Every endpoint should return a compact summary unless explicitly asked for more.
3. **Denormalize all references.** Every foreign key should include the referenced entity's name. Always.
4. **Respect token budgets.** No response should exceed 4KB by default. Provide opt-in verbosity for drill-down.
5. **Typed mutation schemas.** Create/update endpoints must have fully typed parameter schemas so agents know what to send.

### 5.2 Endpoint Redesign

#### Tier 1: High-frequency endpoints (answer 80% of questions)

##### `get_training_snapshot` (redesign)
Default response (~2KB):
```json
{
  "user": { "name": "Valter", "weight_unit": "lbs" },
  "active_routine": {
    "id": "...",
    "name": "Alternating Full Body A/B/C Split",
    "description": "3-day/week, two-week cycle...",
    "templates": [
      { "id": "...", "name": "Workout A1", "exercises": ["Chest Press", "Lat Pulldown", "Incline Bench Press", "Hammer Curl", "Lateral Raise", "Skullcrusher"] },
      { "id": "...", "name": "Workout B1", "exercises": ["Incline Bench Press", "Seated Row", "Romanian Deadlift", "Preacher Curl", "Triceps Extension", "Face Pull"] }
    ]
  },
  "next_workout": {
    "template_name": "Workout A1",
    "template_id": "...",
    "selection_method": "cursor"
  },
  "recent_workouts": [
    { "id": "...", "date": "2026-01-29", "template_name": "Workout B", "exercises": ["Seated Row", "Incline Bench Press", "Bicep Curl", "Face Pull", "Triceps Extension", "Lying Leg Curl"], "total_sets": 28, "total_volume_kg": 12600, "duration_min": 60 }
  ],
  "strength_summary": [
    { "exercise": "Deadlift", "e1rm": 165.3, "weight": 160, "reps": 1 },
    { "exercise": "Chest Press", "e1rm": 133.3, "weight": 100, "reps": 10 }
  ],
  "days_since_last_workout": 48,
  "acwr": 0.08,
  "fatigue_status": "fresh"
}
```

##### `get_exercise_progress` (fix + enhance)
**Fix:** `weekly_points` must actually return data. This is the core value proposition.

Response (~1.5KB):
```json
{
  "exercise": "Incline Bench Press",
  "exercise_id": "incline_bench_press__incline-bench-press",
  "weekly_points": [
    { "week": "2026-W01", "best_e1rm": 72.8, "total_sets": 6, "avg_rir": 1.3 },
    { "week": "2026-W02", "best_e1rm": 71.1, "total_sets": 4, "avg_rir": 2.5 },
    { "week": "2026-W03", "best_e1rm": 74.7, "total_sets": 5, "avg_rir": 1.3 },
    { "week": "2026-W04", "best_e1rm": 74.7, "total_sets": 5, "avg_rir": 1.0 },
    { "week": "2026-W05", "best_e1rm": 76.0, "total_sets": 5, "avg_rir": 1.0 }
  ],
  "trend": "improving",
  "e1rm_slope_per_week": 0.59,
  "last_session": {
    "date": "2026-01-29",
    "top_set": { "weight_kg": 60, "reps": 8, "rir": 0, "e1rm": 76 },
    "total_sets": 5,
    "working_sets": 3
  },
  "pr": { "e1rm": 76, "date": "2026-01-29" },
  "plateau": false,
  "suggestion": null
}
```

##### `list_workouts` (add verbosity)
Default `verbosity: "summary"` (~300 bytes/workout):
```json
{
  "workouts": [
    {
      "id": "...",
      "date": "2026-01-29",
      "template_name": "Workout B",
      "exercises": ["Seated Row", "Incline Bench Press", "Bicep Curl", "Face Pull", "Triceps Extension", "Lying Leg Curl"],
      "total_sets": 28,
      "total_volume_kg": 12600,
      "duration_min": 60
    }
  ]
}
```
`verbosity: "detail"` returns current full response.

#### Tier 2: Medium-frequency endpoints

##### `get_routine_detail` (new composite endpoint)
Replaces: `get_routine` + N× `get_template` + N× exercise resolution

Response (~3KB):
```json
{
  "id": "...",
  "name": "Alternating Full Body A/B/C Split",
  "description": "...",
  "frequency": 3,
  "cycle_length_weeks": 2,
  "templates": [
    {
      "id": "...",
      "name": "Workout A1",
      "position": 0,
      "estimated_duration": 40,
      "exercises": [
        {
          "exercise_id": "...",
          "name": "Chest Press (Machine)",
          "position": 0,
          "working_sets": 4,
          "working_reps": 8,
          "working_weight": 95,
          "warmup_sets": 2,
          "target_rir": "2-5"
        }
      ],
      "muscle_group_sets": { "chest": 4, "back": 4, "shoulders": 3, "arms": 3 }
    }
  ],
  "weekly_muscle_balance": {
    "chest": { "avg_sets": 9.2, "status": "undertrained" },
    "back": { "avg_sets": 17.2, "status": "optimal" }
  }
}
```

##### `search_exercises` (add compact mode)
Default `fields: "compact"` (~100 bytes/exercise):
```json
{
  "items": [
    {
      "id": "rear_delt_fly__rear-delt-fly-cable",
      "name": "Rear Delt Fly (Cable)",
      "equipment": ["cable"],
      "category": "isolation",
      "primary_muscles": ["posterior deltoid"],
      "contribution": { "posterior deltoid": 0.6, "rhomboids": 0.2, "trapezius": 0.2 }
    }
  ]
}
```
`fields: "full"` returns current response with execution notes, common mistakes, etc.

Also: fix search relevance — "Back Squat" should not be the top result for "rear delt."

##### `get_training_analysis` (trim recommendation_history)
- Default: only `pending_review` recommendations
- Add `include_expired: true` for full history
- This alone would cut the response from ~12KB to ~4KB for this user

#### Tier 3: Low-frequency but important

##### `compare_exercises` (new endpoint)
For "compare my squat vs deadlift" or "how does bench compare to incline":
```json
{
  "exercises": [
    {
      "name": "Squat",
      "current_e1rm": 88.7,
      "trend": "improving",
      "slope": 0.5,
      "last_session": { "date": "2026-01-05", "top_set": "60kg × 10" },
      "total_sessions": 4
    },
    {
      "name": "Deadlift",
      "current_e1rm": 165.3,
      "trend": "stable",
      "slope": 0.1,
      "last_session": { "date": "2025-12-11", "top_set": "160kg × 1" },
      "total_sessions": 2
    }
  ]
}
```

##### Mutation schemas (fix)
`create_template` and `update_template` need fully typed schemas:
```json
{
  "name": "string (required)",
  "exercises": [
    {
      "exercise_id": "string (required) — use search_exercises to find",
      "position": "number (required)",
      "sets": [
        {
          "type": "enum: warmup | working",
          "weight": "number (kg)",
          "reps": "number",
          "rir": "number (0-5)"
        }
      ]
    }
  ]
}
```

### 5.3 New: Agent-Oriented Meta Endpoint

##### `answer_question` (new, highest leverage)
An endpoint that takes a natural language question and returns a structured, pre-computed answer:
```json
// Request
{ "question": "How is my chest progressing?" }

// Response (~1KB)
{
  "answer_type": "muscle_group_progress",
  "muscle_group": "chest",
  "status": "undertrained",
  "weekly_sets": 9.2,
  "trend": "decreasing",
  "top_exercises": [
    { "name": "Chest Press", "e1rm": 133.3, "trend": "improving", "slope": 0.75 },
    { "name": "Incline Bench Press", "e1rm": 76.0, "trend": "improving", "slope": 0.59 }
  ],
  "recommendation": "Increase chest volume from 9.2 to 12+ sets/week",
  "supporting_data_tool": "query_sets",
  "supporting_data_params": { "muscle_group": "chest", "limit": 30 }
}
```

This is the ultimate "agent-friendly" pattern: give the answer, and provide a pointer to raw data if the agent needs to drill deeper. The agent can present the answer immediately and only make follow-up calls if the user asks for more detail.

### 5.4 Quick Wins (Minimal Server Changes)

These changes would have the biggest impact with the least effort:

| Change | Effort | Impact |
|--------|--------|--------|
| Add `exercise_name` to template exercise objects | Low | Eliminates 70% of round-trips |
| Add `verbosity` param to `list_workouts`, `get_training_snapshot`, `list_templates` | Medium | Fixes all overflow issues |
| Fix `weekly_points` in progress endpoints | Medium | Makes progress tracking actually work |
| Add `fields: "compact"` to `search_exercises` | Low | 50x payload reduction |
| Filter `recommendation_history` to `pending_review` by default | Low | Cuts `get_training_analysis` by 60% |
| Fix muscle group casing inconsistency | Low | Eliminates data quality confusion |
| Resolve duplicate exercise IDs in aggregations | Medium | Clean data presentation |
| Add typed schemas to mutation endpoints | Low | Enables agent-driven routine modifications |

### 5.5 Response Size Targets

| Endpoint | Current | Target (default) | Target (detailed) |
|----------|---------|-------------------|---------------------|
| `get_training_snapshot` | 129 KB | **2 KB** | 15 KB |
| `list_workouts(5)` | 141 KB | **1.5 KB** | 50 KB |
| `list_templates` | 59 KB | **2 KB** | 59 KB |
| `search_exercises(3)` | 59–176 KB | **0.5 KB** | 15 KB |
| `get_template` | 3–5 KB | **1.5 KB** | 5 KB |
| `get_training_analysis` | 12 KB | **4 KB** | 12 KB |
| `get_workout` | 8–15 KB | **1 KB** | 15 KB |

---

## 6. Token Cost Analysis

### Current: Answering "How am I progressing overall?"

| Step | Calls | Tokens In | Tokens Out |
|------|-------|-----------|------------|
| Get snapshot | 1 MCP + 1 bash | ~35K (overflow parse) | — |
| Get training analysis | 1 MCP | ~3K | — |
| Get 5 muscle groups | 5 MCP | ~2.5K | — |
| Resolve exercise names | 6 get_template + 3 search + bash | ~20K | — |
| Query raw sets for drill-down | 2 MCP | ~4K | — |
| **Total** | **~20 calls** | **~65K tokens** | ~2K answer |

### Optimized: Same question

| Step | Calls | Tokens In | Tokens Out |
|------|-------|-----------|------------|
| Get snapshot (compact) | 1 MCP | ~0.6K | — |
| Get training analysis (trimmed) | 1 MCP | ~1.2K | — |
| Get muscle group progress (with weekly_points) | 5 MCP | ~4K | — |
| **Total** | **7 calls** | **~6K tokens** | ~2K answer |

**Reduction: 65K → 6K input tokens (10x), 20 → 7 calls (3x)**

### With `answer_question` endpoint:

| Step | Calls | Tokens In |
|------|-------|-----------|
| answer_question("full body progress overview") | 1 MCP | ~2K |
| Optional drill-down on flagged areas | 1–2 MCP | ~1K |
| **Total** | **2–3 calls** | **~3K tokens** |

**Reduction: 65K → 3K input tokens (22x), 20 → 3 calls (7x)**

---

## 7. Priority Ordering

### P0 — Ship this week
1. **Add `exercise_name` to template exercise objects** — server-side join, eliminates the biggest pain point
2. **Add `verbosity: "summary"` to `list_workouts` and `get_training_snapshot`** — fixes all overflow issues
3. **Fix `weekly_points` in `get_exercise_progress` and `get_muscle_group_progress`** — makes the progress endpoints actually useful

### P1 — Ship this month
4. Add `fields: "compact"` to `search_exercises`
5. Filter `recommendation_history` to `pending_review` by default in `get_training_analysis`
6. Create `get_routine_detail` composite endpoint
7. Add typed schemas to `create_template` / `update_template`
8. Fix muscle group casing inconsistency

### P2 — Next quarter
9. Create `compare_exercises` endpoint
10. Resolve duplicate exercise ID issue in aggregations
11. Build `answer_question` meta-endpoint
12. Add `max_tokens` budget parameter across all endpoints

---

## 8. Summary

The Povver MCP server has the right *endpoints* but the wrong *defaults*. The data model is comprehensive and the analysis engine (`get_training_analysis`) is genuinely impressive. But the server is designed for a UI developer who will call endpoints once, cache, and render — not for a stateless AI agent that must re-discover everything each conversation and process responses within a token budget.

The core shift needed is: **optimize for the cold-start, token-constrained reader.** Every response should assume the consumer has never seen this data before, has limited memory, and needs the answer — not the raw material to construct the answer.

Three changes would transform the agent experience:
1. Denormalize exercise names everywhere
2. Add summary/compact response modes
3. Fix the weekly_points time-series data

These are not architectural changes — they're response formatting changes on existing infrastructure. The data and the analysis engine are already there. The server just needs to present them in an agent-consumable way.
