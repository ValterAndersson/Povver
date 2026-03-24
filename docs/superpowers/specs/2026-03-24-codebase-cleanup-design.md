# Codebase Cleanup Spec

> Goal: Remove all verified dead code, deprecated services, and unused files across every layer. Update documentation to reflect the current stateless architecture. Result: a slimmer, properly documented codebase ready for production.

> Branch: `cleanup/dead-code-removal` (all changes committed independently for auditability)

---

## Audit Methodology

Four parallel subagents audited every layer (Firebase Functions, iOS, Agent System, Scripts/Misc). A second verification pass traced every deletion target end-to-end — from iOS call sites through Firebase Functions to agent tools — catching 6 items the initial audit incorrectly marked as dead. A third adversarial review caught 3 critical issues (dependency ordering, missing fallback paths, data migration risk) that have been incorporated into this final spec. Only items verified safe through all three passes are included below.

---

## Phase 1: Security & Hygiene (2 commits)

### Commit 1: Remove tracked secrets and data files

| File | Action | Reason |
|------|--------|--------|
| `.mcp.json` | `git rm --cached`, add to `.gitignore` | Contains hardcoded bearer token |
| `strong_workouts.csv` | `git rm --cached`, add `*.csv` to `.gitignore` | 392KB personal workout data |

**Post-commit**: Rotate the MCP bearer token (the old one is in git history).

### Commit 2: Prevent accidental commits of untracked assets

| Entry | Action |
|-------|--------|
| `landing/assets/Povver_images/` | Add to `.gitignore` |

---

## Phase 2: Agent System Cleanup (3 commits)

### Commit 3: Delete `canvas_orchestrator/` entirely

**Verified safe**: Zero runtime imports from any active service. All references are comments/docstrings noting migration provenance.

Files removed: ~50+ source files, ~40+ eval result files, archived multi-agent code, Dockerfile, Makefile, venv artifacts.

### Commit 4: Delete dead modules in `agent_service/`

| File | Reason | Delete with |
|------|--------|-------------|
| `app/critic.py` | Migrated from canvas_orchestrator, never wired into agent loop | `tests/test_critic.py` |
| `app/planner.py` | Migrated from canvas_orchestrator, never wired (distinct from active `skills/planner_skills.py`) | `tests/test_planner.py` |
| `app/safety_gate.py` | Migrated from canvas_orchestrator, never wired | `tests/test_safety_gate.py` |

### Commit 5: Clean up stale root requirements and dead function

| Item | Action |
|------|--------|
| `adk_agent/requirements.txt` | Delete — orphaned root-level file, each service has its own |
| `shared/usage_tracker.py` :: `accumulate_usage_from_chunk()` | Remove function only (self-documented as unused) |

**Checkpoint**: `cd adk_agent/agent_service && make check`

---

## Phase 3: Firebase Functions Cleanup (4 commits)

### Commit 6: Delete dead files with zero references

| File | Verification |
|------|-------------|
| `training/series-endpoints.js` | Not exported in index.js, not imported by any file |
| `analytics/get-features.js` | Not exported, not imported |
| `maintenance/audit-shorthand-exercises.js` | Not exported, not imported |

### Commit 7: Delete canvas files that have zero importers

**IMPORTANT**: Only delete canvas files that are NOT imported by `apply-action.js`. The files `validators.js`, `reducer-utils.js`, and `schemas/` are imported by `apply-action.js` and must stay until commit 12b.

| File | Verification |
|------|-------------|
| `canvas/propose-cards.js` | No iOS callers, no agent callers, not imported by apply-action.js |
| `canvas/propose-cards-core.js` | Only imported by propose-cards.js |
| `canvas/expire-proposals.js` | No callers; proposals no longer created |
| `canvas/expire-proposals-scheduled.js` | Not imported anywhere |
| `canvas/emit-event.js` | No callers outside index.js, not imported by apply-action.js |
| `scripts/seed_canvas.js` | Seeds deprecated canvas system |

