# MCP Server Architecture

> **Document Purpose**: Complete documentation of the MCP (Model Context Protocol) server layer. Written for LLM/agentic coding agents.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Authentication](#authentication)
4. [Tools](#tools)
5. [Shared Modules](#shared-modules)
6. [Deployment](#deployment)
7. [Client Configuration](#client-configuration)
8. [Security](#security)

---

## Overview

The MCP server is an HTTP service that exposes Povver training data and operations to external LLM applications (Claude Desktop, ChatGPT, etc.) via the Model Context Protocol standard.

**Purpose**: Enable premium users to connect their preferred AI assistant to their Povver training data for personalized workout planning, progress analysis, and training recommendations.

**Runtime**: Node.js 20 + TypeScript
**Framework**: `@modelcontextprotocol/sdk` v1.0.0
**Transport**: Streamable HTTP (SSE-compatible)
**Deployment**: Google Cloud Run (us-central1)

---

## Architecture

### Request Flow

```
External LLM Client (Claude Desktop, ChatGPT)
  ↓ HTTP POST with Bearer token (MCP API key)
MCP Server (Cloud Run)
  ↓ SHA-256 hash lookup in `mcp_api_keys`
  ↓ Premium validation via `users/{userId}`
  ↓ Per-request MCP server instance
  ↓ Tool calls → Shared business logic (from Firebase Functions)
  ↓ Firestore read/write
```

### Transport

The server uses **StreamableHTTPServerTransport** from the MCP SDK, which supports:

- Server-Sent Events (SSE) for streaming responses
- JSON-RPC 2.0 protocol over HTTP
- Stateless per-request authentication

Each incoming HTTP request:
1. Extracts API key from `Authorization: Bearer <key>` header
2. Authenticates and validates premium status
3. Creates a new `McpServer` instance scoped to that user
4. Registers tools with userId bound to closures
5. Delegates to `StreamableHTTPServerTransport.handleRequest()`

### File Structure

```
mcp_server/
├── src/
│   ├── index.ts        # HTTP server, auth middleware, health endpoint
│   ├── auth.ts         # API key authentication + premium validation
│   └── tools.ts        # MCP tool registration (all 15 tools)
├── Dockerfile          # Cloud Run container
├── Makefile            # build, deploy, dev, test
├── package.json        # Dependencies (@modelcontextprotocol/sdk, firebase-admin)
└── tsconfig.json       # TypeScript config
```

---

## Authentication

### API Key Flow

1. **Client** includes `Authorization: Bearer <mcp_api_key>` in request
2. **Server** computes `SHA-256(api_key)` → keyHash
3. **Firestore lookup**: `mcp_api_keys/{keyHash}`
4. **Premium validation**: Read `users/{user_id}` and check:
   - `subscription_override === 'premium'` OR
   - `subscription_tier === 'premium'`
5. **Update timestamp**: Set `last_used_at` to server timestamp
6. **Bind userId**: All tool calls scoped to authenticated user

**Implementation**: `src/auth.ts` → `authenticateApiKey(apiKey): Promise<AuthResult>`

**Error codes**:
- `401` - Invalid API key or user not found
- `403` - Valid key but user is not premium

### Premium Gate

MCP access is **premium-only**. The server mirrors the `isPremiumUser()` logic from `firebase_functions/functions/utils/auth-helpers.js` to ensure consistency with the rest of the platform.

Non-premium users who attempt to connect receive:
```json
{
  "error": "Premium subscription required for MCP access"
}
```

---

## Tools

All tools are registered in `src/tools.ts` via `registerTools(server, userId)`. Each tool delegates to shared business logic modules imported from `firebase_functions/functions/shared/`.

### Read Tools

| Tool | Description | Parameters | Module |
|------|-------------|------------|--------|
| `get_training_snapshot` | Get complete training context (planning context) | None | `planning-context.js` |
| `list_routines` | List all user routines | None | `routines.js` |
| `get_routine` | Get specific routine by ID | `routine_id` | `routines.js` |
| `list_templates` | List all workout templates | None | `templates.js` |
| `get_template` | Get specific template by ID | `template_id` | `templates.js` |
| `list_workouts` | List recent completed workouts | `limit` (default 20) | `workouts.js` |
| `get_workout` | Get specific workout by ID | `workout_id` | `workouts.js` |
| `search_exercises` | Search exercise catalog | `query`, `limit` | `exercises.js` |
| `get_training_analysis` | Get training insights/analysis | `sections` (optional) | `training-queries.js` |
| `get_muscle_group_progress` | Get muscle group progress over time | `group`, `weeks` (default 8) | `training-queries.js` |
| `get_exercise_progress` | Get exercise progress over time | `exercise`, `weeks` (default 8) | `training-queries.js` |
| `query_sets` | Query raw set-level training data | `target`, `limit` (default 50) | `training-queries.js` |
| `list_memories` | List agent memories about user | None | Direct Firestore query |

### Write Tools

| Tool | Description | Parameters | Module |
|------|-------------|------------|--------|
| `create_routine` | Create new routine | `name`, `template_ids`, `frequency?` | `routines.js` |
| `update_routine` | Update existing routine | `routine_id`, `updates` | `routines.js` |
| `create_template` | Create new workout template | `name`, `exercises` | `templates.js` |
| `update_template` | Update existing template | `template_id`, `updates` | `templates.js` |

**Note**: Workout creation and active workout operations are deliberately excluded to maintain the iOS app as the canonical workout logging interface.

---

## Shared Modules

The MCP server imports business logic directly from the Firebase Functions layer to ensure behavioral consistency across all API surfaces.

### Import Mechanism

During deployment (`make deploy`):
1. TypeScript compiles `src/` → `dist/`
2. Makefile copies `firebase_functions/functions/shared/` → `mcp_server/shared/`
3. Dockerfile packages both `dist/` and `shared/` into the container
4. Runtime requires: `require('../shared/routines')`, etc.

**Path resolution**: Tools run from `dist/index.js`, so shared modules are at `../shared/` relative to dist.

### Shared Modules Used

| Module | Exports | Used For |
|--------|---------|----------|
| `routines.js` | `listRoutines`, `getRoutine`, `createRoutine`, `patchRoutine` | Routine CRUD |
| `templates.js` | `listTemplates`, `getTemplate`, `createTemplate`, `patchTemplate` | Template CRUD |
| `workouts.js` | `listWorkouts`, `getWorkout` | Workout read operations |
| `exercises.js` | `searchExercises` | Exercise catalog search |
| `training-queries.js` | `getAnalysisSummary`, `getMuscleGroupSummary`, `getExerciseSummary`, `querySets` | Training analytics |
| `planning-context.js` | `getPlanningContext` | Complete training snapshot |

All shared modules accept `db` (Firestore instance) and `userId` as parameters and return promises.

---

## Deployment

### Cloud Run Configuration

**Service**: `mcp-server`
**Region**: `us-central1`
**Service Account**: `ai-agents@myon-53d85.iam.gserviceaccount.com`
**Resources**: 256Mi memory, 1 CPU
**Scaling**: 0 min / 5 max instances
**Timeout**: 60 seconds
**Auth**: `--allow-unauthenticated` (auth via API key, not IAM)

### Deploy Command

```bash
cd mcp_server
make deploy
```

**What happens**:
1. `npm run build` → TypeScript compilation
2. Copy `firebase_functions/functions/shared/` to `shared/`
3. `gcloud run deploy` with source-based deployment
4. Cloud Run builds container from Dockerfile
5. Cleanup: `rm -rf shared/`

**Environment**:
- `GOOGLE_CLOUD_PROJECT=myon-53d85` (set via `--set-env-vars`)
- `PORT=8080` (default, overridden by Cloud Run)
- Firebase Admin SDK auto-configures from service account

### Health Endpoint

```
GET /health
→ 200 { "status": "ok" }
```

Used for Cloud Run health checks and uptime monitoring.

---

## Client Configuration

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "povver": {
      "url": "https://mcp-server-<hash>-uc.a.run.app",
      "headers": {
        "Authorization": "Bearer <user_mcp_api_key>"
      }
    }
  }
}
```

### ChatGPT (via MCP Bridge)

Configure in ChatGPT settings → Integrations → MCP Servers:

```
URL: https://mcp-server-<hash>-uc.a.run.app
Auth: Bearer <user_mcp_api_key>
```

### Obtaining API Keys

Users generate MCP API keys via the Povver iOS app:
1. Settings → Developer → MCP API Keys
2. Tap "Create New Key"
3. Firebase Function `createMcpApiKey` generates:
   - Random 32-byte API key (hex-encoded)
   - SHA-256 hash stored in `mcp_api_keys/{hash}`
   - Key document fields: `user_id`, `name`, `created_at`, `last_used_at`
4. Key displayed once (never stored plaintext)

**Security**: Only the hash is stored in Firestore. Keys cannot be retrieved after initial display.

---

## Security

### Premium-Only Access

- Only users with `subscription_tier === 'premium'` or `subscription_override === 'premium'` can use MCP
- Premium status validated on every request (not cached)
- If subscription expires, all MCP requests fail with 403

### API Key Hashing

- Keys generated via `crypto.randomBytes(32).toString('hex')`
- Only SHA-256 hash stored in Firestore (`mcp_api_keys/{keyHash}`)
- Keys are bearer tokens — treat like passwords (HTTPS only)

### No Direct Firestore Writes from Clients

- MCP server does not expose raw Firestore write operations
- All write tools delegate to shared business logic that enforces:
  - Ownership validation (`userId` scoped)
  - Schema validation
  - Transactional consistency
  - Proper timestamps (via `serverTimestamp()`)

### Rate Limiting

- Cloud Run autoscaling limits concurrent requests
- Max 5 instances × concurrent requests per instance
- Consider adding per-user rate limiting if abuse occurs

### Firestore Security Rules

MCP server uses Firebase Admin SDK, which **bypasses Firestore security rules**. This is intentional — the server itself is the security boundary (via API key auth + premium validation).

**Implication**: Any Firestore write path accessible via MCP tools must enforce ownership validation in application code (all shared modules already do this via `userId` parameter).

### Audit Trail

- `last_used_at` timestamp updated on every successful auth
- Consider adding Cloud Logging for tool invocations if audit requirements increase

---

## Future Enhancements

Potential additions (not currently implemented):

1. **Per-user rate limiting** — Track requests per API key, throttle if excessive
2. **Tool usage analytics** — Log which tools are used most frequently
3. **Scoped keys** — Allow users to create read-only vs read-write keys
4. **Key expiration** — Optional TTL on API keys
5. **Webhook notifications** — Alert users when their MCP key is used from a new IP
6. **Extended write operations** — Add workout logging tools if external-AI-created workouts become a use case

---

## Cross-References

- **System Architecture**: `docs/SYSTEM_ARCHITECTURE.md`
- **Security Model**: `docs/SECURITY.md` → "Authentication Model"
- **Firebase Functions**: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` → "Shared Modules"
- **Firestore Schema**: `docs/FIRESTORE_SCHEMA.md` → `mcp_api_keys` collection
