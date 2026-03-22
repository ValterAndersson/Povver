# Agent Improvement Plan: Closing the Gap with Raw Claude MCP

## Eval Results (Baseline)

| Metric | Gemini Agent | Claude MCP | Delta |
|--------|-------------|------------|-------|
| Overall | 56.8 | 87.5 | -30.7 |
| Correctness | 51.7 | 86.9 | -35.2 |
| Understanding | 51.8 | 90.0 | -38.2 |
| Helpfulness | 38.8 | 89.4 | **-50.6** |
| Response Craft | 51.5 | 84.7 | -33.2 |
| Persona | 52.9 | 81.0 | -28.1 |
| Safety | 86.2 | 88.9 | -2.7 |

Wins: Claude 39 (38 decisive), Gemini 0, Ties 1.

The delta is not close. This is not a tuning problem — it's a structural problem with how the engineering constrains the model.

---

## Root Cause Analysis

I identified **5 root causes** by cross-referencing every eval case with the actual code in `instruction.py`, `planner.py`, `context_builder.py`, and `agent_loop.py`.

### RC1: The Response Craft Rules Suppress Helpfulness

**Code:** `instruction.py:74-83`
```
For data-backed answers, structure as:
- **Verdict** -- what's the state? (1 line)
- **Evidence** -- the key numbers from the data (1-2 lines)
- **Action** -- one concrete next step; change one lever only

Aim for 3-8 lines. Lists: pick the top 3-4 items, not everything.
```

**What happens:** Gemini produces terse bullet-point responses on queries that need depth. On cur_001 ("How did my last workout go?"), Gemini returned a list of exercises with set counts — 28 words. Claude returned a structured breakdown with tables, highlights, RIR analysis, and actionable next steps — 350 words. The judge scored Gemini 20/100 on helpfulness vs Claude 85/100.

**Evidence from eval:**
- **cur_001** (Gemini 48, Claude 81): "Your last workout included: Seated Row: 6 working sets, Incline Bench Press: 5 working sets..." — a raw data dump with no interpretation
- **cur_004** (Gemini 64, Claude 88): "You are currently undertrained, not overtrained" — correct verdict but dismissive on an emotionally-charged query about feeling tired
- **cur_007** (Gemini 78, Claude 92): Conciseness rules "actively hurt performance on broad analytical queries"
- **cur_011** (Gemini 73, Claude 91): "engineering constraints (conciseness rules, rigid output format) actively constrained a response that needed depth"

**The problem is not that the format is bad** — Verdict/Evidence/Action is good for quick mid-workout checks. The problem is it's the ONLY format. A user asking "How did my last workout go?" at home wants a proper summary, not a gym-speed bullet.

### RC2: The Keyword Planner Is Brittle and Frequently Wrong

**Code:** `planner.py:56-90` — `INTENT_PATTERNS` with simple `any(kw in lower for kw in keywords)` matching

**What happens:** The planner keyword-matches intent to tool suggestions. When it misses, the model either gets no tool guidance or gets the WRONG tools. On amb_008 ("I want to look better"), no keywords match, so the planner returns empty — the model asks a clarification question instead of using the pre-loaded context or fetching data. On cur_006 ("My shoulders feel beat up after pressing"), the planner likely matched "change" or "modify" from the EDIT_PLAN pattern and routed to `get_planning_context` instead of `get_training_analysis` + `query_training_sets`.

**Evidence from eval:**
- **cur_006** (Gemini 43, Claude 89): Planner selected `get_planning_context` instead of analytical tools. Gemini gave a generic "could you tell me which exercise?" while Claude proactively fetched training_snapshot + training_analysis + query_sets and produced a comprehensive shoulder assessment
- **amb_005** (Gemini 64, Claude 89): "Engineered planner selected the wrong tool (get_planning_context instead of get_training_analysis)"
- **amb_006** (Gemini 55, Claude 84): "Tool planner and keyword matching became a liability when the exact exercise had no data"
- **amb_008** (Gemini 36, Claude 87): Planner matched nothing → zero tools called → "How many days per week?" clarification question
- **conv_003** (Gemini 34, Claude 86): "Keyword-based tool planning... routing the model toward wrong tools"

