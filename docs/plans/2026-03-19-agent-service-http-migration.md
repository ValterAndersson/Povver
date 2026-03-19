# Agent Service HTTP Read Migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the Python agent service's Firestore direct reads to HTTP calls to Firebase Functions, so both internal agents and MCP consumers use the same shared module projections.

**Architecture:** Replace 7 direct Firestore read methods in `firestore_client.py` with HTTP calls to Firebase Function endpoints that now support `view=summary`, `view=compact`, and `include_templates` parameters. Extract a shared HTTP client from the duplicated `httpx.AsyncClient` pattern across 5 skill files. Keep direct Firestore for writes, conversations, and memory (no HTTP endpoints for those).

**Tech Stack:** Python 3.11, httpx (async), Firebase Functions HTTP endpoints

---

## Current State

The agent service has two data access patterns:
1. **Direct Firestore** (`firestore_client.py`) — 16 read methods, each creating its own Firestore query. Two methods (`list_templates`, `list_recent_workouts`) duplicate summarization logic that now exists in the shared JS modules.
2. **HTTP to Firebase Functions** — all writes + `searchExercises` already use HTTP via inline `httpx.AsyncClient` with no connection pooling or shared error handling.

### Problems
- `list_templates()` and `list_recent_workouts()` reimplement summarization that exists in `shared/templates.js` and `shared/workouts.js`
- `get_planning_context()` makes 7 parallel Firestore reads; the HTTP endpoint does the same aggregation server-side with compact view support
- `get_muscle_group_summary()` and `get_muscle_summary()` accept a `weeks` param but ignore it — the HTTP endpoints handle windowing correctly
- `get_analysis_summary()` returns all recommendations including expired; the HTTP endpoint supports `include_expired=false`
- No shared HTTP client — every skill creates/destroys `httpx.AsyncClient` per call with no connection pooling, retry logic, or shared auth

### What stays on direct Firestore (no migration)
- `get_user()` / `get_user_attributes()` — simple single-doc reads, HTTP adds latency for no benefit
- `get_conversation_messages()` / `save_message()` / `save_artifact()` — conversation-specific, no HTTP endpoint
- Memory methods (`MemoryManager`) — separate concern, direct Firestore is fine
- `get_active_snapshot_lite()` / `get_active_events()` — unused, can be cleaned up

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `app/http_client.py` | **Create** | Shared async HTTP client with connection pooling, auth, retries, error mapping |
| `app/firestore_client.py` | **Modify** | Replace 7 read methods with HTTP calls via `http_client.py`. Remove dead methods. Keep Firestore for writes/conversations/memory. |
| `app/skills/coach_skills.py` | **Modify** | Update tool descriptions to reflect richer data (exercise names always present, template names on routines) |
| `app/skills/copilot_skills.py` | **Modify** | Switch from inline httpx to shared `http_client.py` |
| `app/skills/workout_skills.py` | **Modify** | Switch from inline httpx to shared `http_client.py` |
| `app/skills/planner_skills.py` | **Modify** | Switch from inline httpx to shared `http_client.py` |
| `app/skills/progression_skills.py` | **Modify** | Switch from inline httpx to shared `http_client.py` |
| `app/context_builder.py` | **Modify** | Minor — `get_planning_context()` return shape may change slightly with compact view |
| `tests/test_http_client.py` | **Create** | Tests for the shared HTTP client |
| `tests/test_firestore_client_http.py` | **Create** | Tests for migrated read methods |

---

### Task 1: Create shared HTTP client

**Files:**
- Create: `adk_agent/agent_service/app/http_client.py`
- Create: `adk_agent/agent_service/tests/test_http_client.py`

Currently every skill file does:
```python
async with httpx.AsyncClient(timeout=30) as client:
    resp = await client.post(url, headers={"x-api-key": api_key, "x-user-id": user_id}, json=body)
```

This creates and destroys a TCP connection per call. We need a shared client.

- [ ] **Step 1: Write tests for the HTTP client**

