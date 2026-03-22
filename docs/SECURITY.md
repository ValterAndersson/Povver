# Security Architecture

> Authoritative reference for security invariants, auth lanes, and constraints.
> Violations of these invariants can expose user data, enable privilege escalation, or create financial liability.

---

## Security Invariants (NEVER Violate)

These are non-negotiable. If a change would require violating one, stop and discuss with the team.

| # | Invariant | Enforcement |
|---|-----------|-------------|
| S1 | **Bearer-lane userId comes from the verified token, never from request params** | `getAuthenticatedUserId(req)` in `utils/auth-helpers.js` |
| S2 | **Subscription fields are written only by Admin SDK (webhook/Cloud Functions), never by clients** | Firestore rules block client writes to `subscription_*` fields |
| S3 | **Premium-gated actions check `isPremiumUser()` server-side, never trust client claims** | `utils/subscription-gate.js` reads Firestore directly |
| S4 | **LLM output does not control auth, subscription, or cross-user data access** | Auth enforced at Firebase Functions layer, not in agent |
| S5 | **API keys are loaded from environment variables, never hardcoded** | `process.env.VALID_API_KEYS` in middleware |
| S6 | **Firestore read-then-write must be inside `runTransaction`** | Convention enforced by code review |
| S7 | **App Store webhook payloads are JWS-verified in production** | `SignedDataVerifier` via shared `apple-verifier.js` module |
| S8 | **Subscription sync requires Apple-signed proof** | `syncSubscriptionStatus` verifies JWS before writing |
| S9 | **Conversation messages are Admin SDK only** | Firestore rules: `allow write: if false` on messages subcollection |

---

## Authentication Model

### Three Auth Lanes

Every Firebase Function endpoint uses exactly one of these middlewares. They are defined in `auth/middleware.js`.

| Middleware | Who calls it | userId source | When to use |
|------------|-------------|---------------|-------------|
| `requireFlexibleAuth(handler)` | iOS app OR agent system | Bearer: `req.auth.uid` (token-verified). API key: `req.body.userId` (trusted service) | Most endpoints |
| `withApiKey(handler)` | Agent system, scripts | `req.body.userId` or `req.query.userId` (trusted service) | Agent-only endpoints |
| `requireAuth(handler)` | iOS app only | `req.user.uid` (token-verified) | Strict iOS-only endpoints |

### IDOR Prevention

`getAuthenticatedUserId(req)` in `utils/auth-helpers.js` is the **single source of truth** for deriving the current user's ID. Every endpoint handler must use it.

**How it works:**
- **Bearer lane**: Returns `req.user.uid` or `req.auth.uid` from the decoded Firebase ID token. Ignores any `userId` in request body/query. Logs IDOR attempts when a client tries to pass a different userId.
- **API key lane**: Returns `req.auth.uid` (set by middleware from `X-User-Id` header) or falls back to `req.body.userId` / `req.query.userId`. This is safe because API key callers are authenticated services.

**When adding a new endpoint:**
```javascript
// CORRECT
const userId = getAuthenticatedUserId(req);
if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);

// WRONG — IDOR vulnerability
const userId = req.body.userId;
```

### CORS Policy

No browser clients exist (iOS native + server-to-server only). CORS is restricted to localhost for local development:

```javascript
const ALLOWED_ORIGINS = new Set([
  'http://localhost:3000', 'http://localhost:5173',
  'http://127.0.0.1:3000', 'http://127.0.0.1:5173',
]);
```

No wildcard CORS (`Access-Control-Allow-Origin: *`) is permitted. If browser clients are added in the future, add specific origins to the allowlist.

### Browser Client Surface (Consent Page)

The MCP OAuth consent page at `mcp.povver.ai` is a browser client using Firebase Auth JS SDK. This is the only browser-facing surface in the system.

- **CORS**: Same-origin (consent page + `/authorize/complete` both on `mcp.povver.ai`). No CORS headers needed.
- **CSRF**: Server-generated nonce stored in Firestore, embedded in consent page, validated server-side. Single-use, 10-minute TTL.
- **Token type enforcement**: Access tokens (`type === "access"`) validated on MCP requests. Refresh tokens (`type === "refresh"`) validated on refresh. Prevents 90-day refresh token from being used as 1-hour access token.
- **Firebase API key in browser**: The consent page embeds `FIREBASE_API_KEY` in the HTML source. This is standard practice for Firebase browser clients — the key is restricted to authorized domains and Firebase Auth operations only. It is NOT a server secret despite being stored as an env var for deployment convenience.

### Security Headers

