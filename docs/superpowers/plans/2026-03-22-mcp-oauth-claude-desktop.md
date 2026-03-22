# MCP OAuth 2.1 for Claude Desktop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OAuth 2.1 to the MCP server so Claude Desktop users can connect via `https://mcp.povver.ai` with one-click authorization.

**Architecture:** Implement the MCP SDK's `OAuthServerProvider` interface backed by Firestore. Migrate the server from raw `http.createServer()` to Express (required by the SDK's `mcpAuthRouter()`). Add branded consent page, Firebase Functions for iOS connection management, and Firestore rules/indexes.

**Tech Stack:** TypeScript, Express 5, MCP SDK v1.27.1 (`@modelcontextprotocol/sdk`), Firebase Admin SDK, Firestore, Firebase Auth JS SDK (consent page)

**Spec:** `docs/superpowers/specs/2026-03-22-mcp-oauth-claude-desktop-design.md`

---

## File Structure

### MCP Server (`mcp_server/src/`)

| File | Responsibility |
|------|---------------|
| `tokens.ts` (new) | Token/code/nonce generation, hashing, Firestore CRUD. All transactional writes. Pure Firestore operations. |
| `clients-store.ts` (new) | `OAuthRegisteredClientsStore` — hard-coded client allowlist |
| `oauth-provider.ts` (new) | `OAuthServerProvider` implementation. Delegates to `tokens.ts` for storage, `consent.ts` for HTML. |
| `consent.ts` (new) | Branded consent page HTML generation with embedded nonce |
| `index.ts` (modify) | Migrate to Express. Mount `mcpAuthRouter()` + custom `/authorize/complete` endpoint. Dual auth: OAuth tokens + API keys. |
| `auth.ts` (modify) | Add prefix-based routing (`pvt_` → OAuth, `pvk_`/none → API key). Add `authenticateOAuthToken()`. |

### Firebase Functions (`firebase_functions/functions/`)

| File | Responsibility |
|------|---------------|
| `mcp/get-connection-status.js` (new) | `getMcpConnectionStatus` — queries `mcp_tokens` for user, returns `{ connected, last_used_at }` |
| `mcp/revoke-tokens.js` (new) | `revokeMcpTokens` — deletes all OAuth tokens/codes/nonces for user |
| `mcp/generate-api-key.js` (modify) | Prefix new keys with `pvk_` |
| `triggers/cleanup-mcp-tokens.js` (new) | Scheduled daily cleanup of expired nonces/codes/tokens |
| `user/delete-account.js` (modify) | Add OAuth token/code cleanup on account deletion |
| `index.js` (modify) | Export new functions |

### Firestore Config

| File | Change |
|------|--------|
| `firebase_functions/firestore.rules` (modify) | Add deny-all for `mcp_oauth_nonces`, `mcp_oauth_codes`, `mcp_tokens` |
| `firebase_functions/firestore.indexes.json` (modify) | Add composite index on `mcp_tokens` |

### iOS (`Povver/Povver/`)

| File | Responsibility |
|------|---------------|
| `ViewModels/ClaudeConnectionViewModel.swift` (new) | Connection status, disconnect, premium check |
| `Views/Settings/ClaudeConnectionSection.swift` (new) | UI for not-connected / connected / disabled states |
| `Views/Settings/ConnectedAppsView.swift` (modify) | Add Claude Desktop section above API Keys |

### Documentation

| File | Change |
|------|--------|
| `docs/FIRESTORE_SCHEMA.md` | Add 3 new collections |
| `docs/SYSTEM_ARCHITECTURE.md` | Update MCP server box |
| `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` | Add 3 new functions |
| `docs/SECURITY.md` | Note consent page browser surface, Firebase API key exception |

---

## Task 1: Token Utilities (`tokens.ts`)

**Files:**
- Create: `mcp_server/src/tokens.ts`

Core storage layer for nonces, auth codes, and tokens. All transactional where required.

- [ ] **Step 1: Create `tokens.ts` with token generation and hashing**

```typescript
// mcp_server/src/tokens.ts
import { createHash, randomBytes } from 'crypto';
import admin from 'firebase-admin';

const db = admin.firestore();

const COLLECTIONS = {
  nonces: 'mcp_oauth_nonces',
  codes: 'mcp_oauth_codes',
  tokens: 'mcp_tokens',
} as const;

const TTL = {
  nonce: 10 * 60 * 1000,   // 10 minutes
  code: 5 * 60 * 1000,     // 5 minutes
  access: 60 * 60 * 1000,  // 1 hour
  refresh: 90 * 24 * 60 * 60 * 1000, // 90 days
  grace: 30 * 1000,        // 30 seconds
} as const;

export function generateToken(): string {
  return 'pvt_' + randomBytes(32).toString('hex');
}

export function generateCode(): string {
  return randomBytes(32).toString('hex');
}

export function generateNonce(): string {
  return randomBytes(16).toString('hex');
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
```

- [ ] **Step 2: Add nonce storage (Firestore, not in-memory)**

```typescript
export interface NonceData {
  client_id: string;
  redirect_uri: string;
  state?: string;
  code_challenge: string;
  code_challenge_method: string;
}

export async function storeNonce(nonce: string, data: NonceData): Promise<void> {
  await db.collection(COLLECTIONS.nonces).doc(nonce).set({
    ...data,
    expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.nonce),
    created_at: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/** Consume nonce atomically. Uses runTransaction (S6) to prevent double-spend. */
export async function consumeNonce(nonce: string): Promise<NonceData | null> {
  return db.runTransaction(async (tx) => {
    const doc = await tx.get(db.collection(COLLECTIONS.nonces).doc(nonce));
    if (!doc.exists) return null;

    const data = doc.data()!;
    if (data.expires_at.toMillis() < Date.now()) {
      tx.delete(doc.ref);
      return null;
    }

    tx.delete(doc.ref); // single-use
    return {
      client_id: data.client_id,
      redirect_uri: data.redirect_uri,
      state: data.state,
      code_challenge: data.code_challenge,
      code_challenge_method: data.code_challenge_method,
    };
  });
}
```

- [ ] **Step 3: Add auth code storage (transactional exchange)**