**The planner is net-negative.** When it works (PLAN_ROUTINE, START_WORKOUT), the model would have chosen the right tools anyway. When it fails, it actively prevents the model from reasoning about what tools to use. Claude with zero guidance consistently picked better tools.

### RC3: Clarification-First Behavior on Ambiguous Queries

**Code:** `instruction.py:231-276` — DISCUSS mode triggers on ambiguous queries

```
Triggers: "help me design", "what split should I do", "should I do X or Y",
"I want to start training", unclear goals.

1. get_planning_context to understand current state.
2. Ask up to 2 targeted questions...
```

**What happens:** On ambiguous queries, Gemini asks a clarifying question instead of fetching data and giving a useful answer. Claude's approach is the opposite — fetch data first, give a substantive answer, THEN offer to dig deeper. This is consistently better because the user gets immediate value while still having the option to redirect.

**Evidence from eval:**
- **amb_002** (Gemini 55, Claude 85): "Conciseness constraints and keyword-based planning with no fallback conversational logic produced a dismissive one-liner"
- **amb_004** (Gemini 56, Claude 85): "Prompt rules enforcing clarification-first behavior"
- **amb_008** (Gemini 36, Claude 87): "To help you look better, I need a bit more information. How many days per week can you commit to training?" — vs Claude's 400-word data-driven coaching plan
- **amb_009** (Gemini 44, Claude 75): "Engineered prompt structure forced premature diagnosis and a 'train harder' bias"
- **struct_004** (Gemini 54, Claude 85): "Clarification-first prompt rule actively prevented it from delivering the substantive 6-week plan"

**Claude's pattern is strictly better:** Fetch → Analyze → Respond with value → Offer follow-up. The user always gets something useful, and the offer to go deeper satisfies the same intent as a clarification question.

### RC4: Pre-loaded Context Creates a Satisficing Trap

**Code:** `context_builder.py:33-122` — Loads planning context, memories, summaries, alerts in parallel before the model sees the message

**What happens:** Because the model already has SOME data (training snapshot, alerts, memories), it often decides it has "enough" without fetching more specific data. Claude, starting from zero, is forced to call tools — and this forced thoroughness produces better results. On cur_014, the judge noted: "pre-loaded context and tool planner created a 'satisficing' trap where having partial data readily available prevented the model from fetching comprehensive data."

**Evidence from eval:**
- **cur_014** (Gemini 60, Claude 80): "Pre-loaded context created a 'satisficing' trap — having partial data readily available prevented the model from fetching comprehensive data"
- **cur_009** (Gemini 61, Claude 91): "System A's extensive engineering (733-line prompt, pre-loaded context, 31 tools, keyword planner) was entirely negated by the model's failure to use any of it"
- **conv_003** (Gemini 34, Claude 86): Pre-loaded context contaminated Turn 3 with references to prior conversations — hallucinated "gaps we discussed (rear delts, lateral delts, hamstrings, calves)" that were never in THIS conversation
- **amb_010** (Gemini 58, Claude 86): "Engineering prevented it from leveraging pre-loaded context to answer a philosophical question with personalized data"

**The pre-loaded context itself isn't the problem** — the problem is the model doesn't know when to fetch MORE. And when summaries from other conversations bleed in, it causes hallucinations.

### RC5: Multi-Turn Coherence Collapse

**Category average:** Gemini 44.4, Claude 87.4 — the worst category by far (-43.0 gap)

**What happens:** Gemini treats each turn semi-independently. It fetches `get_planning_context` on turn 1, then on turn 2 when the user says "I don't have a barbell", it calls `save_memory` instead of recognizing this as a constraint on the workout just discussed. On turn 3 when asked to modify templates, it says "I can't directly see the exercises" despite having fetched them in turn 1.