All responses include:
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`

Set by `setSecurityHeaders(res)` in `auth/middleware.js`.

### Token Exchange

`exchange-token.js` exchanges Firebase ID tokens for GCP service account access tokens. The iOS app uses these to call Vertex AI Agent Engine directly.

**Scope constraint**: The scope MUST be `cloud-platform`. Vertex AI Agent Engine (v1beta1 reasoningEngines endpoints) does not accept narrower scopes. All Vertex AI calls in the codebase use `cloud-platform` — see `open-canvas.js`, `stream-agent-normalized.js`, `config.js`.

---

## Firestore Security Rules

Rules are in `firebase_functions/firestore.rules`. Key protections:

### User Documents (`users/{uid}`)

- **Read**: Owner only (`request.auth.uid == uid`)
- **Create**: Owner only, subscription fields blocked (can't self-grant premium)
- **Update**: Owner only, subscription fields blocked via `diff().affectedKeys()` check

### Conversation Messages (`users/{uid}/conversations/{cid}/messages`)

- **Read**: Owner only
- **Write**: `allow write: if false` — Admin SDK only. Messages are written by `streamAgentNormalized` Cloud Function. This prevents clients from injecting fake AI responses into the conversation history.

Blocked fields on create/update:
```
subscription_tier, subscription_override, subscription_status,
subscription_product_id, subscription_original_transaction_id,
subscription_app_account_token, subscription_auto_renew_enabled,
subscription_in_grace_period, subscription_updated_at,
subscription_environment, subscription_expires_at
```

These fields are written ONLY by Admin SDK (webhook handler, sync function).

### User Subcollections

All subcollections under `users/{uid}/` (conversations, routines, templates, workouts, active_workouts, etc.) require `request.auth.uid == uid` for both read and write.

### Root Collections

| Collection | Client Access | Why |
|------------|--------------|-----|
| `exercises`, `exercise_aliases` | Read-only | Admin SDK manages catalog |
| `catalog_jobs`, `training_analysis_jobs` | Denied | Internal job queues |
| `processed_webhook_notifications` | Denied | Replay protection (Admin SDK only) |
| `cache` | Denied | Server-side cache |

### Deny-All Fallback

```javascript
match /{document=**} {
  allow read, write: if false;
}
```

Any collection not explicitly listed is blocked. New collections must be explicitly added to the rules.

---

## Storage Security Rules

Rules are in `firebase_functions/storage.rules`. Currently deny-all (no user file uploads exist). When adding file upload features, scope rules to authenticated users and specific paths.

---

## Subscription Security

### Authority Model

```
Webhook (Apple → server)     ← AUTHORITATIVE for all state changes
    ↓ writes
Firestore subscription_*     ← Source of truth
    ↑ reads
isPremiumUser()              ← Gate check (direct Firestore read, not cached)
    ↑ reads
