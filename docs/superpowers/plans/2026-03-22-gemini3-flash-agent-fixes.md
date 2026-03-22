# Gemini 3 Flash Agent Quality Fixes (Revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the quality gap between the Gemini 3 Flash Preview agent (74.8) and Claude Sonnet 4.6 via MCP (84.3). Realistic target: **80-82** via instruction/context fixes. Higher requires fixing infrastructure bugs (out of scope here).

**Architecture:** Modifying `app/instruction.py`, `app/context_builder.py`, and their tests. Judge is already blinded and position-randomized (done separately). No new files.

**Key constraints from adversarial review:**
- Flash models learn better from **examples** than rules — add few-shot examples, not new rule sections
- **Merge** new behaviors into existing sections to avoid instruction bloat (793 lines already)
- The two 22-score cases (conv_004, conv_007) are **infrastructure bugs** (empty responses, wrong tool routing) — instruction changes won't fix them, so don't target 85
- Keep the instruction's "training snapshot" terminology consistent with context builder output

**Speed context:** Gemini 3 Flash is already faster (27s vs 30s) and will be cheaper after context reduction ($0.034 vs $0.039/req). No thinking budget increase — responses must stay snappy.

---

### Task 1: Reduce context contamination in context_builder.py

The #1 root cause (13/25 losses). Pre-loaded alerts and snapshot inject full analytical content into the system instruction, causing the model to anchor on stale/irrelevant data instead of the user's question.

**Files:**
- Modify: `adk_agent/agent_service/app/context_builder.py` — functions `_format_active_alerts` and `_format_snapshot`
- Modify: `adk_agent/agent_service/tests/test_context_builder.py` — update assertions

**What to change:**

Slim down the pre-loaded context to **pointers with just enough detail** for a useful first response, but not so much that the model anchors on it. Keep the section header as "Training Snapshot" to match the instruction's references to "snapshot" in the WHEN TO FETCH MORE DATA section.

- [ ] **Step 1: Rewrite `_format_active_alerts()` — slim but actionable**

Keep exercise names and suggested action type (enough for a useful mention), drop e1RM values and detailed set counts:

```python
def _format_active_alerts(alerts: dict) -> str:
    """Format active alerts as brief pointers — details fetched on demand."""
    flags = []

    plateau = alerts.get("plateau_report")
    if plateau:
        exercises = plateau.get("plateaued_exercises", [])
        for ex in exercises[:3]:
            name = ex.get("exercise_name", "?")
            weeks = ex.get("weeks_stalled", "?")
            action = ex.get("suggested_action", "review")
            flags.append(f"Plateau: {name} ({weeks}wk, suggested: {action})")

    volume = alerts.get("volume_optimization")
    if volume:
        volume_data = volume.get("volume_by_muscle", {})
        deficit_count = sum(1 for v in volume_data.values() if v.get("status") == "deficit")
        surplus_count = sum(1 for v in volume_data.values() if v.get("status") == "surplus")
        if deficit_count:
            flags.append(f"{deficit_count} muscle group(s) below MEV")
        if surplus_count:
            flags.append(f"{surplus_count} muscle group(s) above MRV")

    period = alerts.get("periodization_status")
    if period:
        acwr = period.get("acwr")
        if acwr is not None:
            flags.append(f"ACWR: {acwr}")
        if period.get("suggest_deload"):
            flags.append("Deload recommended")

    if not flags:
        return ""

    return "## Active Flags\n" + "\n".join(f"- {f}" for f in flags) + \
        "\nUse get_training_analysis for full details if relevant to the user's question."
```

- [ ] **Step 2: Slim down `_format_snapshot()` — keep header name**

Keep "Training Snapshot" header to match instruction references. Drop `analysis.summary` (fetch on demand). Keep `fitness_goal` for coaching relevance.

