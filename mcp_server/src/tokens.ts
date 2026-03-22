// src/tokens.ts
// Core storage layer for OAuth 2.1 nonces, auth codes, and tokens.
// All read-then-write operations use runTransaction (S6).
// Tokens are stored as SHA-256 hashes — raw tokens never persisted.

import { createHash, randomBytes } from 'crypto';
import admin from 'firebase-admin';

const db = admin.firestore();

const COLLECTIONS = {
  nonces: 'mcp_oauth_nonces',
  codes: 'mcp_oauth_codes',
  tokens: 'mcp_tokens',
} as const;

const TTL = {
  nonce: 10 * 60 * 1000,             // 10 minutes
  code: 5 * 60 * 1000,               // 5 minutes
  access: 60 * 60 * 1000,            // 1 hour
  refresh: 90 * 24 * 60 * 60 * 1000, // 90 days
  grace: 30 * 1000,                  // 30 seconds
} as const;

// ---------------------------------------------------------------------------
// Token generation & hashing
// ---------------------------------------------------------------------------

/** Generate an access/refresh token. `pvt_` prefix enables prefix-based auth routing. */
export function generateToken(): string {
  return 'pvt_' + randomBytes(32).toString('hex');
}

export function generateCode(): string {
  return randomBytes(32).toString('hex');
}

export function generateNonce(): string {
  return randomBytes(16).toString('hex');
}

/** One-way hash used as Firestore document ID — raw token is never stored. */
export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

// ---------------------------------------------------------------------------
// Nonce storage (CSRF protection for authorize flow)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Auth code storage (single-use, transactional exchange)
// ---------------------------------------------------------------------------

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
    created_at: admin.firestore.FieldValue.serverTimestamp(),
  });
}

// Note on timestamps inside transactions:
// - expires_at uses Date.now() + offset because we need to compare it in the same transaction
// - created_at uses Timestamp.now() inside transactions (simpler than FieldValue.serverTimestamp())
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

// ---------------------------------------------------------------------------
// Refresh token rotation (transactional, with grace window)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Access token verification
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// User token revocation
// ---------------------------------------------------------------------------

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