```typescript
export async function storeAuthCode(
  code: string,
  userId: string,
  codeChallenge: string,
  redirectUri: string,
): Promise<void> {
  const hash = hashToken(code);
  await db.collection(COLLECTIONS.codes).doc(hash).set({
    user_id: userId,
    code_challenge: codeChallenge,
    redirect_uri: redirectUri,
    expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.code),
    created_at: admin.firestore.FieldValue.serverTimestamp(), // serverTimestamp for non-transactional writes
  });
}

// Note on timestamps inside transactions:
// - expires_at uses Date.now() + offset because we need to compare it in the same transaction
// - created_at uses Timestamp.now() inside transactions (FieldValue.serverTimestamp() is
//   also valid in set/update within transactions, but Timestamp.now() is simpler)
// - Outside transactions, created_at uses FieldValue.serverTimestamp()

export async function getCodeChallenge(code: string): Promise<string> {
  const hash = hashToken(code);
  const doc = await db.collection(COLLECTIONS.codes).doc(hash).get();
  if (!doc.exists) throw new Error('Invalid authorization code');
  const data = doc.data()!;
  if (data.expires_at.toMillis() < Date.now()) throw new Error('Authorization code expired');
  return data.code_challenge;
}

/** Exchange auth code for tokens. Uses runTransaction (S6). */
export async function exchangeCode(
  code: string,
  redirectUri: string,
): Promise<{ userId: string; accessToken: string; refreshToken: string; expiresIn: number }> {
  const codeHash = hashToken(code);
  const accessToken = generateToken();
  const refreshToken = generateToken();
  const accessHash = hashToken(accessToken);
  const refreshHash = hashToken(refreshToken);
  const expiresIn = TTL.access / 1000; // seconds

  const userId = await db.runTransaction(async (tx) => {
    const codeDoc = await tx.get(db.collection(COLLECTIONS.codes).doc(codeHash));
    if (!codeDoc.exists) throw new Error('Invalid authorization code');

    const data = codeDoc.data()!;
    if (data.expires_at.toMillis() < Date.now()) throw new Error('Authorization code expired');
    if (data.redirect_uri !== redirectUri) throw new Error('Redirect URI mismatch');

    // Delete code (single-use)
    tx.delete(codeDoc.ref);

    // Write access token
    const now = admin.firestore.Timestamp.now();
    tx.set(db.collection(COLLECTIONS.tokens).doc(accessHash), {
      user_id: data.user_id,
      type: 'access',
      expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.access),
      created_at: now,
      last_used_at: now,
      grace_until: null,
    });

    // Write refresh token
    tx.set(db.collection(COLLECTIONS.tokens).doc(refreshHash), {
      user_id: data.user_id,
      type: 'refresh',
      expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.refresh),
      created_at: now,
      last_used_at: now,
      grace_until: null,
    });

    return data.user_id;
  });

  return { userId, accessToken, refreshToken, expiresIn };
}
```

- [ ] **Step 4: Add refresh token rotation (transactional, with grace window)**

```typescript
/** Rotate refresh token. Uses runTransaction (S6). Grace window for retries. */
export async function rotateRefreshToken(
  oldRefreshToken: string,
): Promise<{ userId: string; accessToken: string; refreshToken: string; expiresIn: number }> {
  const oldHash = hashToken(oldRefreshToken);
  const newAccessToken = generateToken();
  const newRefreshToken = generateToken();
  const newAccessHash = hashToken(newAccessToken);
  const newRefreshHash = hashToken(newRefreshToken);
  const expiresIn = TTL.access / 1000;

  const userId = await db.runTransaction(async (tx) => {
    const oldDoc = await tx.get(db.collection(COLLECTIONS.tokens).doc(oldHash));
    if (!oldDoc.exists) throw new Error('Invalid refresh token');

    const data = oldDoc.data()!;
    if (data.type !== 'refresh') throw new Error('Token is not a refresh token');
    if (data.expires_at.toMillis() < Date.now()) {
      // Check grace window
      if (!data.grace_until || data.grace_until.toMillis() < Date.now()) {
        throw new Error('Refresh token expired');
      }
    }

    // Set grace window on old token (30s) instead of deleting immediately
    tx.update(oldDoc.ref, {
      grace_until: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.grace),
      expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.grace),
    });

    const now = admin.firestore.Timestamp.now();
    tx.set(db.collection(COLLECTIONS.tokens).doc(newAccessHash), {
      user_id: data.user_id,
      type: 'access',
      expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.access),
      created_at: now,
      last_used_at: now,
      grace_until: null,
    });

    tx.set(db.collection(COLLECTIONS.tokens).doc(newRefreshHash), {
      user_id: data.user_id,
      type: 'refresh',
      expires_at: admin.firestore.Timestamp.fromMillis(Date.now() + TTL.refresh),
      created_at: now,
      last_used_at: now,
      grace_until: null,
    });

    return data.user_id;
  });

  return { userId, accessToken: newAccessToken, refreshToken: newRefreshToken, expiresIn };
}
```

- [ ] **Step 5: Add access token verification and user token revocation**

```typescript
// In-memory debounce for last_used_at updates (per Cloud Run instance)
const lastWriteTimes = new Map<string, number>();

export async function verifyAccessToken(
  token: string,
): Promise<{ userId: string; expiresAt: number }> {
  const hash = hashToken(token);
  const doc = await db.collection(COLLECTIONS.tokens).doc(hash).get();
  if (!doc.exists) throw new Error('Invalid access token');

  const data = doc.data()!;
  if (data.type !== 'access') throw new Error('Token is not an access token');
  if (data.expires_at.toMillis() < Date.now()) throw new Error('Access token expired');

  // Debounced last_used_at update (5 min per instance)
  const lastWrite = lastWriteTimes.get(hash) || 0;
  if (Date.now() - lastWrite > 5 * 60 * 1000) {
    doc.ref.update({ last_used_at: admin.firestore.FieldValue.serverTimestamp() }).catch(() => {});
    lastWriteTimes.set(hash, Date.now());
  }

  return { userId: data.user_id, expiresAt: Math.floor(data.expires_at.toMillis() / 1000) };
}

/** Revoke all OAuth tokens, codes, and nonces for a user. Paginated (500 per batch). */
export async function revokeAllForUser(userId: string): Promise<number> {
  let deleted = 0;

  for (const collection of [COLLECTIONS.tokens, COLLECTIONS.codes]) {
    let hasMore = true;
    while (hasMore) {
      const snap = await db.collection(collection)
        .where('user_id', '==', userId)
        .limit(500)
        .get();

      if (snap.empty) { hasMore = false; break; }

      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
      deleted += snap.docs.length;

      if (snap.docs.length < 500) hasMore = false;
    }
  }

  return deleted;
}
```

- [ ] **Step 6: Verify build**

Run: `cd mcp_server && npx tsc --noEmit`
Expected: no type errors

- [ ] **Step 7: Commit**

```bash
git add mcp_server/src/tokens.ts
git commit -m "feat(mcp): add token utilities for OAuth 2.1

Nonce, auth code, and token CRUD backed by Firestore.
All write operations use runTransaction (S6).
Refresh token rotation with 30s grace window."
```

---

## Task 2: Client Store (`clients-store.ts`)

**Files:**
- Create: `mcp_server/src/clients-store.ts`

- [ ] **Step 1: Create hard-coded client store**

```typescript
// mcp_server/src/clients-store.ts
import type { OAuthRegisteredClientsStore } from '@modelcontextprotocol/sdk/server/auth/clients.js';
import type { OAuthClientInformationFull } from '@modelcontextprotocol/sdk/shared/auth.js';

// Claude Desktop's redirect URI — determine exact scheme from Claude Desktop docs.
// Placeholder until confirmed. Common patterns: http://localhost:PORT/callback or custom scheme.
const REGISTERED_CLIENTS: Record<string, OAuthClientInformationFull> = {
  'claude-desktop': {
    client_id: 'claude-desktop',
    redirect_uris: [new URL('http://localhost:0/callback')], // TODO: confirm from Claude Desktop docs
    token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
  },
};

export class PovverClientsStore implements OAuthRegisteredClientsStore {
  async getClient(clientId: string): Promise<OAuthClientInformationFull | undefined> {
    return REGISTERED_CLIENTS[clientId];
  }

  // No registerClient — dynamic registration not supported
}
```

- [ ] **Step 2: Verify build**

Run: `cd mcp_server && npx tsc --noEmit`

- [ ] **Step 3: Commit**

```bash
git add mcp_server/src/clients-store.ts
git commit -m "feat(mcp): add hard-coded OAuth client store for Claude Desktop"
```

