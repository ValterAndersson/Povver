# Auth — Module Architecture

Authentication middleware and token exchange for Firebase Functions. Provides three authentication strategies used across all endpoints.

## File Inventory

| File | Purpose |
|------|---------|
| `middleware.js` | All auth middleware: `withApiKey`, `requireFlexibleAuth`, `requireAuth`, and low-level verifiers. CORS, security headers, and structured auth failure logging. |
| `exchange-token.js` | `getServiceToken` — exchanges Firebase ID tokens for GCP service account access tokens (iOS uses these to call Vertex AI Agent Engine directly) |

## Authentication Strategies

| Middleware | User ID Source | Use Case | Wrapped In |
|-----------|---------------|----------|------------|
| `withApiKey` | `X-User-Id` header or `req.body.userId` (trusted) | Agent/service-to-service calls | `index.js` |
| `requireFlexibleAuth` | Bearer → `req.auth.uid`; API key → `X-User-Id` header or `req.body.userId` | Endpoints called by both iOS and agents | `index.js` |
| `requireAuth` | `req.auth.uid` only | iOS-only endpoints (strict) | `index.js` |

## Security Model

**Bearer Lane (Firebase Auth Token):**
- Used by iOS app
- `userId` derived from `req.auth.uid` ONLY
- Client-provided `userId` in request body is IGNORED
- Prevents cross-user data access (IDOR prevention)
- Auth failures logged with IP, path, user-agent for incident detection

**Service Lane (API Key):**
- Used by agent system and service-to-service calls
- `userId` from `X-User-Id` header (via `req.auth.uid`) or `req.body.userId` (trusted)
- Authenticated via `X-API-Key` header only (query param `apiKey` not accepted — prevents leakage in access logs)
- Invalid API key attempts logged with key prefix + IP

**Why Bearer endpoints never trust request params:**
If a Bearer endpoint accepted `userId` from the request body, any authenticated user could read/write another user's data by providing a different `userId`. The middleware enforces that Bearer-authenticated requests always derive `userId` from the verified Firebase Auth token.

## CORS & Security Headers

No browser clients exist (iOS native + server-to-server only). CORS is restricted to localhost origins for local development. No wildcard CORS is permitted.

All responses include security headers: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`.

## Token Exchange

`exchange-token.js` issues GCP access tokens scoped to `cloud-platform`. The scope MUST remain `cloud-platform` — Vertex AI Agent Engine (v1beta1 reasoningEngines endpoints) does not accept narrower scopes. The iOS app uses these tokens in `DirectStreamingService.swift` to call Vertex AI directly.

## Structured Auth Logging

Auth failures are logged for incident detection:
- `[auth] token_verification_failed` — invalid/expired Firebase ID tokens
- `[auth] invalid_api_key` — API key validation failures (key prefix logged, not full key)
- `[auth] idor_attempt_blocked` — client tried to pass a different userId than their token (logged in `utils/auth-helpers.js`)

## Cross-References

- All endpoint wrappers in `index.js` use these middleware functions
- IDOR prevention helper: `utils/auth-helpers.js` → `getAuthenticatedUserId(req)`
- Security invariants: `docs/SECURITY.md`
- Auth patterns overview: `docs/SYSTEM_ARCHITECTURE.md` (Authentication Lanes section)
