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
**Framework**: `@modelcontextprotocol/sdk` ^1.27.1, Express 5
**Transport**: Streamable HTTP (SSE-compatible)
**Deployment**: Google Cloud Run (us-central1)
**Custom Domain**: `https://mcp.povver.ai`

---

## Architecture

### Request Flow

```
External LLM Client (Claude Desktop, ChatGPT, Cursor)
  ↓ HTTP POST/GET to https://mcp.povver.ai/ with Bearer token
MCP Server (Express 5 on Cloud Run)
  ↓ requireBearerAuth middleware (MCP SDK)
  ↓ Token prefix routing:
  │   pvt_ → OAuth token → Firestore mcp_tokens/{hash}
  │   pvk_ → API key → Firestore mcp_api_keys/{hash}
  │   none → legacy API key → same as pvk_
  ↓ Premium validation via users/{userId}
  ↓ Per-request McpServer instance + StreamableHTTPServerTransport
  ↓ Tool calls → Shared business logic (from Firebase Functions)
  ↓ Firestore read/write
  ↓ Transport + server closed after each request
```

### Transport

The server uses **StreamableHTTPServerTransport** from the MCP SDK, which supports:

- Server-Sent Events (SSE) for streaming responses
- JSON-RPC 2.0 protocol over HTTP
- Stateless per-request authentication

Each incoming HTTP request:
1. SDK `requireBearerAuth` extracts Bearer token
2. `PovverOAuthProvider.verifyAccessToken()` routes by prefix and validates premium
3. Creates a new `McpServer` instance scoped to that user
4. Registers tools with userId bound to closures
5. Delegates to `StreamableHTTPServerTransport.handleRequest()`
6. Transport and server closed in `finally` block to prevent resource leaks

### File Structure

```
mcp_server/
├── src/
│   ├── index.ts           # Express app, routes, MCP endpoint at /
│   ├── auth.ts            # API key authentication + premium validation
│   ├── oauth-provider.ts  # OAuthServerProvider — authorize, token exchange, verify
│   ├── tokens.ts          # OAuth token/code/nonce generation, hashing, Firestore CRUD
│   ├── clients-store.ts   # Dynamic client registration with redirect URI validation
│   ├── consent.ts         # HTML consent page with Firebase Auth JS SDK
│   └── tools.ts           # MCP tool registration (all 15 tools)
├── Dockerfile             # Cloud Run container
├── Makefile               # build, deploy, dev, test
├── package.json           # Dependencies (@modelcontextprotocol/sdk, express, firebase-admin)
└── tsconfig.json          # TypeScript config
```

---

## Authentication

The server supports two authentication paths, routed by token prefix:

### OAuth 2.1 Flow (Claude Desktop — `pvt_` prefix)

Claude Desktop uses OAuth 2.1 with PKCE (S256) for public clients. The full flow:

1. **Discovery**: Client fetches `/.well-known/oauth-authorization-server` for endpoints
2. **Registration**: Client `POST /register` with its redirect URI (dynamic localhost port). In-memory store validates URI against allowlist (localhost, 127.0.0.1, claude.ai)
3. **Authorization**: Client opens browser to `/authorize` → consent page served
4. **Sign-in**: User signs in via Firebase Auth JS SDK (Apple/Google/Email) on consent page
5. **Consent**: User clicks "Allow access" → `POST /authorize/complete` with Firebase ID token + nonce
6. **Code exchange**: Server validates nonce (single-use, transactional), verifies Firebase ID token, generates auth code, redirects to client callback
7. **Token exchange**: Client `POST /token` with auth code + PKCE verifier → server returns `pvt_`-prefixed access + refresh tokens
8. **MCP requests**: Client sends Bearer token with each request to `/`

**Token storage**: Only SHA-256 hashes stored in Firestore `mcp_tokens/{hash}`. Raw tokens never persisted.

**Token rotation**: Refresh tokens are rotated on each use. Old token marked with `grace_until` (30s) rather than deleted immediately. Retries with an already-rotated token are rejected to prevent token multiplication.

**Implementation**: `src/oauth-provider.ts`, `src/tokens.ts`, `src/clients-store.ts`, `src/consent.ts`

### API Key Flow (Cursor, scripts — `pvk_` or no prefix)

1. **Client** includes `Authorization: Bearer <mcp_api_key>` in request
2. **Server** computes `SHA-256(api_key)` → keyHash
3. **Firestore lookup**: `mcp_api_keys/{keyHash}`
4. **Premium validation**: Read `users/{user_id}` and check subscription status
5. **Update timestamp**: Set `last_used_at` to server timestamp
6. **Bind userId**: All tool calls scoped to authenticated user

**Implementation**: `src/auth.ts` → `authenticateApiKey(apiKey): Promise<AuthResult>`

### Premium Gate

MCP access is **premium-only** for both auth paths. The server mirrors the `isPremiumUser()` logic from `firebase_functions/functions/utils/auth-helpers.js`:
- `subscription_override === 'premium'` OR
- `subscription_tier === 'premium'`

### OAuth Firestore Collections

| Collection | Purpose | Security Rules |
|------------|---------|----------------|
| `mcp_tokens/{hash}` | Access + refresh token records | Deny-all (Admin SDK only) |
| `mcp_oauth_codes/{hash}` | Single-use auth codes | Deny-all (Admin SDK only) |
| `mcp_oauth_nonces/{nonce}` | CSRF nonces for consent flow | Deny-all (Admin SDK only) |