---

## Task 3: Consent Page (`consent.ts`)

**Files:**
- Create: `mcp_server/src/consent.ts`

Generates branded HTML with Firebase Auth JS SDK. Nonce embedded as hidden field. OAuth params stored server-side (not in page).

- [ ] **Step 1: Create consent page HTML generator**

The consent page uses Firebase Auth JS SDK for Apple/Google/email sign-in. On approve, it POSTs to `/authorize/complete` with the Firebase ID token + nonce.

```typescript
// mcp_server/src/consent.ts

const FIREBASE_CONFIG = {
  apiKey: process.env.FIREBASE_API_KEY || '',
  // Use default Firebase Auth domain, not mcp.povver.ai — Firebase Auth
  // needs to host /__/auth/handler for popup/redirect flows
  authDomain: 'myon-53d85.firebaseapp.com',
  projectId: process.env.GOOGLE_CLOUD_PROJECT || 'myon-53d85',
};

export function renderConsentPage(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Connect to Povver</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
      background: #0A0E14;
      color: #EAEEF3;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .container {
      max-width: 400px;
      width: 100%;
      padding: 40px 24px;
      text-align: center;
    }
    .logo {
      font-size: 32px;
      font-weight: 600;
      color: #22C59A;
      margin-bottom: 32px;
    }
    h1 {
      font-size: 20px;
      font-weight: 500;
      line-height: 1.4;
      margin-bottom: 8px;
    }
    .subtitle {
      color: rgba(255,255,255,0.55);
      font-size: 14px;
      margin-bottom: 32px;
    }
    .btn {
      display: block;
      width: 100%;
      padding: 14px;
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: 10px;
      background: #111820;
      color: #EAEEF3;
      font-size: 15px;
      font-family: inherit;
      cursor: pointer;
      margin-bottom: 12px;
      transition: background 0.15s;
    }
    .btn:hover { background: #1a2230; }
    .btn-approve {
      background: #22C59A;
      color: #0A0E14;
      border-color: #22C59A;
      font-weight: 600;
      margin-top: 24px;
    }
    .btn-approve:hover { background: #1A9B79; }
    .consent-text {
      color: rgba(255,255,255,0.55);
      font-size: 13px;
      margin-top: 16px;
      line-height: 1.5;
    }
    .error { color: #ff6b6b; font-size: 14px; margin-top: 12px; display: none; }
    .step { display: none; }
    .step.active { display: block; }
    .spinner {
      display: inline-block;
      width: 20px; height: 20px;
      border: 2px solid rgba(255,255,255,0.2);
      border-top-color: #22C59A;
      border-radius: 50%;
      animation: spin 0.6s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .email-form input {
      display: block;
      width: 100%;
      padding: 12px;
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: 8px;
      background: #111820;
      color: #EAEEF3;
      font-size: 15px;
      font-family: inherit;
      margin-bottom: 12px;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">Povver</div>

    <!-- Step 1: Sign in -->
    <div id="step-signin" class="step active">
      <h1>Sign in to connect your training data to Claude</h1>
      <p class="subtitle">Use the same account you use in the Povver app</p>
      <button class="btn" id="btn-apple"> Apple</button>
      <button class="btn" id="btn-google"> Google</button>
      <button class="btn" id="btn-email">Email</button>
      <div id="email-form" class="email-form" style="display:none;">
        <input type="email" id="email" placeholder="Email" autocomplete="email">
        <input type="password" id="password" placeholder="Password" autocomplete="current-password">
        <button class="btn" id="btn-email-submit">Sign in</button>
      </div>
      <div id="error-signin" class="error"></div>
    </div>

    <!-- Step 2: Consent -->
    <div id="step-consent" class="step">
      <h1>Allow Claude to access your Povver data?</h1>
      <p class="consent-text">
        Claude will be able to read and modify your routines, templates, and workout data.
      </p>
      <button class="btn btn-approve" id="btn-approve">Allow access</button>
      <button class="btn" id="btn-deny">Cancel</button>
      <div id="error-consent" class="error"></div>
    </div>

    <!-- Step 3: Redirecting -->
    <div id="step-redirect" class="step">
      <div class="spinner"></div>
      <p class="subtitle" style="margin-top:16px;">Redirecting to Claude...</p>
    </div>
  </div>

  <script type="module">
    import { initializeApp } from 'https://www.gstatic.com/firebasejs/11.0.1/firebase-app.js';
    import { getAuth, signInWithPopup, signInWithEmailAndPassword, GoogleAuthProvider, OAuthProvider }
      from 'https://www.gstatic.com/firebasejs/11.0.1/firebase-auth.js';

    const app = initializeApp(${JSON.stringify(FIREBASE_CONFIG)});
    const auth = getAuth(app);
    const NONCE = ${JSON.stringify(nonce)};

    function showStep(id) {
      document.querySelectorAll('.step').forEach(s => s.classList.remove('active'));
      document.getElementById(id).classList.add('active');
    }
    function showError(stepId, msg) {
      const el = document.getElementById('error-' + stepId);
      el.textContent = msg;
      el.style.display = 'block';
    }

    let idToken = null;

    // Check if already signed in
    auth.onAuthStateChanged(async (user) => {
      if (user && !idToken) {
        idToken = await user.getIdToken();
        showStep('step-consent');
      }
    });

    // Apple
    document.getElementById('btn-apple').onclick = async () => {
      try {
        const provider = new OAuthProvider('apple.com');
        provider.addScope('email');
        provider.addScope('name');
        const result = await signInWithPopup(auth, provider);
        idToken = await result.user.getIdToken();
        showStep('step-consent');
      } catch (e) { showError('signin', e.message); }
    };

    // Google
    document.getElementById('btn-google').onclick = async () => {
      try {
        const result = await signInWithPopup(auth, new GoogleAuthProvider());
        idToken = await result.user.getIdToken();
        showStep('step-consent');
      } catch (e) { showError('signin', e.message); }
    };

    // Email toggle
    document.getElementById('btn-email').onclick = () => {
      document.getElementById('email-form').style.display = 'block';
    };

    // Email submit
    document.getElementById('btn-email-submit').onclick = async () => {
      try {
        const email = document.getElementById('email').value;
        const password = document.getElementById('password').value;
        const result = await signInWithEmailAndPassword(auth, email, password);
        idToken = await result.user.getIdToken();
        showStep('step-consent');
      } catch (e) { showError('signin', e.message); }
    };

    // Approve
    document.getElementById('btn-approve').onclick = async () => {
      try {
        showStep('step-redirect');
        const res = await fetch('/authorize/complete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ id_token: idToken, nonce: NONCE }),
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error_description || data.error || 'Authorization failed');
        window.location.href = data.redirect_url;
      } catch (e) {
        showStep('step-consent');
        showError('consent', e.message);
      }
    };

    // Deny — redirect back with error per OAuth 2.1 spec
    document.getElementById('btn-deny').onclick = async () => {
      try {
        // Consume nonce to get redirect_uri, then redirect with error
        const res = await fetch('/authorize/deny', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ nonce: NONCE }),
        });
        const data = await res.json();
        if (data.redirect_url) {
          window.location.href = data.redirect_url;
        } else {
          window.close();
        }
      } catch (e) {
        window.close();
      }
    };
  </script>
</body>
</html>`;
}
```

- [ ] **Step 2: Verify build**

Run: `cd mcp_server && npx tsc --noEmit`

- [ ] **Step 3: Commit**

```bash
git add mcp_server/src/consent.ts
git commit -m "feat(mcp): add branded consent page for OAuth authorization"
```

---

## Task 4: OAuth Provider (`oauth-provider.ts`)

**Files:**
- Create: `mcp_server/src/oauth-provider.ts`

Implements the SDK's `OAuthServerProvider` interface. Delegates to `tokens.ts` for storage.

- [ ] **Step 1: Create the OAuth provider**

```typescript
// mcp_server/src/oauth-provider.ts
import type { Response } from 'express';
import type { OAuthServerProvider, AuthorizationParams } from '@modelcontextprotocol/sdk/server/auth/provider.js';
import type { OAuthRegisteredClientsStore } from '@modelcontextprotocol/sdk/server/auth/clients.js';
import type { OAuthClientInformationFull, OAuthTokens, OAuthTokenRevocationRequest } from '@modelcontextprotocol/sdk/shared/auth.js';
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js';
import admin from 'firebase-admin';
import { PovverClientsStore } from './clients-store.js';
import {
  generateNonce, generateCode, storeNonce, consumeNonce,
  storeAuthCode, getCodeChallenge, exchangeCode,
  rotateRefreshToken, verifyAccessToken as verifyToken,
  revokeAllForUser, hashToken,
} from './tokens.js';
import { renderConsentPage } from './consent.js';
import { authenticateApiKey } from './auth.js';

