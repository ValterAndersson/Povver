# Shared Business Logic Architecture

> Pure business logic for core domain operations.
> Every function takes `(db, userId, ...)` — no req/res. Handlers are thin HTTP wrappers.

---

## Module Inventory

**Core domain entities:**
- `templates.js` — Template CRUD, denormalized exercise names (resolved at write time)
- `routines.js` — Routine CRUD, denormalized template_names (resolved at write time)
- `workouts.js` — Workout CRUD, summary views, analytics computation
- `exercises.js` — Exercise catalog queries (global collection, not user-scoped)

**Agent-facing context:**
- `planning-context.js` — Assemble user profile + active routine + recent workouts + strength summary
- `training-queries.js` — Query set_facts, series, insights, weekly reviews (training analytics)

**Utility modules:**
- `artifacts.js` — Artifact action handlers (save_routine, save_template, start_workout)
- `progressions.js` — Progression scheme lookups and calculations
- `errors.js` — Shared error types (ValidationError, NotFoundError, PermissionDeniedError, etc.)
- `active_workout/` — Active workout state machine (not currently used in iOS)

---

## View Parameter Pattern

Several list/read functions support a `view` parameter for compact projections:

### `listWorkouts(db, userId, opts)`
- **Default (no view):** Full workout documents (~5-10KB each with exercises, sets, analytics)
- **`view: "summary"`:** ~200-500 bytes per workout (exercise names + set counts, no per-set data)

### `listTemplates(db, userId, opts)`
- **Default (no view):** Full template documents (exercises, sets, analytics)
- **`view: "summary"`:** Name, description, exercise_count, exercise_names array (~300 bytes)

### `getPlanningContext(db, userId, opts)`
- **Default (no view):** Full context with user profile, active routine, templates, 20 workouts
- **`view: "compact"`:** ~2KB total (user basics, routine summary, 10 workouts with exercise names only)

### `getRoutine(db, userId, routineId, opts)`
- **No view param** — uses `include_templates: true/false` instead
- **`include_templates: false`:** Routine metadata only
- **`include_templates: true`:** Inlines template summaries (name, exercise_names, exercise_count)

---

## Denormalization Policy

### Why Denormalize?
Agent tools (MCP server) and client list views need entity names without additional reads. Template and routine list endpoints previously required O(N × M) reads (N routines × M templates, or N templates × M exercises). Denormalizing reduces this to O(1).

### What's Denormalized?

#### Exercise names on template exercises
- **Written:** `createTemplate`, `patchTemplate` (batch-resolve from exercises catalog)
- **Storage:** `exercises[].name` field on template documents
- **Staleness:** Exercise names are effectively immutable in production (edits are rare, handled manually)
- **Backfill:** `scripts/backfill_exercise_names.js` (not yet implemented — all current data has names)

#### Template names on routine documents
- **Written:** `createRoutine`, `patchRoutine` (fetched during template_ids validation)
- **Storage:** `template_names` map on routine documents (`{ template_id: name }`)
- **Staleness:** Propagated on rename via `patchTemplate` (scans routines, updates map)
- **Backfill:** `scripts/backfill_template_names.js` (not yet implemented — field added March 2026)

### Staleness Tradeoffs
- **Exercise names:** No propagation on edit (manual catalog updates are rare, agents regenerate plans)
- **Template names:** Active propagation on rename (O(N) routine updates, acceptable given low rename frequency)

### Future Considerations
If template renames become frequent, consider moving to query-time resolution with a short-lived cache. Current approach optimizes for read-heavy workload (agent planning context called on every conversation turn).

---

## Consumer Mapping

### iOS App
- **Consumption:** Full views (default, no `view` param)
- **Why:** UI displays all fields (per-set data, analytics, full metadata)

### MCP Server (`mcp_server/src/tools.ts`)
- **Consumption:** Summary/compact views (`view: "summary"`, `view: "compact"`)
- **Why:** Token budget limits (Claude context window), agent orientation phase needs overview not detail
- **Examples:**
  - `list_workouts` → `view: "summary"`
  - `list_templates` → `view: "summary"`
  - `get_training_snapshot` → `view: "compact"` (via planning-context)

### Agent Service (`adk_agent/agent_service`)
- **Consumption:** Full views via direct Firestore reads (bypasses Firebase Functions)
- **Future:** Migrate to HTTP calls with summary views to reduce token usage in context assembly
- **Benefits:** Denormalization already helps (template names in routines, exercise names in templates)

### Pipeline Consumers
- **Training Analyst (`adk_agent/training_analyst`):** Full workout documents (unbounded set_facts queries)
- **Backfill Scripts (`scripts/backfill_*.js`):** Full documents (no view projections)
- **Triggers (`triggers/*.js`):** Full documents from Firestore event snapshots

---

## Error Handling Convention

All shared functions throw typed errors from `shared/errors.js`:
- `ValidationError` → 400
- `NotFoundError` → 404
- `PermissionDeniedError` → 403
- `AuthenticationError` → 401
- `ConflictError` → 409
- `PremiumRequiredError` → 402

HTTP handlers in `templates/*.js`, `routines/*.js`, etc. catch these and map to response.fail(statusCode, message).

---

## Testing

Each module has a corresponding test file in `tests/`:
- `tests/shared-templates.test.js`
- `tests/shared-routines.test.js`
- `tests/shared-workouts.test.js`
- `tests/shared-planning-context.test.js`

Tests use in-memory Firestore emulator (no mocks). Run via `npm test`.

---

## Cross-References

- **Firestore schema:** `docs/FIRESTORE_SCHEMA.md`
- **Function conventions:** `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
- **MCP server usage:** `mcp_server/README.md`
- **Agent service usage:** `docs/SHELL_AGENT_ARCHITECTURE.md`