```python
# tests/test_http_client.py
import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from app.http_client import FunctionsClient, FunctionsError

@pytest.mark.asyncio
async def test_get_sends_auth_headers():
    """GET requests include x-api-key and x-user-id headers."""
    client = FunctionsClient(base_url="http://test", api_key="key123")
    with patch.object(client, '_client') as mock:
        mock.get = AsyncMock(return_value=MagicMock(status_code=200, json=lambda: {"data": "ok"}))
        result = await client.get("/health", user_id="uid1")
        call_kwargs = mock.get.call_args
        assert call_kwargs.kwargs["headers"]["x-api-key"] == "key123"
        assert call_kwargs.kwargs["headers"]["x-user-id"] == "uid1"

@pytest.mark.asyncio
async def test_post_sends_json_body():
    """POST requests send JSON body with auth headers."""
    client = FunctionsClient(base_url="http://test", api_key="key123")
    with patch.object(client, '_client') as mock:
        mock.post = AsyncMock(return_value=MagicMock(status_code=200, json=lambda: {"data": "ok"}))
        result = await client.post("/endpoint", user_id="uid1", body={"foo": "bar"})
        call_kwargs = mock.post.call_args
        assert call_kwargs.kwargs["json"] == {"foo": "bar"}

@pytest.mark.asyncio
async def test_error_response_raises_functions_error():
    """Non-2xx responses raise FunctionsError with status and message."""
    client = FunctionsClient(base_url="http://test", api_key="key123")
    with patch.object(client, '_client') as mock:
        mock.get = AsyncMock(return_value=MagicMock(
            status_code=404,
            json=lambda: {"error": "Not found"},
            text="Not found"
        ))
        with pytest.raises(FunctionsError) as exc_info:
            await client.get("/missing", user_id="uid1")
        assert exc_info.value.status_code == 404

@pytest.mark.asyncio
async def test_get_without_user_id():
    """Requests without user_id omit x-user-id header."""
    client = FunctionsClient(base_url="http://test", api_key="key123")
    with patch.object(client, '_client') as mock:
        mock.get = AsyncMock(return_value=MagicMock(status_code=200, json=lambda: {"data": "ok"}))
        await client.get("/health")
        call_kwargs = mock.get.call_args
        assert "x-user-id" not in call_kwargs.kwargs["headers"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd adk_agent/agent_service && python -m pytest tests/test_http_client.py -v`
Expected: ImportError — `app.http_client` doesn't exist yet.

- [ ] **Step 3: Implement the shared HTTP client**

```python
# app/http_client.py
"""Shared async HTTP client for Firebase Functions endpoints.

Provides connection pooling, auth headers, and error mapping.
All skill files and firestore_client should use this instead of
creating inline httpx.AsyncClient instances.
"""
import os
import httpx
import logging

logger = logging.getLogger(__name__)

FUNCTIONS_BASE_URL = os.environ.get(
    "MYON_FUNCTIONS_BASE_URL",
    "https://us-central1-myon-53d85.cloudfunctions.net"
)
API_KEY = os.environ.get("MYON_API_KEY", "")


class FunctionsError(Exception):
    """Error from a Firebase Functions HTTP call."""
    def __init__(self, status_code: int, message: str, endpoint: str = ""):
        self.status_code = status_code
        self.endpoint = endpoint
        super().__init__(f"HTTP {status_code} from {endpoint}: {message}")


class FunctionsClient:
    """Async HTTP client for Firebase Functions with connection pooling."""

    def __init__(self, base_url: str = None, api_key: str = None, timeout: float = 30):
        self._base_url = base_url or FUNCTIONS_BASE_URL
        self._api_key = api_key or API_KEY
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            timeout=timeout,
        )

    def _headers(self, user_id: str | None = None) -> dict:
        h = {"x-api-key": self._api_key}
        if user_id:
            h["x-user-id"] = user_id
        return h

    async def get(self, path: str, user_id: str = None, params: dict = None) -> dict:
        resp = await self._client.get(path, headers=self._headers(user_id), params=params or {})
        return self._handle_response(resp, path)

    async def post(self, path: str, user_id: str = None, body: dict = None) -> dict:
        resp = await self._client.post(path, headers=self._headers(user_id), json=body or {})
        return self._handle_response(resp, path)

    def _handle_response(self, resp: httpx.Response, path: str) -> dict:
        if resp.status_code >= 400:
            try:
                detail = resp.json().get("error", resp.text)
            except Exception:
                detail = resp.text
            raise FunctionsError(resp.status_code, str(detail), path)
        data = resp.json()
        # Firebase Functions wrap responses in {data: ...} via ok()
        return data.get("data", data)

    async def close(self):
        await self._client.aclose()


# Module-level singleton
_client: FunctionsClient | None = None


def get_functions_client() -> FunctionsClient:
    """Get or create the shared FunctionsClient singleton."""
    global _client
    if _client is None:
        _client = FunctionsClient()
    return _client
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd adk_agent/agent_service && python -m pytest tests/test_http_client.py -v`
Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/http_client.py tests/test_http_client.py
git commit -m "feat(agent): add shared HTTP client for Firebase Functions"
```

---

### Task 2: Migrate `get_planning_context()` to HTTP

**Files:**
- Modify: `adk_agent/agent_service/app/firestore_client.py`
- Create: `adk_agent/agent_service/tests/test_firestore_client_http.py`

This is the highest-impact migration. Currently makes 7 parallel Firestore reads and assembles the result in Python. The HTTP endpoint does the same thing server-side with `view=compact` support.

- [ ] **Step 1: Write test for the HTTP-based get_planning_context**

```python
# tests/test_firestore_client_http.py
import pytest
from unittest.mock import AsyncMock, patch
from app.firestore_client import FirestoreClient