export class PovverOAuthProvider implements OAuthServerProvider {
  get clientsStore(): OAuthRegisteredClientsStore {
    return new PovverClientsStore();
  }

  /**
   * Called by SDK on GET /authorize.
   * Generates nonce, stores in Firestore, serves consent page.
   */
  async authorize(
    client: OAuthClientInformationFull,
    params: AuthorizationParams,
    res: Response,
  ): Promise<void> {
    const nonce = generateNonce();

    await storeNonce(nonce, {
      client_id: client.client_id,
      redirect_uri: params.redirectUri,
      state: params.state,
      code_challenge: params.codeChallenge,
      code_challenge_method: 'S256',
    });

    res.setHeader('Content-Type', 'text/html');
    res.end(renderConsentPage(nonce));
  }

  /**
   * Called by SDK to get PKCE challenge for a code.
   */
  async challengeForAuthorizationCode(
    _client: OAuthClientInformationFull,
    authorizationCode: string,
  ): Promise<string> {
    return getCodeChallenge(authorizationCode);
  }

  /**
   * Called by SDK on POST /token with grant_type=authorization_code.
   * SDK already validated PKCE.
   */
  async exchangeAuthorizationCode(
    _client: OAuthClientInformationFull,
    authorizationCode: string,
    _codeVerifier?: string,
    redirectUri?: string,
    _resource?: URL,
  ): Promise<OAuthTokens> {
    const result = await exchangeCode(authorizationCode, redirectUri || '');
    return {
      access_token: result.accessToken,
      token_type: 'bearer',
      expires_in: result.expiresIn,
      refresh_token: result.refreshToken,
    };
  }

  /**
   * Called by SDK on POST /token with grant_type=refresh_token.
   */
  async exchangeRefreshToken(
    _client: OAuthClientInformationFull,
    refreshToken: string,
    _scopes?: string[],
    _resource?: URL,
  ): Promise<OAuthTokens> {
    const result = await rotateRefreshToken(refreshToken);
    return {
      access_token: result.accessToken,
      token_type: 'bearer',
      expires_in: result.expiresIn,
      refresh_token: result.refreshToken,
    };
  }

  /**
   * Called by SDK on every MCP request via Bearer auth middleware.
   * Routes by token prefix: pvt_ → OAuth, pvk_/none → API key.
   */
  async verifyAccessToken(token: string): Promise<AuthInfo> {
    // OAuth token path
    if (token.startsWith('pvt_')) {
      const { userId, expiresAt } = await verifyToken(token);

      // Premium check
      const userDoc = await admin.firestore().doc(`users/${userId}`).get();
      if (!userDoc.exists) throw new Error('User not found');
      const userData = userDoc.data()!;
      const isPremium = userData.subscription_override === 'premium'
                     || userData.subscription_tier === 'premium';
      if (!isPremium) throw new Error('Premium subscription required for MCP access');

      return {
        token,
        clientId: 'claude-desktop',
        scopes: [],
        expiresAt,
        extra: { userId },
      };
    }

    // API key path (pvk_ prefix or no prefix = legacy)
    const rawKey = token.startsWith('pvk_') ? token : token;
    const auth = await authenticateApiKey(rawKey);
    return {
      token,
      clientId: 'api-key',
      scopes: [],
      extra: { userId: auth.userId },
    };
  }

  /**
   * Called on POST /authorize/complete (custom endpoint, not SDK-routed).
   * Validates nonce + Firebase ID token, generates auth code, returns redirect URL.
   */
  async completeAuthorization(
    idToken: string,
    nonce: string,
  ): Promise<{ redirectUrl: string }> {
    // Validate nonce
    const nonceData = await consumeNonce(nonce);
    if (!nonceData) throw new Error('Invalid or expired nonce');

    // Validate Firebase ID token
    const decoded = await admin.auth().verifyIdToken(idToken);
    const userId = decoded.uid;

    // Revoke existing tokens (prevent accumulation)
    await revokeAllForUser(userId);

    // Generate auth code
    const code = generateCode();
    await storeAuthCode(code, userId, nonceData.code_challenge, nonceData.redirect_uri);

    // Build redirect URL
    const redirectUrl = new URL(nonceData.redirect_uri);
    redirectUrl.searchParams.set('code', code);
    if (nonceData.state) redirectUrl.searchParams.set('state', nonceData.state);

    return { redirectUrl: redirectUrl.toString() };
  }
}
```

- [ ] **Step 2: Verify build**

Run: `cd mcp_server && npx tsc --noEmit`

- [ ] **Step 3: Commit**

```bash
git add mcp_server/src/oauth-provider.ts
git commit -m "feat(mcp): implement OAuthServerProvider backed by Firestore

Implements authorize, token exchange, refresh rotation,
access token verification with prefix-based routing,
and custom /authorize/complete flow with nonce CSRF protection."
```

---

## Task 5: Express Migration + Wiring (`index.ts`)

**Files:**
- Modify: `mcp_server/src/index.ts`
- Modify: `mcp_server/src/auth.ts` (minor: ensure `authenticateApiKey` is exported correctly for the provider)

Migrate from `http.createServer()` to Express. Mount the SDK's `mcpAuthRouter()` and the custom `/authorize/complete` endpoint.

- [ ] **Step 1: Rewrite `index.ts` with Express + SDK auth router**

Read current `mcp_server/src/index.ts` first. Then rewrite:

```typescript
// mcp_server/src/index.ts
import express from 'express';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { mcpAuthRouter } from '@modelcontextprotocol/sdk/server/auth/router.js';
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js';
import { PovverOAuthProvider } from './oauth-provider.js';
import { consumeNonce } from './tokens.js';
import { registerTools } from './tools.js';

const PORT = parseInt(process.env.PORT || '8080');
const ISSUER_URL = new URL(process.env.MCP_ISSUER_URL || 'https://mcp.povver.ai');

const provider = new PovverOAuthProvider();

const app = express();