```python
def _format_snapshot(planning: dict) -> str:
    """Format planning context as brief orientation — not a data source."""
    parts = []
    user = planning.get("user", {})
    if user.get("name"):
        parts.append(f"User: {user['name']}")

    attrs = user.get("attributes", {})
    fitness_level = attrs.get("fitness_level") or user.get("fitness_level")
    fitness_goal = attrs.get("fitness_goal") or user.get("fitness_goal")
    if fitness_level:
        parts.append(f"Level: {fitness_level}")
    if fitness_goal:
        parts.append(f"Goal: {fitness_goal}")

    weight_unit = user.get("weight_unit", "kg")
    parts.append(f"Unit: {weight_unit}")

    routine = planning.get("active_routine") or planning.get("activeRoutine")
    if routine:
        parts.append(f"Routine: {routine.get('name', 'Unknown')}")

    if not parts:
        return ""

    return "## Training Snapshot\n" + " | ".join(parts)
```

- [ ] **Step 3: Update tests in `tests/test_context_builder.py`**

Update assertions in `test_build_system_context_includes_all_sections`:
- `"Fitness level: intermediate"` → `"Level: intermediate"`
- `"Goal: hypertrophy"` stays (kept)
- `"Active routine: Push Pull Legs"` → `"Routine: Push Pull Legs"`
- Remove assertion for `"Latest insight: Bench trending up"` (dropped)
- `"Current Training Snapshot"` → `"Training Snapshot"`

Update `test_build_system_context_handles_errors`:
- `"Current Training Snapshot"` → `"Training Snapshot"`

Update `TestFormatSnapshot` class — all assertions to match new format:
- `"Fitness level:"` → `"Level:"`
- `"Active routine:"` → `"Routine:"`
- `"Weight unit:"` → `"Unit:"`
- `"Current Training Snapshot"` → `"Training Snapshot"`
- Remove all `"Latest insight"` assertions
- Both legacy and HTTP compact view tests need updating

- [ ] **Step 4: Run tests**

Run: `cd adk_agent/agent_service && make test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/context_builder.py adk_agent/agent_service/tests/test_context_builder.py
git commit -m "fix(agent): reduce context contamination — slim pointers in system instruction

Alerts now show exercise name + weeks + action type (one line each).
Snapshot shows user overview without analysis summary.
Both sections ~70% smaller. Model fetches full details via tools
when relevant. Addresses 13/25 eval losses."
```

---

### Task 2: Embed ambiguity handling into DATA-FIRST section

Add a clarification clause directly inside the existing DATA-FIRST PRINCIPLE section. No new top-level section — Flash models handle fewer sections better.

**Files:**
- Modify: `adk_agent/agent_service/app/instruction.py` — within `## DATA-FIRST PRINCIPLE`

- [ ] **Step 1: Add clarification clause at the end of DATA-FIRST PRINCIPLE**

Find the paragraph ending with "Even then, if get_planning_context has their profile with frequency preference, USE IT instead of asking." and append after it:

```
**Exception — truly ambiguous queries:**
"What do you think?", "Is this enough?", "Should I?" have no referent without
conversation context. Check earlier turns first — the referent is usually there.
If this is Turn 1 with no context, ask ONE clarification question. Never fetch
all available data hoping something will be relevant.
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/app/instruction.py
git commit -m "feat(agent): add ambiguity clause to DATA-FIRST section

Teaches the model to clarify truly ambiguous queries (no referent)
rather than fetching all data. Embedded in existing section to
avoid instruction bloat."
```

---

### Task 3: Add turn-priority rule and multi-turn example

Strengthen CONVERSATION HISTORY with a critical turn-priority rule, and add a multi-turn few-shot example to the EXAMPLES section. Flash models learn more from examples than rules.

**Files:**
- Modify: `adk_agent/agent_service/app/instruction.py` — `## CONVERSATION HISTORY` and `## EXAMPLES`

- [ ] **Step 1: Add turn-priority rule to CONVERSATION HISTORY**

After the existing `### Progressive depth` subsection, add:

```
### Turn priority (CRITICAL)
The user's current message is ALWAYS the primary input. Pre-loaded context
(snapshot, alerts, memories) is orientation — it must never redirect your
answer away from what the user actually asked.

Anti-pattern: User asks about bench in Turn 3. Alerts mention a squat plateau.
You answer about squats. This is wrong — answer the question that was asked.

Turn 2+ rule: The user is narrowing or building on Turn 1. Don't restart.
Don't introduce topics from pre-loaded context the user hasn't mentioned.
```

- [ ] **Step 2: Add multi-turn few-shot example to EXAMPLES section**

Add before the `## ACTIVE WORKOUT MODE` section:

```
User (Turn 1): "How's my squat doing?"
Think: Specific exercise question -> drill down
Tool: get_exercise_progress(exercise_id="squat")
Response: "Squat e1RM is 102kg, up from 95kg over 6 weeks. Solid progress — you're
hitting 5x5 at 90kg with RIR 2. Ready for 92.5kg next session."

User (Turn 2): "I've been trying to add weight but it's not working"
Think: CONTINUATION of squat conversation. I already have squat data from Turn 1.
Don't re-fetch. Don't pivot to other exercises. The user means squat weight specifically.
Response: "Your squat data shows consistent 5x5 at 90kg for 3 weeks — you're right,
it has stalled. Before adding weight, try: drop to 3x5 at 92.5kg and build back to 5x5.
If that doesn't break it in 2 weeks, switch to 3x8 at 80kg for a rep range change."

User (Turn 3): "What about front squats instead?"
Think: Still on the squat thread. User is exploring alternatives. I have their squat
data already — don't re-fetch everything. Answer about front squats specifically.
Tool: get_exercise_progress(exercise_id="front squat")
Response: "No front squat history yet. It's a solid alternative — expect about 82% of
your back squat, so start around 72.5kg. It'll hit your quads harder and force better
positioning. Want me to swap it into your routine?"
```

- [ ] **Step 3: Commit**

```bash
git add adk_agent/agent_service/app/instruction.py
git commit -m "feat(agent): add turn-priority rule and multi-turn example

Embeds turn-priority in CONVERSATION HISTORY and adds a 3-turn
few-shot example showing how to maintain topic coherence across
turns without re-fetching data."
```

---

### Task 4: Embed safety override and tone matching into existing sections

Instead of adding two new top-level sections, embed safety override into RESPONSE CRAFT (where brevity rules live) and tone matching into IDENTITY (where persona is defined). This keeps the section count constant.

**Files:**
- Modify: `adk_agent/agent_service/app/instruction.py` — `## RESPONSE CRAFT` and `## IDENTITY`

- [ ] **Step 1: Add safety override to RESPONSE CRAFT**

After the paragraph about "Default: if unsure, err toward more detail.", add:

```
**Safety override:** When the user reports acute symptoms (dizziness, chest
pressure, numbness, sharp pain), override all length rules. Give thorough
guidance: stop/modify/continue verdict, escalation criteria (when to see
a doctor), and return-to-training protocol. Safety > brevity.
```

- [ ] **Step 2: Add tone matching to IDENTITY**

After the line "Correct wrong assumptions plainly. Never narrate your tool usage or internal reasoning.", add:

```
Match the user's emotional register: frustrated → acknowledge then redirect
to data; fatigued → empathize briefly then give a verdict; excited → match
energy then add coaching value. One sentence of empathy max, then coaching.
```

- [ ] **Step 3: Add a tone-matching few-shot example to EXAMPLES**

Add after the "I feel beat up, should I skip?" example:

```
User: "Nothing is working, I'm getting weaker"
Think: Frustrated + claim of regression. Acknowledge the feeling, then check the data.
Don't lead with analytics — lead with empathy.
Tool: get_training_analysis()
Response: "That's a frustrating place to be. Let me check what's actually happening.
Your bench and squat are flat over 3 weeks, but your deadlift is still climbing.
You're not getting weaker — you're stalling on two lifts. Both are at RIR 3-4,
which is too conservative. Push closer to failure (RIR 1-2) before we add volume
or swap anything."
```

- [ ] **Step 4: Commit**