**NOT deleting yet** (imported by `apply-action.js`, deferred to commit 12b):
- `canvas/validators.js` — imported at `apply-action.js` line 87
- `canvas/reducer-utils.js` — verify if imported by apply-action.js; if so, defer
- `canvas/schemas/` — used by validators.js

Remove corresponding exports (`proposeCards`, `expireProposals`, `emitEvent`) from `index.js`.

### Commit 8: Delete deprecated CRUD endpoints + dead analytics endpoint

| File | Verification |
|------|-------------|
| `routines/create-routine.js` | No iOS callers, no agent callers. Replaced by `create-routine-from-draft.js`. |
| `templates/update-template.js` | No iOS callers (dead method on `CloudFunctionService` — `.updateTemplate()` has zero call sites). Agent uses `patchTemplate`. |
| `analytics/publish-weekly-job.js` | Exported in index.js but zero active callers (no iOS, no agent, no script calls it). Uses deprecated `canvasId`. Delete entire file rather than partially removing parameters. |

Remove exports (`createRoutine`, `updateTemplate`, `publishWeeklyJob`) from `index.js`.

**NOT deleting**: `routines/update-routine.js` — agent service actively calls `/updateRoutine` via `planner_skills.py`.

### Commit 9: Delete canvas-only test files and clean index.js

| Test File | Tests For |
|-----------|-----------|
| `tests/canvas.validators.test.js` | canvas/validators.js |
| `tests/e2e.canvas.flow.test.js` | Canvas flow |
| `tests/e2e.http.canvas-smoke.test.js` | Canvas HTTP |
| `tests/e2e.http.demo.test.js` | Canvas demo |
| `tests/reducer.invariants.test.js` | Canvas reducer |
| `tests/reducer.phase.test.js` | Canvas reducer |
| `tests/reducer.props.test.js` | Canvas reducer |
| `tests/reducer.undo.test.js` | Canvas reducer |
| `tests/reducer.utils.test.js` | Canvas reducer utils |

Also: Remove the unused `const { getAuthenticatedUserId } = require('./utils/auth-helpers');` import from `index.js`.

**Checkpoint**: `cd firebase_functions/functions && npm test`

**Note**: At this point `apply-action.js`, `purge-canvas.js`, `validators.js`, `reducer-utils.js`, and `schemas/` still exist and are exported. The npm test checkpoint verifies the codebase is consistent before proceeding to Phase 4.

---

## Phase 4: iOS Cleanup + Final Canvas Deletion (5 commits)

### Commit 10: Remove `canvasId` backward-compat from Firebase Functions

| Location | Change |
|----------|--------|
| `stream-agent-normalized.js` | Remove `\|\| req.body?.canvasId` fallback |
| `templates/create-template-from-plan.js` | Remove `canvasId` parameter acceptance |
| `shared/templates.js` | Remove canvasId references |

**DEFERRED** (data migration required first):
- `templateIds` camelCase fallbacks in `shared/routines.js`, `shared/planning-context.js`, `shared/artifacts.js`, `utils/validators.js`, `training/process-workout-completion.js` — existing Firestore documents may still have `templateIds` (camelCase). Removing fallbacks without a data backfill would make old routines unreadable. Deferred to a future task after running a `templateIds` -> `template_ids` migration script.

### Commit 11: Delete verified dead Swift files (9 files)

| File | Verification |
|------|-------------|
| `Config/StrengthOSConfig.swift` | Zero references. Deprecated Vertex AI Agent Engine config. |
| `Services/Errors.swift` | `StrengthOSError` type not referenced by any other file. |
| `Services/PendingAgentInvoke.swift` | Zero call sites. Deprecated session queueing. |
| `Services/CacheManager.swift` | Zero references. Unimplemented stubs. |
| `UI/Canvas/ConversationGridView.swift` | Never instantiated in app code. |
| `UI/Canvas/UpNextRailView.swift` | Never instantiated. |
| `UI/Canvas/PinnedRailView.swift` | Never instantiated. |
| `UI/Canvas/WorkoutRailView.swift` | Never instantiated. |
| `UI/Components/TrendDelta.swift` | Never used. |