// Health check (unauthenticated)
app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

// Mount SDK OAuth router (handles /.well-known/*, /authorize, /token, /register)
app.use(mcpAuthRouter({
  provider,
  issuerUrl: ISSUER_URL,
}));

// Rate limiter for custom OAuth endpoints (10 requests per minute per IP)
import rateLimit from 'express-rate-limit';
const oauthEndpointLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'rate_limited', error_description: 'Too many requests' },
});

// Custom endpoint: consent page completion
app.post('/authorize/complete', oauthEndpointLimiter, express.json(), async (req, res) => {
  try {
    const { id_token, nonce } = req.body;
    if (!id_token || typeof id_token !== 'string' || !nonce || typeof nonce !== 'string' || nonce.length > 64) {
      res.status(400).json({ error: 'invalid_request', error_description: 'Missing or invalid id_token or nonce' });
      return;
    }
    const result = await provider.completeAuthorization(id_token, nonce);
    res.json({ redirect_url: result.redirectUrl });
  } catch (e: any) {
    res.status(400).json({ error: 'access_denied', error_description: e.message });
  }
});

// Custom endpoint: consent page denial (redirects with error)
app.post('/authorize/deny', oauthEndpointLimiter, express.json(), async (req, res) => {
  try {
    const { nonce } = req.body;
    if (!nonce || typeof nonce !== 'string' || nonce.length > 64) {
      res.status(400).json({ error: 'invalid_request' });
      return;
    }
    const nonceData = await consumeNonce(nonce);
    if (!nonceData) {
      res.status(400).json({ error: 'invalid_request', error_description: 'Invalid or expired nonce' });
      return;
    }
    const redirectUrl = new URL(nonceData.redirect_uri);
    redirectUrl.searchParams.set('error', 'access_denied');
    if (nonceData.state) redirectUrl.searchParams.set('state', nonceData.state);
    res.json({ redirect_url: redirectUrl.toString() });
  } catch (e: any) {
    res.status(400).json({ error: 'server_error', error_description: e.message });
  }
});

// MCP endpoint (Bearer auth required)
const bearerAuth = requireBearerAuth({ verifier: provider });

app.post('/mcp', bearerAuth, async (req, res) => {
  const authInfo = (req as any).auth as import('@modelcontextprotocol/sdk/server/auth/types.js').AuthInfo;
  const userId = (authInfo.extra as any)?.userId;

  if (!userId) {
    res.status(401).json({ error: 'Authentication failed' });
    return;
  }

  const server = new McpServer({ name: 'povver', version: '1.0.0' });
  registerTools(server, userId);

  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  await server.connect(transport);
  await transport.handleRequest(req, res);
});

app.listen(PORT, () => {
  console.log(`MCP server listening on port ${PORT}`);
});
```

Note: The `requireBearerAuth` middleware calls `provider.verifyAccessToken()` which handles both OAuth tokens (`pvt_`) and API keys (`pvk_`/legacy). The `authInfo.extra.userId` is set by the provider for both paths.

- [ ] **Step 2: Add `express` as direct dependency**

First, pin the MCP SDK to `^1.27.1` in `package.json` (current `^1.0.0` is too loose and could resolve to a version without the OAuth module on a fresh install).

Run: `cd mcp_server && npm install @modelcontextprotocol/sdk@^1.27.1 express express-rate-limit`

Express 5 is already transitively installed via the SDK, but adding it as a direct dependency prevents breakage if the SDK changes its dependency tree. Express 5 bundles its own types — `@types/express` is not needed. `express-rate-limit` is used for the custom OAuth endpoints.

- [ ] **Step 3: Verify build**

Run: `cd mcp_server && npx tsc --noEmit`

Fix any type errors. Common issue: Express 5 types may differ from Express 4 types. The SDK uses Express 5.

- [ ] **Step 4: Test locally**

Run: `cd mcp_server && npm run dev`

Verify:
- `GET http://localhost:8080/health` → `{ "status": "ok" }`
- `GET http://localhost:8080/.well-known/oauth-authorization-server` → metadata JSON
- `POST http://localhost:8080/mcp` without auth → 401

- [ ] **Step 5: Commit**

```bash
git add mcp_server/src/index.ts mcp_server/src/auth.ts mcp_server/package.json mcp_server/package-lock.json
git commit -m "feat(mcp): migrate to Express + SDK OAuth auth router

Replaces http.createServer() with Express.
Mounts mcpAuthRouter() for OAuth 2.1 endpoints.
Custom /authorize/complete for consent page flow.
Bearer auth middleware on /mcp with dual auth (OAuth + API key)."
```

---

## Task 6: Firestore Rules & Indexes

**Files:**
- Modify: `firebase_functions/firestore.rules`
- Modify: `firebase_functions/firestore.indexes.json`

- [ ] **Step 1: Add deny-all rules for new collections**

Read `firebase_functions/firestore.rules`. Find the `mcp_api_keys` rule block (around line 164-167). Add the three new collections immediately after:

```
// MCP OAuth nonces — server-only (Admin SDK reads/writes)
match /mcp_oauth_nonces/{doc} {
  allow read, write: if false;
}

// MCP OAuth codes — server-only (Admin SDK reads/writes)
match /mcp_oauth_codes/{doc} {
  allow read, write: if false;
}

// MCP OAuth tokens — server-only (Admin SDK reads/writes)
match /mcp_tokens/{doc} {
  allow read, write: if false;
}
```

- [ ] **Step 2: Add composite index for `mcp_tokens`**

Read `firebase_functions/firestore.indexes.json`. Add to the `indexes` array:

```json
{
  "collectionGroup": "mcp_tokens",
  "queryScope": "COLLECTION",
  "fields": [
    { "fieldPath": "user_id", "order": "ASCENDING" },
    { "fieldPath": "type", "order": "ASCENDING" }
  ]
}
```

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/firestore.rules firebase_functions/firestore.indexes.json
git commit -m "feat(mcp): add Firestore rules and indexes for OAuth collections

Deny-all for mcp_oauth_nonces, mcp_oauth_codes, mcp_tokens.
Composite index on mcp_tokens (user_id + type)."
```

---

## Task 7: Firebase Functions — Connection Status & Revoke

**Files:**
- Create: `firebase_functions/functions/mcp/get-connection-status.js`
- Create: `firebase_functions/functions/mcp/revoke-tokens.js`
- Modify: `firebase_functions/functions/index.js`

- [ ] **Step 1: Create `get-connection-status.js`**

Follow the existing pattern from `mcp/list-api-keys.js`:

```javascript
// firebase_functions/functions/mcp/get-connection-status.js
const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ok, fail } = require('../utils/response');

const db = admin.firestore();

const getMcpConnectionStatus = onRequest({ region: 'us-central1' },
  requireFlexibleAuth(async (req, res) => {
    if (req.method !== 'GET' && req.method !== 'POST') {
      return fail(res, 'METHOD_NOT_ALLOWED', 'GET or POST required', null, 405);
    }

    const userId = getAuthenticatedUserId(req);
    if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);

    // Check for any non-expired token (access OR refresh).
    // A user with an expired access token but valid refresh token is still connected
    // (Claude Desktop will refresh automatically).
    const snap = await db.collection('mcp_tokens')
      .where('user_id', '==', userId)
      .limit(10)
      .get();

    if (snap.empty) {
      return ok(res, { connected: false, last_used_at: null });
    }

    const now = Date.now();
    let connected = false;
    let lastUsedAt = null;

    for (const doc of snap.docs) {
      const data = doc.data();
      const isExpired = data.expires_at && data.expires_at.toMillis() < now;
      if (!isExpired) connected = true;
      // Track most recent last_used_at across all tokens
      if (data.last_used_at) {
        const ts = data.last_used_at.toDate().toISOString();
        if (!lastUsedAt || ts > lastUsedAt) lastUsedAt = ts;
      }
    }

    return ok(res, { connected, last_used_at: lastUsedAt });
  })
);