@pytest.mark.asyncio
async def test_get_planning_context_calls_http():
    """get_planning_context uses HTTP endpoint with view=compact."""
    fs = FirestoreClient.__new__(FirestoreClient)
    mock_http = AsyncMock()
    mock_http.post = AsyncMock(return_value={
        "user": {"name": "Test"},
        "activeRoutine": {"name": "PPL"},
        "templates": [],
        "recentWorkouts": [],
        "strengthSummary": [],
    })
    fs._http = mock_http

    result = await fs.get_planning_context("uid1")

    mock_http.post.assert_called_once()
    call_args = mock_http.post.call_args
    assert call_args.kwargs.get("user_id") == "uid1" or call_args.args[0] == "/getPlanningContext"
    assert "user" in result
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd adk_agent/agent_service && python -m pytest tests/test_firestore_client_http.py -v`
Expected: FAIL — `get_planning_context` still uses direct Firestore.

- [ ] **Step 3: Add HTTP client to FirestoreClient and migrate get_planning_context**

In `firestore_client.py`, add to `__init__`:
```python
from app.http_client import get_functions_client
self._http = get_functions_client()
```

Replace the existing `get_planning_context` method (which does 7 parallel Firestore reads) with:
```python
async def get_planning_context(self, user_id: str) -> dict:
    """Get planning context via HTTP endpoint with compact view."""
    return await self._http.post(
        "/getPlanningContext",
        user_id=user_id,
        body={"view": "compact", "workoutLimit": 10},
    )
```

- [ ] **Step 4: Verify context_builder.py compatibility**

Read `app/context_builder.py` and check that `_format_snapshot()` handles both the old dict shape and the new compact shape. The compact view uses slightly different keys (`activeRoutine` vs `active_routine`, `recentWorkouts` vs `recent_workouts`). Add key normalization if needed:

```python
# In context_builder.py _format_snapshot(), handle both shapes:
routine = snapshot.get("activeRoutine") or snapshot.get("active_routine")
```

- [ ] **Step 5: Run tests**

Run: `cd adk_agent/agent_service && python -m pytest tests/ -v`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/firestore_client.py app/context_builder.py tests/test_firestore_client_http.py
git commit -m "feat(agent): migrate get_planning_context to HTTP with compact view"
```

---

### Task 3: Migrate list/query read methods to HTTP

**Files:**
- Modify: `adk_agent/agent_service/app/firestore_client.py`
- Modify: `adk_agent/agent_service/tests/test_firestore_client_http.py`

Migrate 6 read methods that have corresponding HTTP endpoints with projection support:

| Python Method | HTTP Endpoint | Parameters |
|---|---|---|
| `list_templates(user_id, include_exercises)` | `GET /getUserTemplates` | `?view=summary` or no param |
| `list_recent_workouts(user_id, limit)` | `GET /getUserWorkouts` | `?view=summary&limit=N` |
| `get_muscle_group_summary(user_id, group, weeks)` | `GET /getMuscleGroupSummary` | `?muscle_group=X&weeks=N` |
| `get_exercise_summary(user_id, exercise_id)` | `GET /getExerciseSummary` | `?exercise_name=X&weeks=8` |
| `get_analysis_summary(user_id)` | `GET /getAnalysisSummary` | `?include_expired=false` |
| `get_weekly_review(user_id)` | `GET /getAnalysisSummary` | `?sections=weekly_review` |
| `query_sets(user_id, exercise_id, filters)` | `POST /querySets` | body with target + limit |

- [ ] **Step 1: Write tests for each migrated method**

Add to `tests/test_firestore_client_http.py`:

```python
@pytest.mark.asyncio
async def test_list_templates_calls_http_with_summary():
    """list_templates uses HTTP with view=summary by default."""
    fs = FirestoreClient.__new__(FirestoreClient)
    mock_http = AsyncMock()
    mock_http.get = AsyncMock(return_value={"items": [{"id": "t1", "name": "Push"}]})
    fs._http = mock_http

    result = await fs.list_templates("uid1")
    mock_http.get.assert_called_once()
    call_kwargs = mock_http.get.call_args.kwargs
    assert call_kwargs.get("params", {}).get("view") == "summary"

@pytest.mark.asyncio
async def test_list_templates_full_with_exercises():
    """list_templates(include_exercises=True) omits view=summary."""
    fs = FirestoreClient.__new__(FirestoreClient)
    mock_http = AsyncMock()
    mock_http.get = AsyncMock(return_value={"items": [{"id": "t1", "exercises": []}]})
    fs._http = mock_http

    result = await fs.list_templates("uid1", include_exercises=True)
    call_kwargs = mock_http.get.call_args.kwargs
    assert call_kwargs.get("params", {}).get("view") is None

@pytest.mark.asyncio
async def test_list_recent_workouts_calls_http_summary():
    """list_recent_workouts uses HTTP with view=summary."""
    fs = FirestoreClient.__new__(FirestoreClient)
    mock_http = AsyncMock()
    mock_http.get = AsyncMock(return_value={"items": [], "hasMore": False})
    fs._http = mock_http

    result = await fs.list_recent_workouts("uid1", limit=5)
    call_kwargs = mock_http.get.call_args.kwargs
    assert call_kwargs["params"]["view"] == "summary"
    assert call_kwargs["params"]["limit"] == "5"

@pytest.mark.asyncio
async def test_get_analysis_summary_filters_expired():
    """get_analysis_summary passes include_expired=false."""
    fs = FirestoreClient.__new__(FirestoreClient)
    mock_http = AsyncMock()
    mock_http.get = AsyncMock(return_value={"insights": []})
    fs._http = mock_http

    result = await fs.get_analysis_summary("uid1")
    call_kwargs = mock_http.get.call_args.kwargs
    assert call_kwargs["params"]["include_expired"] == "false"

@pytest.mark.asyncio
async def test_get_muscle_group_summary_passes_weeks():
    """get_muscle_group_summary passes weeks parameter."""
    fs = FirestoreClient.__new__(FirestoreClient)
    mock_http = AsyncMock()
    mock_http.get = AsyncMock(return_value={"muscle_group": "chest", "points": []})
    fs._http = mock_http

    result = await fs.get_muscle_group_summary("uid1", "chest", weeks=12)
    call_kwargs = mock_http.get.call_args.kwargs
    assert call_kwargs["params"]["weeks"] == "12"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd adk_agent/agent_service && python -m pytest tests/test_firestore_client_http.py -v`
Expected: FAIL — methods still use direct Firestore.

- [ ] **Step 3: Replace read methods with HTTP calls**

In `firestore_client.py`, replace each method:

```python
async def list_templates(self, user_id: str, include_exercises: bool = False) -> list[dict]:
    params = {} if include_exercises else {"view": "summary"}
    result = await self._http.get("/getUserTemplates", user_id=user_id, params=params)
    return result.get("items", result) if isinstance(result, dict) else result

async def list_recent_workouts(self, user_id: str, limit: int = 5) -> list[dict]:
    result = await self._http.get(
        "/getUserWorkouts", user_id=user_id,
        params={"view": "summary", "limit": str(limit)},
    )
    return result.get("items", [])

async def get_analysis_summary(self, user_id: str) -> dict | None:
    result = await self._http.get(
        "/getAnalysisSummary", user_id=user_id,
        params={"include_expired": "false"},
    )
    return result

async def get_weekly_review(self, user_id: str) -> dict | None:
    result = await self._http.get(
        "/getAnalysisSummary", user_id=user_id,
        params={"sections": "weekly_review"},
    )
    return result.get("weekly_review")

async def get_muscle_group_summary(self, user_id: str, muscle_group: str, weeks: int = 8) -> dict | None:
    return await self._http.get(
        "/getMuscleGroupSummary", user_id=user_id,
        params={"muscle_group": muscle_group, "weeks": str(weeks)},
    )

async def get_exercise_summary(self, user_id: str, exercise_name: str, weeks: int = 8) -> dict | None:
    return await self._http.get(
        "/getExerciseSummary", user_id=user_id,
        params={"exercise_name": exercise_name, "weeks": str(weeks)},
    )

async def query_sets(self, user_id: str, target: dict, limit: int = 50) -> list[dict]:
    result = await self._http.post(
        "/querySets", user_id=user_id,
        body={"target": target, "limit": limit},
    )
    return result.get("sets", [])
```

- [ ] **Step 4: Delete the old Firestore query code for migrated methods**

Remove the direct Firestore implementations of all 7 methods listed above. Keep the `db` property and direct Firestore for: `get_user`, `get_user_attributes`, `get_conversation_messages`, `save_message`, `save_artifact`, `get_weekly_stats`.

- [ ] **Step 5: Delete unused methods**

Remove dead code:
- `get_routine()` — not called by any tool
- `get_template()` — not called by any tool
- `get_muscle_summary()` — not called by any tool
- `get_active_snapshot_lite()` — not called by any tool
- `get_active_events()` — not called by any tool

- [ ] **Step 6: Run all tests**

Run: `cd adk_agent/agent_service && python -m pytest tests/ -v`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/firestore_client.py tests/test_firestore_client_http.py
git commit -m "feat(agent): migrate 7 read methods from Firestore to HTTP with projections"
```

---

### Task 4: Migrate skill files to shared HTTP client

**Files:**
- Modify: `adk_agent/agent_service/app/skills/copilot_skills.py`
- Modify: `adk_agent/agent_service/app/skills/workout_skills.py`
- Modify: `adk_agent/agent_service/app/skills/planner_skills.py`
- Modify: `adk_agent/agent_service/app/skills/progression_skills.py`

Each of these files creates inline `httpx.AsyncClient` instances. Replace with the shared `FunctionsClient`.

- [ ] **Step 1: Migrate copilot_skills.py**

Replace all `async with httpx.AsyncClient(...) as client:` blocks with calls to the shared client:

```python
from app.http_client import get_functions_client

# Before (in each tool function):
async with httpx.AsyncClient(timeout=30) as client:
    resp = await client.post(f"{base_url}/logSet", headers={...}, json=body)
    data = resp.json()

