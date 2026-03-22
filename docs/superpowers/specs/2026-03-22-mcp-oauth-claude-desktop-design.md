# MCP OAuth 2.1 for Claude Desktop

> Add OAuth 2.1 authorization to the existing MCP server so Claude Desktop users can connect with one click. Branded consent page, custom domain, and iOS settings UI for connection management.

## Context

The MCP server (`mcp_server/`) is deployed on Cloud Run with 15 tools (training data, routines, templates, exercises, memories). It currently authenticates via API keys (Bearer token → Firestore `mcp_api_keys` lookup → premium gate). This works for Claude Code and Cursor but not for Claude Desktop, which requires OAuth 2.1 for remote MCP servers.

## Goals

1. Claude Desktop users connect by entering `https://mcp.povver.ai` — no API key needed
2. Branded consent page consistent with povver.ai landing page
3. iOS settings UI showing connection status with disconnect/upgrade flows
4. Existing API key auth remains unchanged for Claude Code, Cursor, etc.

## Non-Goals

- ChatGPT GPT Actions (separate effort, different protocol)
- New MCP tools or changes to existing tool behavior
- Changes to premium gating logic

---

## Architecture

### Approach

Single service — OAuth 2.1 support added to the existing MCP Cloud Run service using the **MCP SDK's built-in OAuth framework** (`@modelcontextprotocol/sdk` v1.27.1). The SDK provides `OAuthServerProvider` interface + `mcpAuthRouter()` which handles endpoint routing, URL-encoded body parsing, PKCE validation, and rate limiting out of the box.

### Server Migration: `http.createServer()` → Express

The current server uses raw `http.createServer()`. The SDK's `mcpAuthRouter()` requires Express (`express.Router()`). The server must be migrated to Express. The SDK also provides `createMcpExpressApp()` as a helper. This is a one-time migration that simplifies routing for both OAuth and MCP endpoints.

### Why single service

The OAuth layer is tightly coupled to the MCP server's auth, and shares the same Firestore instance. A separate service adds deployment complexity with no architectural benefit at current scale.

---

## OAuth 2.1 Implementation

### SDK Integration

Instead of rolling custom OAuth endpoints, implement the `OAuthServerProvider` interface from the SDK:

```typescript
interface OAuthServerProvider {
  // Look up registered client by client_id
  clientsStore: OAuthRegisteredClientsStore;

  // Called on GET /authorize — render consent page or redirect
  authorize(client, params, res): Promise<void>;

  // Called on POST /token with grant_type=authorization_code
  exchangeAuthorizationCode(client, code, codeVerifier, redirectUri): Promise<OAuthTokens>;

  // Called on POST /token with grant_type=refresh_token
  exchangeRefreshToken(client, refreshToken): Promise<OAuthTokens>;

  // Called on every MCP request to verify the Bearer token
  verifyAccessToken(token): Promise<AuthInfo>;

  // Return the PKCE code challenge for a given auth code
  challengeForAuthorizationCode(client, code): Promise<string>;
}
```

The SDK's `mcpAuthRouter()` mounts:
- `GET /.well-known/oauth-authorization-server` — metadata discovery
- `GET /authorize` — calls `provider.authorize()`
- `POST /token` — calls `exchangeAuthorizationCode()` or `exchangeRefreshToken()` with built-in URL-encoded parsing and PKCE validation
- Bearer auth middleware for MCP endpoints

**We implement the provider methods backed by Firestore. The SDK handles protocol details.**

### Discovery

Handled automatically by `mcpAuthRouter()`. Returns metadata including:

```json
{
  "issuer": "https://mcp.povver.ai",
  "authorization_endpoint": "https://mcp.povver.ai/authorize",
  "token_endpoint": "https://mcp.povver.ai/token",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"]
}
```

### Client Registration

Implement `OAuthRegisteredClientsStore` with a hard-coded allowlist (no dynamic registration):

| `client_id` | Allowed `redirect_uri` patterns |
|-------------|--------------------------------|
| `claude-desktop` | Claude Desktop's callback scheme (determined from Claude Desktop docs at implementation time) |

Unknown `client_id` or mismatched `redirect_uri` → `400 invalid_request` (handled by SDK).

### Authorization Flow

The SDK calls `provider.authorize(client, params, res)` on `GET /authorize`. Our implementation:

1. Generate a session nonce (crypto-random, 32 chars). Store in Firestore collection `mcp_oauth_nonces/{nonce}` with OAuth params (redirect_uri, state, code_challenge, client_id) and TTL 10 minutes. (**Firestore, not in-memory** — Cloud Run scales to zero and has multiple instances with no session affinity.)
2. Serve the branded consent page with the nonce embedded as a hidden field.
3. User signs in via Firebase Auth JS SDK. If already signed in, skip to consent step.
4. On approve, the page calls `POST /authorize/complete` (custom endpoint, not part of SDK router) with: Firebase ID token, session nonce, `client_id`.
5. Server validates:
   - Nonce exists in Firestore and hasn't expired (CSRF protection)
   - Firebase ID token via Admin SDK `verifyIdToken()`
   - Retrieves OAuth params from nonce doc
6. Server revokes any existing OAuth tokens for this user (prevents unbounded token accumulation).
7. Server generates auth code (crypto-random, 64 chars), stores in Firestore `mcp_oauth_codes/{code_hash}` with userId + PKCE challenge + redirect_uri, TTL 5 minutes. Nonce doc is deleted (single-use).
8. Redirects browser to `redirect_uri?code=...&state=...`.

### Token Exchange

The SDK calls `provider.exchangeAuthorizationCode(client, code, codeVerifier, redirectUri)`. PKCE validation is handled by the SDK (it calls `challengeForAuthorizationCode()` and verifies against `codeVerifier`). Our implementation:

**Must use `runTransaction`** (security invariant S6) to prevent double-spend:

```
runTransaction:
  1. Read code doc by hash
  2. Validate: exists, not expired, redirect_uri match
  3. Delete code doc (single-use)
  4. Write access token doc + refresh token doc
  → return { access_token, refresh_token, expires_in }
```

Issues:
- Access token: opaque, prefixed `pvt_`, 1 hour TTL
- Refresh token: opaque, prefixed `pvt_`, 90 day TTL

### Token Refresh

The SDK calls `provider.exchangeRefreshToken(client, refreshToken)`. Our implementation:

**Must use `runTransaction`**:

```
runTransaction:
  1. Read refresh token doc by hash
  2. Validate: exists, not expired, type == "refresh"
  3. Delete old refresh token (or set grace_until = now + 30s)
  4. Write new access token doc + new refresh token doc
  → return new tokens
```

**Grace window**: After rotation, the old refresh token remains valid for 30 seconds (`grace_until` field). Handles retries when Claude Desktop's first refresh response is lost in transit.

### Access Token Verification

The SDK calls `provider.verifyAccessToken(token)` on every MCP request. Our implementation:

1. Route by prefix: `pvt_` → OAuth path, `pvk_` → API key path, no prefix → legacy API key path.
2. For OAuth: hash token, look up in `mcp_tokens`, validate `type === "access"` (prevents refresh tokens from being used as access tokens — refresh tokens have 90-day TTL vs 1-hour for access), validate not expired.
3. Check premium status (same as current API key flow).
4. Update `last_used_at` (debounced: skip if last write was <5 minutes ago, checked in-memory per instance — benign race across instances).

Note: existing API keys are generated without a prefix (raw hex via `crypto.randomBytes(32).toString('hex')` in `mcp/generate-api-key.js`). No existing key starts with `pvk_` or `pvt_`. New API keys should be prefixed `pvk_` going forward (update `generate-api-key.js` in this effort).

Premium lapse → HTTP 403 with `{ "error": "premium_required", "error_description": "Premium subscription required for MCP access" }`. Tokens remain valid — re-subscribing resumes the connection without re-authorization.

---

## Firestore Schema

### `mcp_oauth_nonces/{nonce}`

Temporary session nonces for CSRF protection during consent flow.

| Field | Type | Description |
|-------|------|-------------|
| `client_id` | string | OAuth client ID |
| `redirect_uri` | string | OAuth redirect URI |
| `state` | string | OAuth state parameter |
| `code_challenge` | string | PKCE S256 challenge |
| `code_challenge_method` | string | Always `"S256"` |
| `expires_at` | timestamp | 10 minutes from creation |
| `created_at` | timestamp | Server timestamp |

### `mcp_oauth_codes/{code_hash}`

Temporary, single-use authorization codes.