module.exports = { getMcpConnectionStatus };
```

- [ ] **Step 2: Create `revoke-tokens.js`**

```javascript
// firebase_functions/functions/mcp/revoke-tokens.js
const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ok, fail } = require('../utils/response');

const db = admin.firestore();

const { logger } = require('firebase-functions');

const revokeMcpTokens = onRequest({ region: 'us-central1' },
  requireFlexibleAuth(async (req, res) => {
    if (req.method !== 'POST') {
      return fail(res, 'METHOD_NOT_ALLOWED', 'POST required', null, 405);
    }

    const userId = getAuthenticatedUserId(req);
    if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);

    let deleted = 0;

    // Only query collections that have user_id field (nonces are keyed by nonce value, no user_id)
    // Paginate at 500 (Firestore batch limit)
    for (const collection of ['mcp_tokens', 'mcp_oauth_codes']) {
      let hasMore = true;
      while (hasMore) {
        const snap = await db.collection(collection)
          .where('user_id', '==', userId)
          .limit(500)
          .get();

        if (snap.empty) { hasMore = false; break; }

        const batch = db.batch();
        snap.docs.forEach((doc) => batch.delete(doc.ref));
        await batch.commit();
        deleted += snap.docs.length;

        if (snap.docs.length < 500) hasMore = false;
      }
    }

    logger.info('MCP tokens revoked', { userId, deleted });
    return ok(res, { revoked: true, deleted });
  })
);

module.exports = { revokeMcpTokens };
```

- [ ] **Step 3: Export from `index.js`**

Read `firebase_functions/functions/index.js`. Find the MCP section (around line 120-123 for imports, 312-317 for exports). Add:

```javascript
// Imports (near line 123)
const { getMcpConnectionStatus } = require('./mcp/get-connection-status');
const { revokeMcpTokens } = require('./mcp/revoke-tokens');

// Exports (near line 317)
exports.getMcpConnectionStatus = getMcpConnectionStatus;
exports.revokeMcpTokens = revokeMcpTokens;
```

- [ ] **Step 4: Test locally**

Run: `cd firebase_functions/functions && npm test`

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/mcp/get-connection-status.js firebase_functions/functions/mcp/revoke-tokens.js firebase_functions/functions/index.js
git commit -m "feat(mcp): add getMcpConnectionStatus and revokeMcpTokens endpoints

Bearer-lane endpoints for iOS settings UI.
Connection status queries mcp_tokens server-side.
Revoke deletes all OAuth tokens/codes for the user."
```

---

## Task 8: API Key Prefix Migration

**Files:**
- Modify: `firebase_functions/functions/mcp/generate-api-key.js`

- [ ] **Step 1: Update key generation to use `pvk_` prefix**

Read `firebase_functions/functions/mcp/generate-api-key.js`. Find the key generation line (around line 58):

```javascript
// Before:
const rawKey = crypto.randomBytes(32).toString('hex');

// After:
const rawKey = 'pvk_' + crypto.randomBytes(32).toString('hex');
```