# After:
http = get_functions_client()
data = await http.post("/logSet", user_id=user_id, body=body)
```

Remove `import httpx` and the `MYON_FUNCTIONS_BASE_URL` / `MYON_API_KEY` env var reads from the file (now handled by `http_client.py`).

- [ ] **Step 2: Migrate workout_skills.py**

Same pattern — replace all 8 inline httpx usages with shared client calls.

- [ ] **Step 3: Migrate planner_skills.py**

Replace `update_routine` and `update_template` HTTP calls. Keep `fs.save_artifact()` as-is (direct Firestore).

- [ ] **Step 4: Migrate progression_skills.py**

Replace `apply_progression` HTTP call.

- [ ] **Step 5: Run all tests**

Run: `cd adk_agent/agent_service && make test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/skills/copilot_skills.py app/skills/workout_skills.py app/skills/planner_skills.py app/skills/progression_skills.py
git commit -m "refactor(agent): migrate skill files to shared HTTP client"
```

---

### Task 5: Update tool descriptions for richer data

**Files:**
- Modify: `adk_agent/agent_service/app/skills/coach_skills.py`

Now that the shared modules return exercise names on templates and template names on routines, the LLM tool descriptions should reflect this so the agent knows it doesn't need follow-up lookups.

- [ ] **Step 1: Update get_planning_context description**

```python
# Before:
"Get the user's training context including profile, active routine, templates, recent workouts, and analysis."

# After:
"Get compact training snapshot: user profile, active routine with template names and exercise names, recent workouts (exercise names + set counts), strength records. One call gives full orientation — no follow-up needed."
```

- [ ] **Step 2: Update get_training_analysis description**

```python
# Before:
"Get training analysis insights and weekly review."

# After:
"Get training analysis: active insights (plateaus, volume issues, periodization alerts) and latest weekly review. Only shows pending recommendations by default."
```

- [ ] **Step 3: Update get_muscle_group_progress description**

```python
# Before:
"Get muscle group training progress over time."

# After:
"Get muscle group progress over N weeks: weekly volume, set counts, exercise breakdown, trend direction. The weeks parameter controls the time window."
```

- [ ] **Step 4: Update get_exercise_progress description**

Note: the `exercise_id` parameter should be renamed to `exercise_name` since the HTTP endpoint uses fuzzy name matching, not exact ID lookup.

```python
# Before:
"Get exercise progress over time." (with exercise_id param)

# After:
"Get exercise progress over N weeks: weekly e1RM trend, PR, plateau detection, last session details. Use exercise name (fuzzy match), not ID." (with exercise_name param)
```

- [ ] **Step 5: Run tests**

Run: `cd adk_agent/agent_service && make test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/skills/coach_skills.py
git commit -m "docs(agent): update tool descriptions for projection-enriched responses"
```

---

### Task 6: Handle response shape compatibility in context_builder

**Files:**
- Modify: `adk_agent/agent_service/app/context_builder.py`
- Modify: `adk_agent/agent_service/tests/test_firestore_client_http.py`

The compact view from the HTTP endpoint uses camelCase keys (`activeRoutine`, `recentWorkouts`, `strengthSummary`). The old direct Firestore path used snake_case keys built by the Python code. The context builder's `_format_snapshot()` needs to handle the new shape.

- [ ] **Step 1: Write test for context builder with compact view shape**

```python
# Add to tests/test_firestore_client_http.py
from app.context_builder import _format_snapshot

def test_format_snapshot_handles_compact_view_keys():
    """_format_snapshot works with camelCase keys from compact HTTP view."""
    snapshot = {
        "user": {"name": "Test", "fitness_level": "intermediate", "fitness_goal": "strength"},
        "activeRoutine": {"name": "PPL", "template_ids": ["t1"]},
        "templates": [{"name": "Push", "exerciseNames": ["Bench Press"]}],
        "recentWorkouts": [{"exercises": [{"name": "Bench", "working_sets": 4}]}],
        "strengthSummary": [{"name": "Bench Press", "e1rm": 100}],
    }
    result = _format_snapshot(snapshot)
    assert "Test" in result
    assert "PPL" in result