All read-then-write operations use `runTransaction` to prevent race conditions.

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
| `list_workouts` | List recent completed workouts | `limit` (default 10, max 100) | `workouts.js` |
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

**Environment** (all set via Makefile `--set-env-vars`):
- `GOOGLE_CLOUD_PROJECT=myon-53d85`
- `MCP_ISSUER_URL=https://mcp.povver.ai` — OAuth discovery issuer
- `FIREBASE_API_KEY` — Used by consent page Firebase Auth JS SDK
- `PORT=8080` (default, overridden by Cloud Run)
- Firebase Admin SDK auto-configures from service account

**Custom Domain**: `mcp.povver.ai` → Cloud Run domain mapping with managed SSL. DNS: CNAME to `ghs.googlehosted.com` (Route 53).

**Important**: The Makefile uses `--set-env-vars` which replaces ALL env vars. Every env var must be included in the deploy command.

### Health Endpoint

```
GET /health
→ 200 { "status": "ok" }
```

Used for Cloud Run health checks and uptime monitoring.

---

## Client Configuration

### Claude Desktop (OAuth — recommended)

1. Open Claude Desktop → Settings → Connectors → Add custom connector
2. Enter URL: `https://mcp.povver.ai`
3. Claude Desktop initiates OAuth — opens browser to consent page
4. User signs in with Apple/Google/Email (same account as Povver app)
5. Click "Allow access" → Claude Desktop receives tokens automatically
6. Done — Claude can access training data via MCP tools

No manual config file editing required. Claude Desktop handles OAuth registration, authorization, and token management automatically.

### Cursor / Other Clients (API Key)

Add to MCP client config:

```json
{
  "mcpServers": {
    "povver": {
      "url": "https://mcp.povver.ai",
      "headers": {
        "Authorization": "Bearer <user_mcp_api_key>"
      }
    }
  }
}
```

### Obtaining API Keys

Users generate MCP API keys via the Povver iOS app:
1. Settings → Connected Apps → MCP API Keys
2. Tap "Create New Key"
3. Firebase Function `createMcpApiKey` generates:
   - Random 32-byte key with `pvk_` prefix (hex-encoded)
   - SHA-256 hash stored in `mcp_api_keys/{hash}`
   - Key document fields: `user_id`, `name`, `created_at`, `last_used_at`
4. Key displayed once (never stored plaintext)

### iOS Connection Status

The Povver iOS app shows connection status in Settings → Connected Apps → Claude Desktop section (`ClaudeConnectionSection.swift`). Users can:
- See if Claude Desktop is connected (checks for non-expired tokens)
- Copy the MCP URL
- Disconnect (revokes all OAuth tokens)

---

## Security

### Premium-Only Access

- Only users with `subscription_tier === 'premium'` or `subscription_override === 'premium'` can use MCP
- Premium status validated on every request (not cached)
- If subscription expires, all MCP requests fail with 403

### Token Security

- OAuth tokens prefixed `pvt_`, API keys prefixed `pvk_` — enables prefix-based auth routing
- Only SHA-256 hashes stored in Firestore — raw tokens/keys never persisted
- All tokens are bearer tokens — HTTPS only (enforced by Cloud Run)
- OAuth access tokens expire after 1 hour, refresh tokens after 90 days
- Debounced `last_used_at` updates (5 min per Cloud Run instance) to reduce Firestore writes

### Security Headers

Express middleware adds on all responses:
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`

### Rate Limiting

- Custom OAuth endpoints (`/authorize/complete`, `/authorize/deny`): 10 req/min/IP via `express-rate-limit`
- SDK OAuth endpoints (`/authorize`, `/token`, `/register`): SDK-managed rate limiting
- Cloud Run autoscaling: max 5 instances

### Input Validation

- `id_token` length capped at 4096 bytes (prevents DoS before Firebase Auth verification)
- `nonce` length capped at 64 characters
- Dynamic client registration validates redirect URIs against allowlist (localhost, 127.0.0.1, claude.ai)

### CSRF Protection

- Server-generated nonces stored in Firestore (`mcp_oauth_nonces`)
- Consumed atomically via `runTransaction` — single-use, prevents replay
- 10-minute TTL

### Cleanup

- `cleanupMcpTokens` scheduled function runs daily, deletes expired documents from all 3 OAuth collections (paginated at 500)
- Account deletion (`delete-account.js`) purges `mcp_tokens`, `mcp_oauth_codes`, and `mcp_api_keys`
- Token revocation available via `revokeMcpTokens` Firebase Function and iOS disconnect button

### Firestore Security Rules

- OAuth collections (`mcp_tokens`, `mcp_oauth_codes`, `mcp_oauth_nonces`) have deny-all rules — Admin SDK only
- MCP server uses Admin SDK which bypasses rules — the server itself is the security boundary

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
- **Firestore Schema**: `docs/FIRESTORE_SCHEMA.md` → `mcp_api_keys`, `mcp_tokens`, `mcp_oauth_codes`, `mcp_oauth_nonces`
- **OAuth Design Spec**: `docs/superpowers/specs/2026-03-22-mcp-oauth-claude-desktop-design.md`
- **iOS Views**: `ClaudeConnectionSection.swift`, `ClaudeConnectionViewModel.swift`