Also: Remove dead `updateTemplate()` method + protocol declaration from `CloudFunctionService.swift` (lines 19, 76-79). Zero call sites verified.

**NOT deleting** (verified active):
- `Models/FocusModeModels.swift` — 266 references across 27 files
- `Models/TrainingIntelligence.swift` — 55 references across 7 files
- `Repositories/BaseRepository.swift` — base class for active `ExerciseRepository`

None of these files are in `project.pbxproj` build sources — they use folder-based membership. Deleting from disk is sufficient.

### Commit 12a: Migrate legacy canvas actions to artifact path in iOS

Migrate ALL action kinds in `ConversationScreen.swift` that call `vm.applyAction`. Every call site must be accounted for:

| Action Kind | Current (legacy) | Migration | Line(s) |
|-------------|-------------------|-----------|---------|
| `apply` | `applyAction("ACCEPT_PROPOSAL")` | Route through `AgentsApi.artifactAction("accept")` if artifactId exists, else update card status locally | ~259 |
| `dismiss` | `applyAction("REJECT_PROPOSAL")` | Route through `AgentsApi.artifactAction("dismiss")` if artifactId exists, else remove card from `vm.cards` | ~264 |
| `accept_all` | `applyAction("ACCEPT_ALL")` | Remove case entirely — `shared/artifacts.js` never sets `groupId`, so no new cards have group proposals | ~269 |
| `reject_all` | `applyAction("REJECT_ALL")` | Remove case entirely — same reason | ~274 |
| `accept_plan`/`start` fallback | `else if` → `applyAction("ACCEPT_PROPOSAL")` | Remove the `else if` legacy fallback — for cards without `artifactId`, do nothing (artifact path is primary) | ~306-307 |
| `save_routine` fallback | `else if` → `applyAction("SAVE_ROUTINE")` | Remove the `else if` legacy fallback — artifact path handles this | ~434-435 |
| `dismiss_draft` fallback | `else if` → `applyAction("DISMISS_DRAFT")` | Remove the `else if` legacy fallback — for cards without `artifactId`, remove card from `vm.cards` locally | ~451-452 |
| `pin_draft` | `applyAction("PIN_DRAFT")` | Remove case entirely — new artifact system doesn't use pinning | ~456-457 |

**Firestore-sourced cards**: Cards loaded via `ConversationMapper.mapCard()` from Firestore do NOT have `artifactId` in their meta. For these cards, the `dismiss`/`apply` handlers must handle the no-artifactId case gracefully (local state mutation only — remove from `vm.cards` or update status). This is safe because Firestore-sourced cards are rendered from the `cards` subcollection which is now deprecated; new artifacts come via SSE and always have `artifactId`.

Then delete iOS canvas infrastructure:
- `ConversationActions.swift` — zero call sites (dead factory)
- `ConversationViewModel.applyAction()` method — all call sites migrated above
- `ConversationService.swift` — delete the entire file. Both methods (`applyAction` and `purgeConversation`) are now dead. `purgeConversation` had zero call sites before this cleanup.
- Delete `ConversationServiceProtocol` — after removing both methods, the protocol is empty. `ConversationViewModel` line 115 injects `service: ConversationServiceProtocol` — remove this property and the `init` parameter since nothing uses it after `applyAction` is gone.
- All canvas-related DTOs from `ConversationDTOs.swift`: `ApplyActionRequestDTO`, `ApplyActionResponseDTO`, `CanvasActionDTO`, `CanvasPhase`, `CanvasStateDTO`, `UpNextEntryDTO`, `ChangedCardDTO`, `ConversationSnapshot`, `ActionErrorDTO`

**Checkpoint**: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

### Commit 12b: Delete remaining Firebase canvas infrastructure