The hash is computed from the full prefixed key, so existing unprefixed keys remain valid (they go through the "no prefix = legacy" path in the MCP server's `verifyAccessToken`).

- [ ] **Step 2: Commit**

```bash
git add firebase_functions/functions/mcp/generate-api-key.js
git commit -m "feat(mcp): prefix new API keys with pvk_ for auth routing"
```

---

## Task 9: Cleanup Scheduled Function

**Files:**
- Create: `firebase_functions/functions/triggers/cleanup-mcp-tokens.js`
- Modify: `firebase_functions/functions/index.js`

- [ ] **Step 1: Create cleanup function**

```javascript
// firebase_functions/functions/triggers/cleanup-mcp-tokens.js
const { onSchedule } = require('firebase-functions/v2/scheduler');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

const db = admin.firestore();

const cleanupMcpTokens = onSchedule({
  schedule: 'every 24 hours',
  region: 'us-central1',
  timeoutSeconds: 120,
}, async () => {
  const now = admin.firestore.Timestamp.now();
  let totalDeleted = 0;

  for (const collection of ['mcp_oauth_nonces', 'mcp_oauth_codes', 'mcp_tokens']) {
    let hasMore = true;
    while (hasMore) {
      const snap = await db.collection(collection)
        .where('expires_at', '<', now)
        .limit(500)
        .get();

      if (snap.empty) {
        hasMore = false;
        break;
      }

      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
      totalDeleted += snap.docs.length;

      if (snap.docs.length < 500) hasMore = false;
    }
  }

  logger.info(`MCP token cleanup: deleted ${totalDeleted} expired documents`);
});

module.exports = { cleanupMcpTokens };
```

- [ ] **Step 2: Export from `index.js`**

```javascript
const { cleanupMcpTokens } = require('./triggers/cleanup-mcp-tokens');
exports.cleanupMcpTokens = cleanupMcpTokens;
```

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/triggers/cleanup-mcp-tokens.js firebase_functions/functions/index.js
git commit -m "feat(mcp): add daily cleanup for expired OAuth tokens/codes/nonces"
```

---

## Task 10: Account Deletion Cleanup

**Files:**
- Modify: `firebase_functions/functions/user/delete-account.js`

When a user deletes their account, orphaned OAuth tokens/codes in root collections must be cleaned up. Without this, tokens remain valid until expiry and could authenticate against the MCP server for a deleted user.

- [ ] **Step 1: Add OAuth token cleanup to `deleteAccount`**

Read `firebase_functions/functions/user/delete-account.js`. Find where user subcollections are deleted. Add cleanup for root-level OAuth collections:

```javascript
// After existing subcollection cleanup, before deleting the user doc:

// Clean up MCP OAuth tokens and codes (root collections, keyed by user_id)
for (const collection of ['mcp_tokens', 'mcp_oauth_codes']) {
  let hasMore = true;
  while (hasMore) {
    const snap = await db.collection(collection)
      .where('user_id', '==', userId)
      .limit(500)
      .get();
    if (snap.empty) { hasMore = false; break; }
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    if (snap.docs.length < 500) hasMore = false;
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add firebase_functions/functions/user/delete-account.js
git commit -m "fix(mcp): clean up OAuth tokens on account deletion"
```

---

## Task 11: iOS — ClaudeConnectionViewModel

**Files:**
- Create: `Povver/Povver/ViewModels/ClaudeConnectionViewModel.swift`

- [ ] **Step 1: Create the ViewModel**

```swift
// Povver/Povver/ViewModels/ClaudeConnectionViewModel.swift
import Foundation

enum ClaudeConnectionState {
    case loading
    case notConnected
    case connected(lastUsedAt: Date?)
    case disabled // not premium
}

@MainActor
final class ClaudeConnectionViewModel: ObservableObject {
    @Published var state: ClaudeConnectionState = .loading
    @Published var errorMessage: String?
    @Published var isDisconnecting = false

    private let subscriptionService = SubscriptionService.shared

    func checkStatus() async {
        guard subscriptionService.isPremium else {
            state = .disabled
            return
        }

        do {
            let response: McpConnectionStatusResponse = try await ApiClient.shared.postJSON(
                endpoint: "getMcpConnectionStatus",
                body: [String: String]()
            )
            if response.data.connected {
                let lastUsed = response.data.lastUsedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                state = .connected(lastUsedAt: lastUsed)
            } else {
                state = .notConnected
            }
        } catch {
            state = .notConnected
        }
    }

    func disconnect() async {
        isDisconnecting = true
        defer { isDisconnecting = false }

        do {
            let _: McpRevokeResponse = try await ApiClient.shared.postJSON(
                endpoint: "revokeMcpTokens",
                body: [String: String]()
            )
            state = .notConnected
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Response types

private struct McpConnectionStatusData: Decodable {
    let connected: Bool
    let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case connected
        case lastUsedAt = "last_used_at"
    }
}

private struct McpConnectionStatusResponse: Decodable {
    let success: Bool
    let data: McpConnectionStatusData
}

private struct McpRevokeData: Decodable {
    let revoked: Bool
}

private struct McpRevokeResponse: Decodable {
    let success: Bool
    let data: McpRevokeData
}
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/ViewModels/ClaudeConnectionViewModel.swift
git commit -m "feat(ios): add ClaudeConnectionViewModel for MCP connection management"
```

---

## Task 12: iOS — Claude Connection Section UI

**Files:**
- Create: `Povver/Povver/Views/Settings/ClaudeConnectionSection.swift`
- Modify: `Povver/Povver/Views/Settings/ConnectedAppsView.swift`

- [ ] **Step 1: Create `ClaudeConnectionSection.swift`**

Follow design tokens from existing `ConnectedAppsView.swift` (uses `Space.*`, `Color.*`, `CornerRadiusToken.*`, `.textStyle()`).

```swift
// Povver/Povver/Views/Settings/ClaudeConnectionSection.swift
import SwiftUI

struct ClaudeConnectionSection: View {
    @StateObject private var viewModel = ClaudeConnectionViewModel()
    @State private var showDisconnectAlert = false

    private let mcpUrl = "https://mcp.povver.ai"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Header
            HStack(spacing: Space.sm) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20))
                    .foregroundColor(Color.accent)
                    .frame(width: 32, height: 32)
                    .background(Color.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))

                Text("Claude Desktop")
                    .textStyle(.body)
                    .foregroundColor(Color.textPrimary)

                Spacer()

                statusBadge
            }

            switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)

            case .notConnected:
                notConnectedContent

            case .connected(let lastUsedAt):
                connectedContent(lastUsedAt: lastUsedAt)

            case .disabled:
                disabledContent
            }
        }
        .padding(Space.lg)
        .background(Color.surface.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .task { await viewModel.checkStatus() }
        .alert("Disconnect Claude?", isPresented: $showDisconnectAlert) {
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude Desktop will lose access to your training data. You can reconnect anytime.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.state {
        case .connected:
            HStack(spacing: 4) {
                Circle().fill(Color.accent).frame(width: 8, height: 8)
                Text("Connected").textStyle(.caption).foregroundColor(Color.accent)
            }
        case .disabled:
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("Disabled").textStyle(.caption).foregroundColor(Color.orange)
            }
        default:
            EmptyView()
        }
    }

    private var notConnectedContent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                instructionRow(number: "1", text: "Open Claude Desktop → Settings → Connectors → Add custom connector")
                instructionRow(number: "2", text: "Name: Povver, URL: \(mcpUrl)")
                instructionRow(number: "3", text: "Click Add, then sign in with your Povver account")
            }

            Button {
                UIPasteboard.general.string = mcpUrl
            } label: {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy URL")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.sm)
                .background(Color.surface.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .foregroundColor(Color.accent)
        }
    }

    private func connectedContent(lastUsedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let lastUsed = lastUsedAt {
                Text("Last used \(lastUsed, style: .relative) ago")
                    .textStyle(.caption)
                    .foregroundColor(Color.textSecondary)
            }

            Button {
                showDisconnectAlert = true
            } label: {
                HStack {
                    if viewModel.isDisconnecting {
                        ProgressView().tint(Color.destructive)
                    }
                    Text("Disconnect")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.sm)
                .background(Color.destructive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .foregroundColor(Color.destructive)
            .disabled(viewModel.isDisconnecting)
        }
    }

    private var disabledContent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Premium subscription required to use Claude Desktop with Povver.")
                .textStyle(.caption)
                .foregroundColor(Color.textSecondary)

            Button {
                // Present paywall — follow existing pattern in the codebase
            } label: {
                Text("Upgrade")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
                    .background(Color.accent)
                    .foregroundColor(Color.bg)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                    .fontWeight(.semibold)
            }
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Text(number)
                .textStyle(.caption)
                .foregroundColor(Color.accent)
                .frame(width: 20)
            Text(text)
                .textStyle(.caption)
                .foregroundColor(Color.textSecondary)
        }
    }
}
```

- [ ] **Step 2: Add section to `ConnectedAppsView.swift`**

Read `Povver/Povver/Views/Settings/ConnectedAppsView.swift`. Add `ClaudeConnectionSection()` above the existing API Keys section. The exact insertion point depends on the current layout, but it should be the first content section after the premium gate.

```swift
// Add at the top of the VStack content, before the API keys section:
ClaudeConnectionSection()

Divider()
    .background(Color.textTertiary.opacity(0.3))
    .padding(.vertical, Space.sm)

// ... existing API Keys section continues below
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Views/Settings/ClaudeConnectionSection.swift Povver/Povver/Views/Settings/ConnectedAppsView.swift
git commit -m "feat(ios): add Claude Desktop connection section in settings

Shows connection status, setup instructions, and disconnect flow.
Premium gate shows upgrade button for non-premium users."
```

---

## Task 13: Documentation Updates

**Files:**
- Modify: `docs/FIRESTORE_SCHEMA.md`
- Modify: `docs/SYSTEM_ARCHITECTURE.md`
- Modify: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
- Modify: `docs/SECURITY.md`

- [ ] **Step 1: Update `docs/FIRESTORE_SCHEMA.md`**

Add after the `mcp_api_keys` section:

```markdown
### mcp_oauth_nonces/{nonce}
Temporary session nonces for CSRF protection during OAuth consent flow. Server-only (Admin SDK).

- `client_id: string` — OAuth client ID
- `redirect_uri: string` — OAuth redirect URI
- `state?: string` — OAuth state parameter
- `code_challenge: string` — PKCE S256 challenge
- `code_challenge_method: string` — Always `"S256"`
- `expires_at: Timestamp` — 10 minutes from creation
- `created_at: Timestamp`

### mcp_oauth_codes/{code_hash}
Temporary, single-use authorization codes. Server-only (Admin SDK). SHA-256 hash of code as document ID.

- `user_id: string` — Firebase Auth UID
- `code_challenge: string` — PKCE S256 challenge
- `redirect_uri: string` — Must match on token exchange
- `expires_at: Timestamp` — 5 minutes from creation
- `created_at: Timestamp`

### mcp_tokens/{token_hash}
OAuth access and refresh tokens. Server-only (Admin SDK). SHA-256 hash of token as document ID.