iOS SubscriptionService      ← Mirrors StoreKit state, syncs POSITIVE entitlements only
```

**Key principle**: The iOS app can only sync positive entitlements (tier=premium, status in active/trial/grace_period) via the `syncSubscriptionStatus` Cloud Function. It cannot downgrade a user. Downgrades happen exclusively through the webhook when Apple sends EXPIRED/REFUND/REVOKE notifications.

### Premium Gates

| Endpoint | Gate | Error Format |
|----------|------|-------------|
| `streamAgentNormalized` | `isPremiumUser(userId)` | SSE `{ type: 'error', error: { code: 'PREMIUM_REQUIRED' } }` |
| `artifact-action.js` (save_routine, save_template, start_workout, save_as_new) | `isPremiumUser(userId)` | HTTP `fail(res, 'PREMIUM_REQUIRED', ...)` |
| Training analysis jobs | `isPremiumUser(userId)` | Job not enqueued (silent) |

**When adding a new premium feature:** Call `isPremiumUser(userId)` from `utils/subscription-gate.js` before the business logic. Return appropriate error format (HTTP `fail()` for REST, SSE error event for streaming).

### Webhook Security

- **JWS verification**: All webhook payloads are verified using Apple root certificates (`AppleRootCA-G2.cer`, `AppleRootCA-G3.cer`) via `@apple/app-store-server-library`
- **Shared verifier module**: `subscriptions/apple-verifier.js` exports `verifySignedTransaction()` and `verifySignedNotification()`, used by both the webhook and `syncSubscriptionStatus`
- **Fail-secure**: If the verifier is unavailable in production, webhooks are rejected (not silently accepted)
- **Emulator fallback**: Insecure base64 decode only when `FUNCTIONS_EMULATOR=true`
- **Replay protection**: `notificationUUID` tracked in `processed_webhook_notifications` collection (90-day TTL)
- **Always returns 200**: Apple retries non-200s indefinitely

### Subscription Sync Security

`syncSubscriptionStatus` (iOS → server positive entitlement sync) enforces:

- **Bearer-lane only** — rejects API key authentication
- **Apple JWS required** — client must send `signedTransactionInfo` (Apple-signed JWS from StoreKit 2). Server verifies against Apple root certificates before writing
- **Bundle ID validation** — decoded transaction must have `bundleId === 'com.povver.Povver'`
- **Positive-only** — only accepts `tier=premium` with `status` in `active/trial/grace_period`. Client cannot downgrade; webhook is authoritative for downgrades

### Account Deletion

`deleteAccount` Cloud Function (App Store Guideline 5.1.1(v)):

- **Bearer-lane only** — user can only delete their own account
- **Admin SDK** — uses Admin SDK to delete subcollections blocked by Firestore rules (conversations, canvases, agent_sessions, subscription_events, etc.)
- **Complete purge** — deletes 20+ subcollections, nested sub-subcollections (messages, artifacts, cards), cache entries, the user document, and Firebase Auth account
- **Safety bounds** — batch delete loop capped at 200 iterations (100,000 docs), function timeout 120s

---

## Rate Limiting

In-memory sliding window rate limiter in `utils/rate-limiter.js`. Per-instance (not distributed), paired with `maxInstances` on v2 functions for global cost control.

### Tiers

| Limiter | Window | Max | Applied To |
|---------|--------|-----|-----------|
| `authLimiter` | 1 min | 10 | Auth-related endpoints |
| `agentLimiter` | 1 hour | 120 | `streamAgentNormalized` (expensive LLM calls) |
| `writeLimiter` | 1 min | 300 | Write-heavy endpoints |

### maxInstances (Global Cost Control)

| Function | maxInstances | Concurrency |
|----------|-------------|-------------|
| `streamAgentNormalized` | 20 | 1 (SSE requires dedicated connection) |
| `openCanvas`, `preWarmSession` | 30 | default |
| `artifactAction` | 30 | default |
| `appStoreWebhook` | 10 | default |

---

## Input Validation

Zod schemas with security bounds in `utils/validators.js`:

| Bound | Value | Rationale |
|-------|-------|-----------|
| `MAX_WEIGHT_KG` | 1500 | Leg press world record territory |
| `MAX_REPS` | 500 | Endurance edge case |
| `MAX_EXERCISES_PER_WORKOUT` | 50 | Prevents payload abuse |
| `MAX_SETS_PER_EXERCISE` | 100 | Prevents payload abuse |
| `MAX_NAME_LENGTH` | 200 | Prevents storage abuse |
| `MAX_NOTES_LENGTH` | 5000 | Prevents storage abuse |
| `MAX_WORKOUTS_PER_ROUTINE` | 14 | Prevents cost amplification via unbounded template creation |
| `MAX_ARTIFACT_SIZE` | 50KB | Prevents storage abuse from oversized agent output |

**Message length limit**: Agent streaming endpoint (`streamAgentNormalized`) enforces a 10KB message limit to prevent cost abuse via oversized LLM payloads.

**Artifact size limit**: Agent artifacts are validated before Firestore persistence — content exceeding 50KB is logged and skipped. The SSE stream is not blocked (client still receives the artifact), but it won't be persisted.

**When adding new write endpoints:** Use Zod schemas for input validation. Validate before business logic. Apply sensible upper bounds to numeric fields and string lengths.

---

## Agent System Security

The LLM (Gemini via Vertex AI Agent Engine) operates within constrained boundaries:

### What the LLM CAN do
- Read user's own training data (via `get_planning_context`, `get_training_context` tools)
- Propose workout plans (via artifacts in SSE stream)
- Log sets to the user's own workout (via `tool_log_set`, validated by Firebase Function)

### What the LLM CANNOT do
- Access another user's data (auth enforced at Firebase Function layer, not LLM)
- Grant/revoke premium status (no tool exists; subscription fields blocked by Firestore rules)
- Bypass input validation (all tool calls go through Firebase Functions with Zod validation)
- Execute arbitrary code (tools are predefined Python functions with specific parameters)

### Prompt Injection Posture

**Risk level**: Low for this domain (fitness app, not financial).

**Why it's contained**:
1. System prompt and user message are in separate roles (Gemini API)
2. Auth/subscription/writes validated at Firebase layer, not by LLM reasoning
3. LLM has no privilege-escalation tools
4. User `user_id` comes from authenticated context (`ContextVar`), not from message content

**Mitigations in place**:
- 10KB message length limit (cost abuse prevention)
- Rate limiting (120 req/hour per user)
- Premium gate (free users can't access agent)
- Input validation on all tool parameters

---

## Health Data Protection

Workout data (exercise names, weights, reps) is technically health-adjacent data. Protections in place:

- **Firestore**: All workout data under `users/{uid}/` with owner-only access rules
- **Agent isolation**: userId from `ContextVar`, never passed as tool parameter — prevents cross-user leakage
- **On-device logs**: `WorkoutSessionLogger` writes to `Caches/workout_logs/` (not included in iCloud/iTunes backups). Contains exercise names, weights, reps for diagnostic purposes only
- **Crash reporting**: No workout data sent to Crashlytics — only breadcrumb event types (e.g., "set_logged") without health payloads
- **Privacy manifest**: `PrivacyInfo.xcprivacy` declares collected data types including fitness data, with `NSPrivacyCollectedDataTypePurposes` set to app functionality (not tracking)

---

## Structured Security Logging

Auth failures and suspicious activity are logged with structured data for incident detection:

```javascript
// Auth failure
logger.warn('[auth] token_verification_failed', {
  error_code, error_message, ip, path, user_agent
});

