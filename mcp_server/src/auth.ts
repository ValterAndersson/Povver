// src/auth.ts
import { createHash } from 'crypto';
import admin from 'firebase-admin';

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

export interface AuthResult {
  userId: string;
  keyName: string;
}

export async function authenticateApiKey(apiKey: string): Promise<AuthResult> {
  const keyHash = createHash('sha256').update(apiKey).digest('hex');
  const doc = await db.doc(`mcp_api_keys/${keyHash}`).get();

  if (!doc.exists) {
    throw new Error('Invalid API key');
  }

  const data = doc.data()!;

  // Check premium status
  const userDoc = await db.doc(`users/${data.user_id}`).get();
  if (!userDoc.exists) {
    throw new Error('User not found');
  }

  const userData = userDoc.data()!;
  // Mirror isPremiumUser() logic from Firebase Functions
  const isPremium = userData.subscription_override === 'premium'
                 || userData.subscription_tier === 'premium';
  if (!isPremium) {
    throw new Error('Premium subscription required for MCP access');
  }

  // Update last_used_at
  await doc.ref.update({ last_used_at: admin.firestore.FieldValue.serverTimestamp() });

  return { userId: data.user_id, keyName: data.name || 'default' };
}