```bash
git add adk_agent/agent_service/app/instruction.py
git commit -m "feat(agent): embed safety override in RESPONSE CRAFT, tone matching in IDENTITY

Safety-critical queries override brevity rules. Tone matching
teaches emotional register awareness. Both embedded in existing
sections, plus a frustrated-user few-shot example."
```

---

### Task 5: Update instruction tests

Verify the new section content is present so future refactors don't accidentally delete safety-critical or tone-matching rules.

**Files:**
- Modify: `adk_agent/agent_service/tests/test_instruction.py` (if it exists) or verify via a simple check

- [ ] **Step 1: Check if test_instruction.py exists and update**

If `tests/test_instruction.py` has a `required_sections` or similar assertion list, add:
- `"Turn priority (CRITICAL)"`
- `"Safety override"`
- `"emotional register"`

If no test file exists for instruction content, skip — the eval is the real test.

- [ ] **Step 2: Run full test suite**

Run: `cd adk_agent/agent_service && make test`
Expected: All tests pass.

- [ ] **Step 3: Commit (if tests were updated)**

```bash
git add adk_agent/agent_service/tests/
git commit -m "test(agent): verify new instruction content in test assertions"
```

---

### Task 6: Deploy and run targeted eval on hardest cases

Test on the 5 hardest cases first before committing to a full 40-case run.

**Files:**
- No code changes — deployment and eval only.

- [ ] **Step 1: Deploy with Gemini 3 Flash Preview**

```bash
cd adk_agent/agent_service
AGENT_MODEL=gemini-3-flash-preview GOOGLE_CLOUD_LOCATION=global make deploy
```

- [ ] **Step 2: Run targeted eval on 5 hardest cases**

These are the decisive Claude wins that instruction changes CAN affect (excluding the two infrastructure failures conv_004/conv_007):

```bash
cd /Users/valterandersson/Documents/Povver
PYTHONPATH=adk_agent/agent_service/tests/eval \
  EVAL_MCP_API_KEY=f5d1a2c7accd9927082ca2f2a32d5885d51f7caea6f6b42453118c0bf54db16d \
  /Users/valterandersson/Documents/Povver/adk_agent/agent_service/.venv/bin/python \
  -m comparative.runner --no-insights \
  --id amb_002 --id amb_007 --id conv_005 --id conv_008 --id conv_009
```

If `--id` doesn't support multiple values, run them individually or add support.

**What to look for:**
- amb_002 (was 41): Should clarify instead of dumping analysis. Target: 70+
- amb_007 (was 29): Should ask what "this" refers to. Target: 70+
- conv_005 (was 80): Should improve with reduced context contamination. Target: 85+
- conv_008 (was 66): Should improve with tone matching. Target: 78+
- conv_009 (was 55): Should improve with turn priority. Target: 72+

- [ ] **Step 3: If targeted results improve, run full 40-case eval**

```bash
PYTHONPATH=adk_agent/agent_service/tests/eval \
  EVAL_MCP_API_KEY=f5d1a2c7accd9927082ca2f2a32d5885d51f7caea6f6b42453118c0bf54db16d \
  /Users/valterandersson/Documents/Povver/adk_agent/agent_service/.venv/bin/python \
  -m comparative.runner --no-insights
```

**Important:** The judge is now blinded and position-randomized. This means:
- Scores may shift in BOTH directions (Claude scores may drop too if bias was helping them)
- The baseline has changed — compare against the new judge, not the old 74.8/84.3 numbers
- Focus on the GAP narrowing, not absolute scores

- [ ] **Step 4: Commit eval results**

```bash
git add adk_agent/agent_service/tests/eval/comparative/results/
git commit -m "eval: post-fix results with blinded judge

Gemini 3 Flash Preview after context/instruction fixes.
Judge now blinded and position-randomized."
```

- [ ] **Step 5: Decide on production model**

```bash
# To keep Gemini 3 Flash Preview (if results are good):
# Already deployed from Step 1

# To revert all changes and go back to baseline:
git revert HEAD~5  # Undo Tasks 1-5
AGENT_MODEL=gemini-2.5-flash make deploy
```
