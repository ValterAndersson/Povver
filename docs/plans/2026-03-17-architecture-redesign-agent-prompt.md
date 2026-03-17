# Architecture Redesign — Agent Execution Prompt

You are implementing a major architecture redesign for a fitness coaching app called Povver. The work is fully planned — your job is execution, not design.

## Documents (read in this order)

1. **Spec** → `docs/plans/2026-03-17-architecture-redesign-design.md` — the architectural design. Read the full thing once at the start to understand *what* you're building and *why*.

2. **Errata** → `docs/plans/2026-03-17-architecture-redesign-errata.md` — 5 architectural decisions (AD-1 through AD-5) that override parts of the original spec. These are already incorporated into the plan, but read them to understand the reasoning behind key decisions:
   - AD-1: Workout completion stays in JS (not ported to Python)
   - AD-2: Artifact emission happens in the agent service (not the proxy)
   - AD-3: SSE proxy translates event names during Phase 3a→7
   - AD-4: Canvas endpoints become no-ops (not deleted) until Phase 7
   - AD-5: All Firestore reads must match actual field names from FIRESTORE_SCHEMA.md

3. **Plan** → `docs/plans/2026-03-17-architecture-redesign-plan.md` — the implementation plan. ~5,800 lines, 43 tasks across 6 chunks. You execute this task by task.

4. **CLAUDE.md** → project root — engineering philosophy, security rules, build commands, conventions. Follow these.

## How to Work

### Per-task workflow

For each task:

1. **Read the task** in the plan. Note its `Read first:` section — those are the specific source files you must read before writing any code.
2. **Read `docs/FIRESTORE_SCHEMA.md`** if the task touches Firestore field names or collection paths. This is the canonical source of truth for field names. Getting these wrong was the #1 class of bug found during review.
3. **Read `docs/SECURITY.md`** if the task creates endpoints, touches auth, or handles user data.
4. **Read the source files** listed in `Read first:`. Understand the existing code before modifying it.
5. **Execute the steps** in order. Steps use `- [ ]` checkbox syntax. Each step is one action (2-5 minutes).
6. **Run tests** where indicated. Don't skip test steps.
7. **Commit** at each commit step. Use the commit message provided in the plan.

### What NOT to do

- **Don't read the entire plan upfront.** It's 5,800 lines. Read only the current task and its read-first files.
- **Don't redesign or second-guess the architecture.** The design went through multiple review cycles including a boundary contract audit. If something looks wrong, it's more likely you're missing context than that the plan is wrong.
- **Don't skip `Read first:` files.** The #1 failure mode is writing code based on the plan's description instead of reading the actual source. The plan tells you *what* to extract — the source files show you the *exact* logic.
- **Don't add features, refactor adjacent code, or "improve" things not in the task.** Stay scoped.
- **Don't use `display_name`** — the field is `name`. Don't use `timestamp` — the field is `created_at`. Don't use `role` in messages — the field is `type`. These were systematic errors found during review. Always check FIRESTORE_SCHEMA.md.

### Critical field name rules (AD-5)

These are the most common errors. Burn them in:

| Wrong | Correct | Where |
|-------|---------|-------|
| `display_name` | `name` | User documents |
| `timestamp` | `created_at` | Message documents |
| `role` (user/assistant) | `type` (user_prompt/agent_response) | Message documents |
| `exercise_name` as query key | `exercise_id` | set_facts queries, exercise series |
| `exercise_series` | `analytics_series_exercise` | Collection name |
| `muscle_group_series` | `analytics_series_muscle_group` | Collection name |
| `weekly_stats/current` | `weekly_stats/{week_start_date}` | Document path |
| `conversations` (hardcoded) | `CONVERSATION_COLLECTION` constant | Python collection paths |
| `FIREBASE_FUNCTIONS_URL` | `MYON_FUNCTIONS_BASE_URL` | Env var name |
| `subscription_status.is_premium` | `subscription_override === 'premium' \|\| subscription_tier === 'premium'` | Premium checks |

### Chunk order

The plan is divided into 6 chunks. Execute in order:

| Chunk | Phases | Tasks | What it builds |
|-------|--------|-------|----------------|
| 1 | 1 + 2 | 1–9 | Observability dashboards + shared business logic extraction |
| 2 | 3a (part 1) | 10–16 | Agent service infrastructure (scaffold, LLM client, agent loop, Firestore client, main.py) |
| 3 | 3a (part 2) | 17–26 | Skill migration, router, instruction, SSE proxy update, deploy + E2E verify |
| 4 | 3b + 3c | 27–31 | Agent memory system + session elimination + dead code removal |
| 5 | 4 + 5 | 32–37, 39b | MCP server + workout trigger Cloud Tasks refactor |
| 6 | 6 + 7 | 40–43 | Training analyst enhancements + iOS cleanup (canvases→conversations) |

### Build & test commands

```bash
# iOS
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Firebase Functions
cd firebase_functions/functions && npm install && npm test
cd firebase_functions/functions && npm run deploy

# Agent Service
cd adk_agent/agent_service && python -m pytest tests/ -v
cd adk_agent/agent_service && make deploy

# Training Analyst
cd adk_agent/training_analyst && make test
```

### Security rules (non-negotiable)

- Every endpoint uses `getAuthenticatedUserId(req)` — never derive userId from request body in bearer-lane endpoints
- Only Admin SDK writes `subscription_*` fields
- Premium gates use `isPremiumUser(userId)` server-side
- Validate all inputs with upper bounds before business logic
- New Firestore collections must be added to `firestore.rules`

## Start

Begin with **Chunk 1, Task 1**. Read the task in the plan, execute its steps, commit, then move to Task 2.