| Field | Type | Description |
|-------|------|-------------|
| `user_id` | string | Firebase Auth UID |
| `code_challenge` | string | PKCE S256 challenge |
| `redirect_uri` | string | Must match on token exchange |
| `expires_at` | timestamp | 5 minutes from creation |
| `created_at` | timestamp | Server timestamp |

### `mcp_tokens/{token_hash}`

Access and refresh tokens. SHA-256 hash of token value as document ID.

| Field | Type | Description |
|-------|------|-------------|
| `user_id` | string | Firebase Auth UID |
| `type` | string | `"access"` or `"refresh"` |
| `expires_at` | timestamp | 1h (access) or 90d (refresh) |
| `created_at` | timestamp | Server timestamp |
| `last_used_at` | timestamp | Debounced updates (~5 min per instance) |
| `grace_until` | timestamp / null | For rotated refresh tokens: valid until this time (30s). Null for active tokens. |

Access tokens are prefixed `pvt_` followed by 64 crypto-random hex chars. Refresh tokens use the same format. Both are stored as SHA-256 hashes of the full prefixed value. Plain-text token returned to client once, never stored.

**Type enforcement**: MCP request auth validates `type === "access"`. Token refresh validates `type === "refresh"`. This prevents a 90-day refresh token from being used as an access token.

### Firestore Rules

All three new collections added to `firestore.rules` as explicit deny-all (matching existing `mcp_api_keys` pattern):

```
match /mcp_oauth_nonces/{doc} {
  allow read, write: if false;
}
match /mcp_oauth_codes/{doc} {
  allow read, write: if false;
}
match /mcp_tokens/{doc} {
  allow read, write: if false;
}
```

### Required Indexes

- `mcp_tokens`: composite index on `user_id` (ASC) + `type` (ASC) — for `getMcpConnectionStatus` and token revocation queries.
- `mcp_oauth_codes`: single-field index on `expires_at` — for cleanup.
- `mcp_oauth_nonces`: single-field index on `expires_at` — for cleanup.
- `mcp_tokens`: single-field index on `expires_at` — for cleanup.

### Cleanup

Scheduled Cloud Function in `firebase_functions/functions/triggers/cleanup-mcp-tokens.js`. Runs daily via Cloud Scheduler. Deletes documents where `expires_at < now()` in `mcp_oauth_nonces`, `mcp_oauth_codes`, and `mcp_tokens`. Uses batched deletes (500 docs per batch) with pagination. Logs count of deleted documents.

Not critical for launch — volume is low — but should be added before significant user growth.

---

## Consent Page

Single HTML page served by the `authorize()` provider method. Branded to match povver.ai:

- Dark background (`#0A0E14`), accent green (`#22C59A`), Inter font
- Povver logo centered at top
- Heading: "Sign in to connect your training data to Claude"
- Three sign-in buttons: Apple / Google / Email (Firebase Auth JS SDK, same config as iOS app)
- After sign-in, brief consent confirmation: "Claude will be able to read and modify your routines, templates, and workout data"
- Approve button → calls `POST /authorize/complete` → redirects back to Claude Desktop

### Implementation

Static HTML with inline CSS and Firebase Auth JS SDK. The server embeds the session nonce as a hidden field when rendering. OAuth params are stored in Firestore (via the nonce doc), not passed through the page.

On sign-in + approve, the page calls `POST /authorize/complete` with:
- Firebase ID token (proves identity)
- Session nonce (proves legitimate consent page, CSRF protection)
- `client_id` (for logging)

### CORS

Consent page and `/authorize/complete` are same-origin (`mcp.povver.ai`). No CORS headers needed. MCP tool endpoints are server-to-server — no CORS.

### Firebase Auth Web Config

**Apple Sign-In on web** requires:
- Services ID registered in Apple Developer Console
- Domain `mcp.povver.ai` verified in Apple Developer Console
- Return URL registered for the Services ID
- Services ID configured in Firebase Console under Authentication > Apple provider

**Google Sign-In on web** requires:
- Domain `mcp.povver.ai` added to Google Cloud Console OAuth consent screen authorized domains

These are deployment prerequisites that will cause silent failures ("popup closed by user") if missed.

---

## Custom Domain

### DNS (Route 53)

Create DNS records as instructed by `gcloud run domain-mappings create` output (may be A/AAAA records or CNAME depending on region).