**Evidence from eval:**
- **conv_001** (Gemini 50, Claude 83): "Catastrophically fails on synthesis turns that require reasoning over accumulated conversational context"
- **conv_003** (Gemini 34, Claude 86): Turn 2 → save_memory instead of adapting workout. Turn 3 → "I can't see the exercises" despite fetching them in turn 1
- **conv_005** (Gemini 60, Claude 89): "Keyword-based planner and conciseness constraints catastrophically failed on the ambiguous 'go deeper' turn"
- **conv_007** (Gemini 24, Claude 86): Coherence score 15 vs 90. "Model's failure to reason about user intent, use tool results effectively, or maintain multi-turn coherence"
- **conv_009** (Gemini 40, Claude 89): "Chose to ask generic clarifying questions and give textbook deload definitions instead of synthesizing the available data"

**This is the biggest gap** and the hardest to fix because it's partly a model reasoning issue. But the engineering can help: the conversation history is already loaded (last 20 messages), the model just doesn't USE it well. The instruction has some guidance (lines 52-58) but it's generic.

---

## Improvement Plan: 5 Changes, Prioritized by Impact

### Change 1: Replace Rigid Response Format with Adaptive Depth (Impact: HIGH)

**Target:** `instruction.py` RESPONSE CRAFT section (lines 73-83)

**Current:**
```
For data-backed answers, structure as:
- **Verdict** -- what's the state? (1 line)
- **Evidence** -- the key numbers from the data (1-2 lines)
- **Action** -- one concrete next step; change one lever only

Aim for 3-8 lines. Lists: pick the top 3-4 items, not everything.
```

**Replace with:**
```
Match response depth to the question's scope:

**Quick check** ("Am I ready to train?", "What weight next?"):
Verdict → Evidence → Action. 3-5 lines. One lever.

**Analysis request** ("How did my workout go?", "How's my bench?", "Rate my week"):
Lead with a verdict, then break down the evidence with structure (headers, tables,
bullet points). Include highlights, flags, and a clear next step. 8-20 lines.
Show the user WHY, not just WHAT.

**Broad/complex request** ("Give me a full breakdown", "Compare all my lifts",
"Plan my next mesocycle"):
Full structured response with sections. Use tables for comparisons, callouts
for flags. No length limit — match the depth the user asked for.

Default: if unsure, err toward more detail. Users can skim a thorough answer;
they can't extract insight from a sparse one.

When you build an artifact (propose_workout / propose_routine / update_routine /
update_template), the card IS the answer. Reply with one short confirmation
sentence — don't restate its contents as text.
```

**Why:** This preserves the quick-check format for workout mode while unlocking rich responses for analytical queries. The key insight from Claude's wins: users asking "How did my last workout go?" want interpretation, not enumeration.

**Expected impact on eval dimensions:**
- Helpfulness: +20-30 points (currently 38.8, biggest gap)
- Response Craft: +15-20 points
- Persona: +10-15 points (richer responses naturally feel more "coach-like")

### Change 2: Remove the Keyword Planner (Impact: HIGH)

**Target:** `planner.py` — delete the keyword-based tool planning entirely. In `agent_loop.py` / `main.py`, remove the planner injection.

**Current flow:**
```
User message → keyword match → inject INTERNAL PLAN with suggested tools → LLM
```

**New flow:**
```
User message → LLM decides tools from instruction + context
```

**Why:** The planner is net-negative. Across 40 cases:
- When it matched correctly, the model would have chosen the same tools anyway (the instruction already has detailed guidance for each tool)
- When it matched incorrectly (cur_006, amb_005, amb_008, conv_003), it actively steered the model to wrong tools
- When it didn't match at all, the model sometimes called zero tools when it should have