After iOS no longer calls `applyAction` or `purgeCanvas`, delete the entire `canvas/` directory and its dependencies:
- `canvas/apply-action.js`
- `canvas/purge-canvas.js`
- `canvas/validators.js` (imported by apply-action.js — safe now that apply-action.js is also deleted)
- `canvas/reducer-utils.js`
- `canvas/schemas/` (16 JSON files)
- `canvas/ARCHITECTURE.md`
- `shared/active_workout/` (4 files: `log_set_core.js`, `swap_core.js`, `adjust_load_core.js`, `reorder_sets_core.js`) — verified: only imported by `canvas/apply-action.js`, NOT by `active_workout/*.js` endpoints (which use `utils/active-workout-helpers.js` instead)
- `routines/create-routine-from-draft.js` — only imported by `canvas/apply-action.js`
- Remove `ajv` from `package.json` (only used by `canvas/validators.js`)
- Remove all remaining canvas exports (`applyAction`, `purgeCanvas`) from `index.js`

**Checkpoint**: `cd firebase_functions/functions && npm test`

### Commit 13: Rename `canvasId` to `conversationId` across iOS

Files to update (~10+ files). Use Xcode's Rename refactoring per symbol to catch all call sites, especially parent views that instantiate `ConversationScreen`.

| File | Changes |
|------|---------|
| `ConversationViewModel.swift` | `@Published var canvasId` -> `conversationId`, method params |
| `ConversationScreen.swift` | `let canvasId: String?` view parameter -> `conversationId`. This propagates to all parent views that instantiate `ConversationScreen`. |
| `ConversationRepository.swift` | `currentCanvasId` -> `currentConversationId`, `subscribe(canvasId:)` -> `subscribe(conversationId:)`, log strings, comments |
| `AgentPipelineLogger.swift` | Method parameter `canvasId:` -> `conversationId:` |
| `DebugLogger.swift` | Skip set entries |
| `OnboardingViewModel.swift` | Local variable |
| `CoachTabView.swift` | Closure parameter + `ConversationScreen` instantiation |
| `DirectStreamingService.swift` | Already sends `conversationId` — update comments only |
| Parent views of `ConversationScreen` | Any view that passes `canvasId:` when constructing `ConversationScreen` |

**Wire format note**: `DirectStreamingService` already sends `"conversationId"` over the wire. `AgentsApi.artifactAction()` already sends `"conversationId"`. After commit 12a removes the `applyAction` code path, there is no wire format concern — the rename is purely internal Swift naming.

### Commit 14: Rename `CanvasCardModel` to `ArtifactCardModel` (~28 files)

Pure internal Swift type rename. No wire format impact — this type is never serialized to JSON for API calls, never appears in string literals, UserDefaults keys, or analytics events. It's the in-memory model for rendering cards. Compiler will catch all misses.

Affects: `Models.swift` (definition), `ConversationMapper`, `ConversationRepository`, `ConversationViewModel`, `ConversationScreen`, `WorkspaceTimelineView`, all card components (`SessionPlanCard`, `VisualCard`, `RoutineSummaryCard`, `AnalysisSummaryCard`, `AgentMessageCard`, etc.), `CardActionEnvironment`.

**Checkpoint**: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

---

## Phase 5: Scripts & Root Cleanup (2 commits)

### Commit 15: Delete deprecated scripts

| File | Reason |
|------|--------|
| `scripts/curl_invoke_agent.sh` | Calls deprecated `invokeCanvasOrchestrator` |
| `scripts/curl_propose_cards.sh` | Calls deprecated `proposeCards` with `canvasId` |
| `scripts/migrate_existing_users_to_premium.js` | One-time migration, completed |

### Commit 16: Document root package.json

Add a comment header to root `package.json` explaining it provides `firebase-admin` for the `scripts/` directory. Or move to `scripts/package.json` with corresponding `scripts/node_modules/` in `.gitignore`.

---

## Phase 6: Documentation (2 commits)

### Commit 17: Update tier 1 architecture docs