// Invalid API key
logger.warn('[auth] invalid_api_key', {
  key_prefix: apiKey.substring(0, 4) + '***', ip, path, user_agent
});

// IDOR attempt
logger.warn('[auth] idor_attempt_blocked', {
  token_uid, requested_uid, path, ip
});

// Rate limit exceeded
logger.warn('[rate_limit] exceeded', { key, limit, window_ms });
```

---

## Data Retention & TTL

Collections with TTL fields require a **Firestore TTL policy** configured in GCP Console. The `expires_at` field marks documents for automatic deletion, but Firestore only honors it if a TTL policy is set on that collection.

| Collection | TTL Field | Retention | Status |
|------------|-----------|-----------|--------|
| `processed_webhook_notifications` | `expires_at` | 90 days | Needs TTL policy |
| `users/{uid}/subscription_events` | `expires_at` | 180 days | Needs TTL policy |

**To configure TTL policies:**
```bash
gcloud firestore fields ttls update expires_at \
  --collection-group=processed_webhook_notifications \
  --project=myon-53d85

gcloud firestore fields ttls update expires_at \
  --collection-group=subscription_events \
  --project=myon-53d85
```

### Default Query Limits

`getDocumentsFromSubcollection()` in `utils/firestore-helper.js` enforces a default limit of 500 documents when no explicit limit is provided. This prevents accidental unbounded reads.

---

## Operational Security (Console/CLI)

These items require GCP Console or gcloud CLI access and are NOT enforced by code:

| Item | Current State | Target State | Priority |
|------|---------------|-------------|----------|
| Firestore TTL policies | Not configured | Enable on `processed_webhook_notifications` and `subscription_events` | HIGH |
| Default SAs have `roles/editor` | Overly broad | Dedicated SAs per workload with minimal roles | HIGH |
| API keys in Functions config | Visible to project members | Migrate to Secret Manager | HIGH |
| Langfuse secret key in config | Exposed | Rotate + move to Secret Manager | HIGH |
| Cloud Monitoring alerts | None | Alert on auth failures, rate limits, errors | MEDIUM |
| SA key file permissions | Unknown | `chmod 400 ~/.config/povver/*.json` | LOW |

---

## Security Checklist for New Endpoints

When creating a new Firebase Function endpoint:

1. **Auth middleware**: Wrap with `requireFlexibleAuth`, `withApiKey`, or `requireAuth`
2. **userId derivation**: Use `getAuthenticatedUserId(req)` — never `req.body.userId` in bearer-lane
3. **Input validation**: Validate all inputs with Zod or manual checks before business logic
4. **Premium gate**: If the feature is premium, call `isPremiumUser(userId)` and return `fail(res, 'PREMIUM_REQUIRED', ...)`
5. **Response format**: Use `ok(res, data)` / `fail(res, code, message, details, httpStatus)`
6. **Logging**: Use `logger` from `firebase-functions`, include userId and action context
7. **Firestore writes**: Use `serverTimestamp()`, wrap read-then-write in `runTransaction`
8. **Rate limiting**: Apply appropriate limiter for expensive operations
9. **maxInstances**: Set on v2 function options for cost control
10. **Firestore rules**: If writing to a new collection, add rules in `firestore.rules`

---

## Cross-References

| Topic | Location |
|-------|----------|
| Auth middleware implementation | `firebase_functions/functions/auth/ARCHITECTURE.md` |
| Rate limiter + validators | `firebase_functions/functions/utils/ARCHITECTURE.md` |
| Subscription lifecycle | `firebase_functions/functions/subscriptions/ARCHITECTURE.md` |
| Auth lanes overview | `docs/SYSTEM_ARCHITECTURE.md` → Authentication Lanes |
| Firestore schema | `docs/FIRESTORE_SCHEMA.md` |
| Agent context security | `docs/SYSTEM_ARCHITECTURE.md` → Context Flow |
| iOS subscription components | `docs/IOS_ARCHITECTURE.md` |
