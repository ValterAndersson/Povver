# Povver Documentation

> Documentation for the Povver agent-driven training platform.

---

## Start Here

| Document | Purpose |
|----------|---------|
| **`SYSTEM_ARCHITECTURE.md`** | Cross-cutting data flows, schema contracts, common patterns, deprecated code warnings, and checklists for adding features across the stack. |
| **`SECURITY.md`** | Security invariants, auth lanes (Bearer/Service/Callable), IDOR prevention, subscription protection. Authoritative source for authentication. |

---

## Architecture Documentation

| Document | Purpose |
|----------|---------|
| **`IOS_ARCHITECTURE.md`** | iOS app: MVVM structure, services, repositories, canvas components, design system. |
| **`FIREBASE_FUNCTIONS_ARCHITECTURE.md`** | Firebase Functions: all HTTP endpoints, triggers, scheduled jobs. Per-endpoint auth lane annotations. |
| **`FIRESTORE_SCHEMA.md`** | Firestore data model with field-level specifications, triggers, and automatic mutations. |
| **`SHELL_AGENT_ARCHITECTURE.md`** | Shell Agent: 4-lane routing, skills modules, ContextVar state management. |
| **`CATALOG_ORCHESTRATOR_ARCHITECTURE.md`** | Catalog enrichment pipeline: LLM review agent, job system, apply gate. |
| **`THINKING_STREAM_ARCHITECTURE.md`** | Agent thinking streams: `_display` metadata flow from Python agents to iOS UI. |
| **`FOCUS_MODE_WORKOUT_EXECUTION.md`** | Workout execution: data lifecycle, backend endpoints, iOS architecture, copilot integration. |
| **`TRAINING_ANALYTICS_API_V2_SPEC.md`** | Training analytics v2: set facts, paginated queries, series update strategy. |

## Reference Documentation

| Document | Purpose |
|----------|---------|
| **`ANALYTICS.md`** | GA4 event taxonomy (53 events, 9 domains), server-side structured logging, LLM usage tracking. |
| **`LOGGING.md`** | iOS session logging system for debugging agent interactions. |
| **`ALIAS_POLICY.md`** | Exercise alias resolution policy for catalog admin. |

## Deprecated

| Document | Superseded By |
|----------|---------------|
| `platformvision.md` | `SYSTEM_ARCHITECTURE.md`, `IOS_ARCHITECTURE.md`, `SHELL_AGENT_ARCHITECTURE.md` |