| Doc | Changes |
|-----|---------|
| `docs/SYSTEM_ARCHITECTURE.md` | Remove stale Vertex AI Agent Engine references. Update deprecated tables to reflect completed removals. Remove canvas sections. |
| `docs/SECURITY.md` | Remove Vertex AI Agent Engine reference in token exchange section. Remove `openCanvas`/`preWarmSession` from maxInstances table. |
| `docs/FIRESTORE_SCHEMA.md` | Remove canvas collections. Update stale references. |
| `docs/SHELL_AGENT_ARCHITECTURE.md` | Remove canvas_orchestrator legacy sections. |
| `docs/platformvision.md` | Delete (deprecated, superseded by current docs). |

### Commit 18: Update CLAUDE.md and supporting docs

| Doc | Changes |
|-----|---------|
| `CLAUDE.md` | Add `catalog_orchestrator` and `admin/catalog_dashboard` to build commands. Update deprecated table — mark removed items as "REMOVED" or delete entries. |
| `docs/README.md` | Add `MCP_SERVER_ARCHITECTURE.md` entry. |
| `scripts/ARCHITECTURE.md` | Add undocumented scripts: `set_subscription_override.js`, `reset_stuck_job.js`, `query_llm_usage.js`, `backfill_exercise_usage_stats.js`, `backfill_routine_template_names.js`, `backfill_template_exercise_names.js`. |
| Various `ARCHITECTURE.md` files | Remove stale canvas_orchestrator cross-references. |

---

## What Stays (Future Cleanup Candidates)

| Item | Why It Stays | Future Action |
|------|-------------|---------------|
| `routines/update-routine.js` | Agent calls `/updateRoutine` | Migrate agent to `patchRoutine` |
| `templateIds` camelCase fallbacks | Existing Firestore docs may use old field name | Run backfill script to migrate all docs to `template_ids`, then remove fallbacks |
| Eval result files in `agent_service/tests/eval/` | Not dead code, but git bloat | Consider `.gitignore` or archive |

---

## Risk Matrix

| Phase | Commit | Risk | Mitigation |
|-------|--------|------|------------|
| 1 | 1-2 | None | Git operations only |
| 2 | 3-5 | None | Zero runtime imports verified |
| 3 | 6-9 | None | Zero references verified. Canvas files with dependencies on apply-action.js kept until 12b. |
| 3 | 10 | Low | canvasId compat removal only. templateIds deferred. |
| 4 | 11 | None | All files verified zero-reference |
| 4 | 12a | **Medium** | Functional migration — all 8 `vm.applyAction` call sites explicitly mapped. Xcode build checkpoint immediately after. Local fallbacks for cards without artifactId. |
| 4 | 12b | Low | Firebase deletions orphaned by 12a — entire canvas/ dir deleted atomically. npm test checkpoint. |
| 4 | 13 | Low | Internal rename via Xcode refactoring. Propagates to parent views. Build will catch misses. |
| 4 | 14 | Low | Internal rename across 28 files, compiler catches all misses |
| 5 | 15-16 | None | Scripts and docs |
| 6 | 17-18 | None | Documentation only |

---

## Intermediate State Safety

At no point between commits should a deploy of any layer break functionality:

- **After commit 7**: `apply-action.js` still works because `validators.js`, `reducer-utils.js`, and `schemas/` are kept. All remaining canvas exports are intact.
- **After commits 8-9**: Deleted endpoints had zero callers. Remaining canvas endpoints still functional.
- **After commit 10**: `canvasId` fallback removed from stream-agent-normalized, but iOS already sends `conversationId`.
- **After commit 12a**: iOS no longer calls `applyAction`/`purgeCanvas`. These endpoints are still deployed but have no callers.
- **After commit 12b**: Canvas endpoints removed from Firebase. iOS already migrated away. Clean state.

---

## Estimated Scope

- ~18 commits
- ~130+ files deleted
- ~40+ files modified (renames, import cleanup, doc updates)
- 5 checkpoints (agent make check, firebase npm test x2, xcode build x2)