Claude with zero tool guidance consistently selected better tool combinations than Gemini with the planner. The instruction's USING YOUR TOOLS section (lines 86-139) already provides excellent tool selection guidance — the planner just overrides it with worse heuristics.

**Risk mitigation:** The instruction already says when to use each tool. If we observe tool selection degrading after removal, we can add 2-3 examples of intent→tool reasoning to the EXAMPLES section instead of re-introducing the planner.

**Expected impact on eval dimensions:**
- Correctness: +15-20 points (right tools → right data → right answer)
- Understanding: +10-15 points (model reasons about intent instead of pattern-matching)

### Change 3: Data-First, Clarify-Second (Impact: MEDIUM-HIGH)

**Target:** `instruction.py` — DISCUSS mode section (lines 231-276) and THINK BEFORE YOU RESPOND (lines 61-71)

**Current (DISCUSS mode):**
```
Triggers: "help me design", "what split should I do", "should I do X or Y",
"I want to start training", unclear goals.

1. get_planning_context to understand current state.
2. Ask up to 2 targeted questions...
```

**Add this principle before THINK BEFORE YOU RESPOND:**
```
## DATA-FIRST PRINCIPLE
When the user asks something vague or broad, your first move is to FETCH DATA —
not ask a clarification question. You almost always have enough context (user profile,
training history, active routine) to give a substantive, personalized answer.

Pattern: Fetch → Analyze → Respond with value → Offer to go deeper

Example:
  User: "I want to look better"
  WRONG: "How many days per week can you train?" (clarification-first)
  RIGHT: Fetch training_snapshot + training_analysis → analyze frequency, volume gaps,
  stalled exercises → give concrete assessment of what's working and what to change →
  "Want me to adjust your routine or dig into a specific area?"

Only ask a clarification question when you genuinely cannot give useful guidance
without the answer — e.g., the user says "build me a routine" and you don't know
their available days. Even then, if get_planning_context has their profile with
frequency preference, USE IT instead of asking.
```

**Modify DISCUSS mode:**
```
### DISCUSS mode (collaborative design before building)

Triggers: "help me design", "what split should I do", "should I do X or Y"

1. get_planning_context to understand current state.
2. If you have enough to recommend (frequency in profile, existing routine to adapt):
   Present your recommendation with brief rationale. Offer 1-2 alternatives.
   User picks → enter CREATE or UPDATE mode.
3. Only if critical info is truly missing (no profile data, no frequency preference):
   Ask ONE targeted question, then build on the answer.
```

**Why:** Claude's data-first approach won 39/40 cases. Users get immediate value and can redirect if the answer misses their intent. Clarification questions create dead-end turns that feel like talking to a form.

**Expected impact:**
- Understanding: +15 points (fetching data forces the model to understand context)
- Helpfulness: +15 points (user always gets something actionable)
- Ambiguity category: +15-20 points (currently 58.6 vs 85.6)

### Change 4: Strengthen Multi-Turn Instruction (Impact: MEDIUM)

**Target:** `instruction.py` — CONVERSATION HISTORY section (lines 50-58)

**Current:**
```
You have access to the full conversation history for the current session. Use it
effectively:
- Reference earlier messages when the user says "like I said" or "as we discussed"
- Track context across turns...
```

**Replace with:**
```
## CONVERSATION HISTORY
You have the full conversation history. This is your primary context source —
use it aggressively:

### Cross-turn reasoning
- Tool results from earlier turns are STILL VALID. If you fetched planning_context
  in turn 1 and the user asks about their routine in turn 2, you already have the data.
  Don't re-fetch unless they've made a change since (e.g., you updated a template).
- Track constraints the user has stated: "I don't have a barbell" in turn 2 means
  ALL subsequent exercise recommendations must respect that constraint.
- When the user says "do that", "go deeper", "show me more" — look back to find
  what they're referencing and ACT on it. Don't ask what they mean.

### Avoid contamination
- ONLY reference things discussed in THIS conversation. Never say "as we discussed"
  about topics from the Recent Conversations summary section — those are DIFFERENT
  conversations. If you want to reference something from a prior conversation, say
  "In a previous conversation, we talked about..." — never imply it was this session.

### Progressive depth
- Turn 1: Give a solid answer with data.
- Turn 2+: Build on what you already know. Don't restart from scratch.
  If the user asks to go deeper, add detail to your previous answer — don't repeat it.
```