- `user_id: string` — Firebase Auth UID
- `type: string` — `"access"` or `"refresh"`
- `expires_at: Timestamp` — 1h (access) or 90d (refresh)
- `created_at: Timestamp`
- `last_used_at: Timestamp` — Debounced ~5min updates
- `grace_until: Timestamp | null` — For rotated refresh tokens (30s grace window)
```

- [ ] **Step 2: Update `docs/SYSTEM_ARCHITECTURE.md`**

Find the MCP server box in the layer map (around line 54-56). Change:

```
│  │ MCP Server (mcp_server/) — Cloud Run, Node.js/TypeScript               │
│  │  Premium-gated API key auth, imports shared Firebase Functions logic    │
```

to:

```
│  │ MCP Server (mcp_server/) — Cloud Run, Node.js/TypeScript               │
│  │  Premium-gated dual auth (API key + OAuth 2.1 for Claude Desktop)      │
```

- [ ] **Step 3: Update `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`**

Add to the MCP API Keys table (around line 52):

```markdown
| **MCP OAuth** | `getMcpConnectionStatus`, `revokeMcpTokens`, `cleanupMcpTokens` | Flexible / Scheduled |
```

- [ ] **Step 4: Update `docs/SECURITY.md`**

Add after the CORS section (around line 67):

```markdown
### Browser Client Surface (Consent Page)

The MCP OAuth consent page at `mcp.povver.ai` is a browser client using Firebase Auth JS SDK. This is the only browser-facing surface in the system.

- **CORS**: Same-origin (consent page + `/authorize/complete` both on `mcp.povver.ai`). No CORS headers needed.
- **CSRF**: Server-generated nonce stored in Firestore, embedded in consent page, validated server-side. Single-use, 10-minute TTL.
- **Token type enforcement**: Access tokens (`type === "access"`) validated on MCP requests. Refresh tokens (`type === "refresh"`) validated on refresh. Prevents 90-day refresh token from being used as 1-hour access token.
- **Firebase API key in browser**: The consent page embeds `FIREBASE_API_KEY` in the HTML source. This is standard practice for Firebase browser clients — the key is restricted to authorized domains and Firebase Auth operations only. It is NOT a server secret despite being stored as an env var for deployment convenience.
```

- [ ] **Step 5: Commit**

```bash
git add docs/FIRESTORE_SCHEMA.md docs/SYSTEM_ARCHITECTURE.md docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md docs/SECURITY.md
git commit -m "docs: update architecture docs for MCP OAuth 2.1

Add 3 new Firestore collections, update MCP server description,
document new Firebase Functions, note browser client surface."
```

---

## Task 14: Custom Domain Setup (Manual / Infra)

This task is manual infrastructure work, not code.

- [ ] **Step 1: Create Cloud Run domain mapping**

```bash
gcloud run domain-mappings create \
  --service mcp-server \
  --domain mcp.povver.ai \
  --region us-central1 \
  --project myon-53d85
```

Note the DNS records output.

- [ ] **Step 2: Add DNS records in Route 53**

SSH to configure or use AWS Console. Create the records shown by the `gcloud` output (likely A/AAAA records).

- [ ] **Step 3: Wait for SSL certificate provisioning**

Google automatically provisions and renews the SSL certificate. This can take up to 24 hours.

- [ ] **Step 4: Configure Firebase Auth authorized domains**

In Firebase Console → Authentication → Settings → Authorized domains, add `mcp.povver.ai`.

- [ ] **Step 5: Configure Apple Sign-In for web**

In Apple Developer Console:
1. Create a Services ID for web authentication
2. Add `mcp.povver.ai` as a verified domain
3. Register the return URL
4. Configure in Firebase Console → Authentication → Apple provider

- [ ] **Step 6: Configure Google Sign-In for web**

In Google Cloud Console → OAuth consent screen, add `mcp.povver.ai` to authorized domains.

- [ ] **Step 7: Set environment variables on Cloud Run**

```bash
gcloud run services update mcp-server \
  --set-env-vars "MCP_ISSUER_URL=https://mcp.povver.ai,FIREBASE_API_KEY=$FIREBASE_API_KEY" \
  --region us-central1 \
  --project myon-53d85
```

Note: `FIREBASE_API_KEY` is required by the consent page's Firebase Auth JS SDK config. Source from `~/.config/povver/` per secrets docs.

- [ ] **Step 8: Deploy and test**

Deploy: `cd mcp_server && make deploy`

Test:
1. `curl https://mcp.povver.ai/health` → `{ "status": "ok" }`
2. `curl https://mcp.povver.ai/.well-known/oauth-authorization-server` → metadata JSON
3. Open `https://mcp.povver.ai/authorize?client_id=claude-desktop&...` in browser → consent page
4. Connect from Claude Desktop → full flow

---

## Requirement Traceability

| Spec Requirement | Task |
|-----------------|------|
| SDK `OAuthServerProvider` interface | Task 4 |
| Express migration from `http.createServer()` | Task 5 |
| Token generation, hashing, SHA-256 storage | Task 1 |
| `runTransaction` for code exchange (S6) | Task 1 (exchangeCode) |
| `runTransaction` for token rotation (S6) | Task 1 (rotateRefreshToken) |
| 30s grace window on refresh rotation | Task 1 (rotateRefreshToken) |
| `type === "access"` / `type === "refresh"` enforcement | Task 1 (verifyAccessToken, rotateRefreshToken) |
| CSRF nonce in Firestore (not in-memory) | Task 1 (storeNonce, consumeNonce) |
| Hard-coded client allowlist | Task 2 |
| Branded consent page (dark bg, accent green, Inter) | Task 3 |
| Firebase Auth JS SDK (Apple/Google/email) | Task 3 |
| Prefix-based auth routing (`pvt_`/`pvk_`/legacy) | Task 4 (verifyAccessToken) |
| Premium gate on every MCP request | Task 4 (verifyAccessToken) |
| Re-authorization revokes old tokens | Task 4 (completeAuthorization) |
| Firestore rules — deny-all for 3 collections | Task 6 |
| Composite index on `mcp_tokens` | Task 6 |
| `getMcpConnectionStatus` Firebase Function | Task 7 |
| `revokeMcpTokens` Firebase Function | Task 7 |
| `ok()`/`fail()` response format | Task 7 |
| `requireFlexibleAuth` + `getAuthenticatedUserId` | Task 7 |
| API key prefix `pvk_` migration | Task 8 |
| Daily cleanup scheduled function | Task 9 |
| Account deletion cleanup | Task 10 |
| iOS ViewModel (not inline in View) | Task 11 |
| Not-connected state with instructions | Task 12 |
| Connected state with last-used + disconnect | Task 12 |
| Disabled state with upgrade button | Task 12 |
| `docs/FIRESTORE_SCHEMA.md` update | Task 13 |
| `docs/SYSTEM_ARCHITECTURE.md` update | Task 13 |
| `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` update | Task 13 |
| `docs/SECURITY.md` update | Task 13 |
| Custom domain `mcp.povver.ai` | Task 14 |
| Apple Services ID for web | Task 14 |
| Google OAuth consent screen | Task 14 |
| Firebase Auth authorized domains | Task 14 |
| Cloud Run domain mapping | Task 14 |
| Rate limiting on custom OAuth endpoints | Task 5 |
| OAuth denial redirect per spec | Task 5 |