### Cloud Run Domain Mapping

```bash
gcloud run domain-mappings create \
  --service mcp-server \
  --domain mcp.povver.ai \
  --region us-central1 \
  --project myon-53d85
```

Google manages SSL certificate provisioning and renewal.

### Alternative: Cloud Run with Global External ALB

If Cloud Run domain mapping has issues (it's been flaky historically), fall back to a Global External Application Load Balancer with a serverless NEG pointing to the Cloud Run service.

---

## iOS Settings UI

### Location

New section in the app's Settings screen (within `ConnectedAppsView` or `MoreView`), above the existing API Keys section.

### Architecture

Business logic (connection status check, disconnect, premium check) lives in a ViewModel (`ClaudeConnectionViewModel` or similar), not inline in the View. The ViewModel calls the Firebase Function endpoints and publishes state for the View to render.

### States

**Not connected** (no active tokens for user in `mcp_tokens`):
- Claude icon + "Claude Desktop" heading
- Card with 3-step instructions:
  1. Open Claude Desktop > Settings > Connectors > Add custom connector
  2. Name: `Povver`, URL: `https://mcp.povver.ai`
  3. Click Add, then sign in with your Povver account
- Copy URL button (copies `https://mcp.povver.ai` to clipboard)

**Connected** (active tokens exist):
- Claude icon + "Claude Desktop" heading
- Green dot + "Connected"
- Last used: relative timestamp from `last_used_at`
- "Disconnect" button → confirmation alert → calls Firebase Function

**Disabled** (not premium):
- Claude icon + "Claude Desktop" heading
- Amber indicator + "Disabled — Premium required"
- "Upgrade" button → presents paywall

### Connection Status Check

The app calls Firebase Function `getMcpConnectionStatus` (bearer-lane) which queries `mcp_tokens` server-side. Returns `ok({ connected: boolean, last_used_at: timestamp | null })`. Keeps `mcp_tokens` deny-all in Firestore rules. Called once when settings screen appears.

### Disconnect

Calls Firebase Function `revokeMcpTokens` (`requireFlexibleAuth`, `getAuthenticatedUserId(req)`) which deletes all `mcp_tokens` and `mcp_oauth_codes` for the user. Returns `ok({ revoked: true })`.

After disconnect: Claude Desktop's next MCP request → 401. Refresh attempt → 401 (token deleted). Claude Desktop surfaces re-authorization prompt.

---

## Server Changes Summary

### Dependencies to add

| Package | Purpose |
|---------|---------|
| `express` | Required by SDK's `mcpAuthRouter()`. Replaces raw `http.createServer()`. |

### New files in `mcp_server/src/`

| File | Purpose |
|------|---------|
| `oauth-provider.ts` | `OAuthServerProvider` implementation backed by Firestore (authorize, exchangeAuthorizationCode, exchangeRefreshToken, verifyAccessToken, challengeForAuthorizationCode) |
| `clients-store.ts` | `OAuthRegisteredClientsStore` with hard-coded client allowlist |
| `consent.ts` | Serves the branded consent HTML page with embedded nonce |
| `tokens.ts` | Token generation, hashing, storage, revocation (transactional) |

### Modified files

| File | Change |
|------|--------|
| `index.ts` | Migrate from `http.createServer()` to Express. Mount `mcpAuthRouter()`. Keep API key auth path for `pvk_`/unprefixed tokens. |
| `auth.ts` | Add prefix-based routing. `verifyAccessToken()` becomes the primary OAuth path. Existing `authenticateApiKey()` handles `pvk_`/legacy. |
| `package.json` | Add `express` dependency |

### Firebase Function changes

Location: `firebase_functions/functions/mcp/`

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `getMcpConnectionStatus` | `requireFlexibleAuth` / `getAuthenticatedUserId(req)` | Returns `ok({ connected, last_used_at })` |
| `revokeMcpTokens` | `requireFlexibleAuth` / `getAuthenticatedUserId(req)` | Deletes all OAuth tokens/codes/nonces for user, returns `ok({ revoked: true })` |

Both use `ok()`/`fail()` from `utils/response.js`. Must be exported from `index.js`.

Also update `mcp/generate-api-key.js` to prefix new keys with `pvk_`.

### Scheduled Function

| Function | Location | Schedule |
|----------|----------|----------|
| `cleanupMcpTokens` | `firebase_functions/functions/triggers/cleanup-mcp-tokens.js` | Daily |

---

## Security Considerations

- **PKCE enforced**: SDK validates S256 code challenge. Requests without PKCE rejected.
- **Token hashing**: SHA-256 hashes in Firestore. Raw tokens only in transit, never logged.
- **Token type enforcement**: `type === "access"` checked on MCP requests. `type === "refresh"` checked on refresh. Prevents 90-day refresh token from being used as 1-hour access token.
- **Single-use codes**: Consumed atomically via `runTransaction` (S6).
- **Redirect URI validation**: Allowlisted per client_id. Stored at code creation, verified at exchange.
- **Token rotation**: Refresh token invalidated via `runTransaction`. 30-second grace window for retry safety.
- **CSRF protection**: Server-generated nonce stored in Firestore, embedded in consent page, validated on `/authorize/complete`. Single-use, 10-minute TTL.
- **Token accumulation prevention**: Re-authorization revokes all existing tokens for the user.
- **Premium gate unchanged**: Checked on every MCP request. Returns 403 with descriptive error.
- **CORS**: Same-origin consent flow. MCP endpoints: no CORS (server-to-server).
- **No client secret**: Public client flow per OAuth 2.1. Security via PKCE + redirect URI allowlist + nonce.
- **Firebase ID token validation**: Admin SDK `verifyIdToken()`.
- **Rate limiting**: SDK's built-in `express-rate-limit` on OAuth endpoints.
- **HTTPS only**: Cloud Run TLS termination.
- **OAuth error format**: Standard `{ "error": "...", "error_description": "..." }`.

---

## Documentation Updates Required

| Document | Update |
|----------|--------|
| `docs/FIRESTORE_SCHEMA.md` | Add `mcp_oauth_nonces`, `mcp_oauth_codes`, and `mcp_tokens` collection schemas |
| `docs/SYSTEM_ARCHITECTURE.md` | Update MCP server box: "API key + OAuth 2.1 auth" |
| `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` | Add `getMcpConnectionStatus`, `revokeMcpTokens`, `cleanupMcpTokens` |
| `docs/SECURITY.md` | Note browser client surface (consent page), CORS posture, nonce-based CSRF, token type enforcement |
| `firebase_functions/firestore.rules` | Add explicit deny-all for 3 new collections |
| `firebase_functions/firestore.indexes.json` | Add required composite indexes |

---

## Deployment Checklist

1. Configure Apple Services ID with `mcp.povver.ai` domain + return URL in Apple Developer Console
2. Configure Firebase Auth Apple provider with the Services ID
3. Add `mcp.povver.ai` to Google Cloud Console OAuth consent screen authorized domains
4. Add `mcp.povver.ai` to Firebase Auth authorized domains (Firebase Console)
5. Create DNS records in Route 53 (per `gcloud run domain-mappings create` output)
6. Create Cloud Run domain mapping
7. Wait for SSL certificate provisioning
8. Deploy MCP server with OAuth (Express migration + SDK auth router)
9. Deploy new Firebase Functions (`getMcpConnectionStatus`, `revokeMcpTokens`)
10. Deploy updated `generate-api-key.js` with `pvk_` prefix
11. Update Firestore rules with explicit deny-all for new collections
12. Deploy Firestore indexes
13. Test end-to-end: Claude Desktop → authorize → consent → MCP tools
14. Ship iOS update with settings UI

---

## User Flow Summary

### Claude Desktop (new)

1. User opens Claude Desktop > Settings > Connectors > Add custom connector
2. Enters name "Povver", URL `https://mcp.povver.ai`
3. Claude Desktop discovers OAuth metadata, opens browser
4. User sees branded Povver consent page, signs in with Apple/Google/email
5. Approves access, browser redirects back to Claude Desktop
6. Claude Desktop has tokens, MCP tools available immediately
7. User asks Claude about their training — Claude calls MCP tools

### iOS Settings (new)

1. User opens Settings in Povver app
2. Sees "Claude Desktop" section with instructions or connected status
3. Can copy URL, disconnect, or upgrade to premium

### API Keys (unchanged)

1. User generates API key in Povver app settings
2. Pastes into Claude Code config, Cursor, etc.
3. Works exactly as before