**Why:** conv_003 showed the model hallucinating cross-conversation references (coherence score 15/100). conv_007 showed complete failure to use prior turn data (coherence 24/100). The current guidance is too generic — it needs explicit rules about data reuse and contamination avoidance.

**Expected impact:**
- Multi-turn category: +15-20 points (currently 44.4 vs 87.4)
- Understanding: +5-10 points

### Change 5: Add "When Pre-loaded Context Isn't Enough" Guidance (Impact: MEDIUM)

**Target:** `instruction.py` — new section after USING YOUR TOOLS

**Add:**
```
## WHEN TO FETCH MORE DATA
Your system context includes a training snapshot, memories, and alerts — but this
is a SUMMARY, not the full picture. Treat it as orientation, not as sufficient data
for a detailed answer.

Rules:
- Snapshot tells you WHAT the user's routine is. To answer HOW it's going, you need
  get_training_analysis or drill-down tools.
- Alerts tell you about flags. To explain WHY a flag exists or what to do, fetch
  the underlying data.
- If the user asks about a specific exercise, muscle, or time period — ALWAYS fetch
  the specific data even if the snapshot mentions it. The snapshot is a pointer, not
  the answer.
- If you have partial data and the user's question deserves more depth, fetch more.
  Don't give a shallow answer because you have shallow data.
```

**Why:** The satisficing trap is the subtlest problem. The model sees data in its context and decides it's enough. This explicit instruction tells it when pre-loaded data is a starting point vs an answer.

**Expected impact:**
- Correctness: +10 points (more thorough data → more accurate answers)
- Curated category: +5-10 points

---

## Implementation Order

| Priority | Change | Files | Complexity |
|----------|--------|-------|------------|
| 1 | Adaptive response depth | `instruction.py` | Low — text change |
| 2 | Remove keyword planner | `planner.py`, `main.py` | Medium — code deletion + wiring |
| 3 | Data-first principle | `instruction.py` | Low — text change |
| 4 | Multi-turn guidance | `instruction.py` | Low — text change |
| 5 | Pre-loaded context guidance | `instruction.py` | Low — text change |

Changes 1, 3, 4, 5 are instruction-only — zero code risk, immediately testable. Change 2 requires removing planner injection from the agent loop.

## Expected Post-Fix Scores (Conservative Estimate)

| Dimension | Current | Target | Rationale |
|-----------|---------|--------|-----------|
| Helpfulness | 38.8 | 70-75 | Adaptive depth + data-first |
| Understanding | 51.8 | 70-75 | Remove planner + data-first |
| Correctness | 51.7 | 70-75 | Remove planner + fetch-more guidance |
| Response Craft | 51.5 | 70-75 | Adaptive depth |
| Persona | 52.9 | 65-70 | Richer responses naturally coach-like |
| Safety | 86.2 | 86+ | No change needed |
| **Overall** | **56.8** | **72-76** | +15-20 points |

This won't match Claude's 87.5 — the remaining gap is model reasoning quality (Gemini 2.5 Flash vs Claude Sonnet 4.6). But it should close the gap from -31 to approximately -12, and eliminate the 0-win embarrassment. The engineering should HELP the model, not constrain it.

## Validation

After implementing, re-run the eval:
```bash
PYTHONPATH=tests/eval EVAL_MCP_API_KEY=... python -m comparative.runner --no-insights
```

Target: Gemini wins ≥ 5 cases, overall ≥ 72, helpfulness ≥ 65, multi-turn ≥ 60.