```

- [ ] **Step 2: Update _format_snapshot to handle both key formats**

In `context_builder.py`, use `.get()` with fallbacks:

```python
routine = snapshot.get("activeRoutine") or snapshot.get("active_routine")
workouts = snapshot.get("recentWorkouts") or snapshot.get("recent_workouts", [])
strength = snapshot.get("strengthSummary") or snapshot.get("strength_summary", [])
```

- [ ] **Step 3: Run tests**

Run: `cd adk_agent/agent_service && make test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add app/context_builder.py tests/test_firestore_client_http.py
git commit -m "fix(agent): handle camelCase keys from compact HTTP planning context"
```

---

### Task 7: Cleanup and documentation

**Files:**
- Modify: `adk_agent/agent_service/app/firestore_client.py` — final cleanup
- Modify: `docs/SHELL_AGENT_ARCHITECTURE.md` — update data access section

- [ ] **Step 1: Remove stale imports from firestore_client.py**

After removing direct Firestore read methods, check for unused imports (`asyncio.gather`, Firestore query types, etc.) and remove them.

- [ ] **Step 2: Update SHELL_AGENT_ARCHITECTURE.md**

Add a "Data Access Patterns" section documenting:
- Reads: via HTTP to Firebase Functions (with projection parameters)
- Writes: mixed — HTTP for domain mutations, direct Firestore for conversations/artifacts/memory
- Shared HTTP client: `app/http_client.py` with connection pooling

- [ ] **Step 3: Run full test suite and lint**

Run: `cd adk_agent/agent_service && make check`
Expected: All tests pass, lint clean.

- [ ] **Step 4: Commit**

```bash
git add app/firestore_client.py docs/SHELL_AGENT_ARCHITECTURE.md
git commit -m "chore(agent): cleanup stale Firestore imports, update architecture docs"
```

---

## HTTP Endpoint Reference

For the implementer — these are the Firebase Functions HTTP endpoints with their new projection parameters:

| Endpoint | Method | Projection Params | Notes |
|----------|--------|-------------------|-------|
| `/getPlanningContext` | POST | `body.view: "compact"`, `body.workoutLimit: N` | Returns compact snapshot with exercise names |
| `/getUserWorkouts` | GET | `?view=summary&limit=N` | Returns exercise name + set count, no per-set data |
| `/getUserTemplates` | GET | `?view=summary` | Returns name + exercise count + exercise names |
| `/getRoutine` | GET | `?routineId=X&include_templates=true` | Returns inline template summaries |
| `/getAnalysisSummary` | GET | `?include_expired=false&sections=insights,weekly_review` | Filters expired recommendations |
| `/getMuscleGroupSummary` | GET | `?muscle_group=X&weeks=N` | Windowed muscle group data |
| `/getExerciseSummary` | GET | `?exercise_name=X&weeks=N` | Fuzzy name match, windowed |
| `/querySets` | POST | `body.target: {exercise_name, muscle_group, ...}` | Explicit target fields |
| `/searchExercises` | GET | `?query=X&limit=N&fields=lean` | Already used via HTTP |

Auth: all endpoints use `x-api-key` header (server-to-server lane) + `x-user-id` header.

---

## Expected Outcomes

| Metric | Before | After |
|--------|--------|-------|
| Summarization implementations | 3 (JS shared, MCP tools.ts, Python firestore_client) | 1 (JS shared modules only) |
| `get_planning_context` Firestore reads | 7 parallel | 0 (1 HTTP call) |
| `list_templates` Python summarization code | ~20 lines in firestore_client.py | 0 (delegated to shared module) |
| `list_recent_workouts` Python summarization code | ~25 lines in firestore_client.py | 0 (delegated to shared module) |
| Inline httpx clients across skill files | ~15 instances across 4 files | 0 (shared FunctionsClient) |
| Dead methods in firestore_client.py | 5 unused methods | 0 (deleted) |
| `weeks` parameter actually working | No (ignored) | Yes (passed to HTTP endpoint) |
| `include_expired` filtering | No | Yes (default false) |

## Risks

1. **Latency increase:** Direct Firestore reads are ~20-50ms. HTTP via Cloud Functions adds ~50-200ms (including cold start risk). Mitigated by: Cloud Functions are always warm (frequent traffic), and `get_planning_context` replaces 7 parallel reads with 1 HTTP call (net latency may decrease).

2. **Auth header compatibility:** The HTTP endpoints use `x-api-key` + `x-user-id` for server-to-server auth. Verify the middleware accepts this pattern for all endpoints (some may only support bearer token auth). Check `requireFlexibleAuth` middleware.

3. **Response shape drift:** The HTTP endpoints return `{data: ...}` wrapped responses. The `FunctionsClient._handle_response` unwraps this, but edge cases (errors, empty responses) need testing.
