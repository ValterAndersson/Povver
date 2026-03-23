# Security Remediation Plan (v2 — Post-Review)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all exploitable security findings, harden against cost abuse, and ensure App Store submission readiness.

**Architecture:** Hardening pass across 6 layers (Firebase Functions, Firestore Rules, Agent Service, MCP Server, iOS, Infrastructure). Each task is scoped to one layer and one concern. No new features.

**Tech Stack:** Node.js (Firebase Functions), Python (Agent Service), TypeScript (MCP Server), Swift (iOS), Firestore Security Rules, GCP Cloud Run, Docker

**Audit Reference:** 2026-03-23 security audit, reviewed by pragmatic engineer, App Store reviewer, and cost/business analyst. Severity levels recalibrated per review feedback.

---

## Severity Recalibration (from review)

| Original | Finding | Revised | Reason |
|---|---|---|---|
| C1 | Agent Service "no auth" | LOW (defense-in-depth) | Cloud Run IAM (`--no-allow-unauthenticated`) IS auth |
| C2 | applyProgression IDOR | MEDIUM | Requires compromised API key; withApiKey middleware gates access |
| C4 | Cloud Tasks handler | MEDIUM | Cloud Run IAM restricts callers; header check is just defense-in-depth |
| C6 | No maxInstances on v1 | MEDIUM (cost) | Google has network DDoS protection; this is cost management |
| H4 | active_workout auth pattern | LOW-MEDIUM | Functionally equivalent; value is IDOR logging + consistency |

**Remains Critical:** C3 (API key in git), C5 (rate limiter bypass — deferred)
**Remains High:** H1 (Firestore rules), H2 (subscription race), H3 (premium gate), H5 (reviewRecommendation race), H6 (SSE exhaustion)

### Verified Safe Assumptions (from pre-execution audit)

| Concern | Verified | Evidence |
|---|---|---|
| `signedDate` exists on decoded JWS | YES | `JWSTransactionDecodedPayload.d.ts:99` — UNIX ms timestamp |
| Agent Service sends `X-User-Id` | YES | `http_client.py:106` sends `x-user-id` header |
| `getAuthenticatedUserId` handles API key lane | YES | `auth-helpers.js:37-44` reads `req.auth.uid` (set from header) |
| iOS writes to blocked subcollections | NO writes, but **DELETES during account deletion** | `UserRepository.swift:85-104` — see Task 8 note |

---

## Execution Order (revised per cost/business review)

| Priority | Task | Why |
|---|---|---|
| 1 | Task 1: Privacy manifest | **App Store rejection blocker** |
| 2 | Task 2: Rotate API key | Active credential exposure in git history |
| 3 | Task 3: Fix applyProgression IDOR | Combined with C3, data integrity risk |
| 4 | Task 21: App Store compliance fixes | **App Store rejection blockers** (new task) |
| 5 | Task 8: Firestore rules | Clients can forge analytics data NOW |
| 6 | Task 11: maxInstances | Highest ROI cost protection (~30 min, prevents $500+/day) |
| 7 | Task 12: Upstream cancellation | Saves real money daily from normal usage |
| 8 | Task 4: Standardize auth helpers | Consistency + IDOR logging |
| 9 | Task 5: Cloud Tasks error sanitization | Defense-in-depth (IAM is primary gate) |
| 10 | Task 6: reviewRecommendation | Race condition (needs investigation first) |
| 11 | Task 7: Agent Service defense-in-depth | Cloud Run IAM is primary; this is secondary |
| 12 | Task 14: Error sanitization | Information leakage |
| 13 | Task 15: Input validation | Payload abuse prevention |
| 14 | Task 13: Rate limiting | Missing on expensive endpoints |
| 15 | Task 9: Premium gate expires_at | Needs verification first |
| 16 | Task 10: Subscription sync transaction | Low likelihood (JWS blocks most attacks) |
| 17-20 | Infrastructure + iOS | Lower urgency |

---

## Workstream 1: App Store Submission Blockers

### Task 1: Fix Privacy Manifest [M1]

**Files:**
- Modify: `Povver/Povver/PrivacyInfo.xcprivacy`
- Reference: `Povver/Povver/Services/WorkoutSessionLogger.swift:220,238`

- [ ] **Step 1: Read the current privacy manifest**

- [ ] **Step 2: Add `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1`**

```xml
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array>
        <string>C617.1</string>
    </array>
</dict>
```

- [ ] **Step 3: Add `NSPrivacyCollectedDataTypeUserID` to collected data types**

The app collects Firebase UID (used as `appAccountToken`, stored in Firestore). Add to `NSPrivacyCollectedDataTypes`:

```xml
<dict>
    <key>NSPrivacyCollectedDataType</key>
    <string>NSPrivacyCollectedDataTypeUserID</string>
    <key>NSPrivacyCollectedDataTypeLinked</key>
    <true/>
    <key>NSPrivacyCollectedDataTypeTracking</key>
    <false/>
    <key>NSPrivacyCollectedDataTypePurposes</key>
    <array>
        <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
    </array>
</dict>
```

- [ ] **Step 4: Verify by building**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/PrivacyInfo.xcprivacy
git commit -m "fix(ios): complete privacy manifest for App Store submission

Adds NSPrivacyAccessedAPICategoryFileTimestamp (C617.1) for
WorkoutSessionLogger's .creationDateKey usage. Adds UserID to
collected data types.

Closes audit finding M1."
```

---

### Task 21: App Store Compliance Fixes (NEW — from App Store review)

**Files:**
- Modify: `Povver/Povver/Views/PaywallView.swift`
- Modify: `Povver/Povver/Views/Settings/SubscriptionView.swift`

- [ ] **Step 1: Read PaywallView.swift and SubscriptionView.swift**

- [ ] **Step 2: Add Terms of Service and Privacy Policy links to PaywallView**

Apple requires subscription paywalls to display links to both. Add after the subscription disclosure / "Manage Subscriptions" section:

```swift
HStack(spacing: 16) {
    Link("Terms of Service", destination: URL(string: "https://povver.ai/terms")!)
        .font(.caption)
        .foregroundColor(.secondary)
    Link("Privacy Policy", destination: URL(string: "https://povver.ai/privacy")!)
        .font(.caption)
        .foregroundColor(.secondary)
}
```

**NOTE:** Verify these URLs exist and are hosted. If not, they must be created before submission.

- [ ] **Step 3: Make "Restore Purchases" visible for non-premium users in SubscriptionView**

The restore button is currently inside the `manageSection` which only renders when `isPremium` is true. Move it outside the conditional or add a separate restore option for the non-premium state. Apple reviewers specifically test this flow from Settings > Subscription (not just the paywall).

- [ ] **Step 4: Verify Firebase SDK privacy manifest compliance**

Check that the Firebase SDK version in use (SPM/CocoaPods) is >= 10.22.0 and ships its own `PrivacyInfo.xcprivacy`. Run:

```bash
# For SPM:
grep -r "firebase" Povver/Povver.xcodeproj/project.pbxproj | head -5
# Check Package.resolved for version
cat Povver/Povver.xcworkspace/xcshareddata/swiftpm/Package.resolved | grep -A3 firebase
```

If the SDK version is older than 10.22.0, update it.

- [ ] **Step 5: Build and verify**

```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

- [ ] **Step 6: Commit**

```bash
git commit -am "fix(ios): App Store compliance — ToS/Privacy links, restore button

Adds Terms of Service and Privacy Policy links to PaywallView
(Guideline 3.1.2). Makes Restore Purchases visible for non-premium
users in SubscriptionView (Guideline 3.1.1).

Closes App Store review findings."
```

---

## Workstream 2: Active Credential Exposure

### Task 2: Rotate Compromised API Key [C3]

**Files:**
- Modify: `firebase_functions/functions/.env` (local, not committed)
- Modify: `firebase_functions/functions/README.md:111`

- [ ] **Step 1: Generate a new API key**

```bash
openssl rand -hex 32
```

- [ ] **Step 2: Add new key ALONGSIDE old key in Firebase Functions (overlap period)**

**BREAKAGE PREVENTION:** Deploy with both keys valid simultaneously to avoid agent outage during rotation. The middleware at `auth/middleware.js:129` reads `VALID_API_KEYS` which supports comma-separated values.

```bash
cd firebase_functions/functions
# Check how VALID_API_KEYS is currently configured:
firebase functions:config:get
# Add new key alongside old key (comma-separated):
# VALID_API_KEYS=myon-agent-key-2024,<new-key>
# Deploy Functions with both keys valid
npm run deploy
```

- [ ] **Step 3: Update Agent Service to use new key**

```bash
cd adk_agent/agent_service
# Update MYON_API_KEY to new key only
gcloud run services update agent-service \
  --update-env-vars MYON_API_KEY=<new-key> \
  --region us-central1
```

- [ ] **Step 4: Remove old key from Firebase Functions**

```bash
cd firebase_functions/functions
# Update VALID_API_KEYS to new key only (remove old):
# VALID_API_KEYS=<new-key>
npm run deploy
```

- [ ] **Step 5: Remove hardcoded key from README**

Replace the key reference in `firebase_functions/functions/README.md` with `<your-api-key>`.

- [ ] **Step 6: Verify old key is rejected**

After deployment, confirm `myon-agent-key-2024` is rejected by all endpoints:

```bash
curl -H "x-api-key: myon-agent-key-2024" https://us-central1-myon-53d85.cloudfunctions.net/streamAgentNormalized
# Should get 401/403
```

- [ ] **Step 7: Verify new key works end-to-end**

```bash
cd adk_agent/agent_service && make chat
# Send a test message and verify SSE response
```

- [ ] **Step 8: Commit**

```bash
git add firebase_functions/functions/README.md
git commit -m "security: rotate API key, remove hardcoded value from README

Old key myon-agent-key-2024 was visible in committed source files.
Rotated to new key distributed via environment variables only.
Old key verified rejected by all endpoints.

Closes audit finding C3."
```

---

### Task 3: Fix `applyProgression` userId Derivation [C2→M]

**Files:**
- Modify: `firebase_functions/functions/agents/apply-progression.js`

- [ ] **Step 1: Read the file**

- [ ] **Step 2: Replace `req.body.userId` with `getAuthenticatedUserId(req)`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

// Replace:  const { userId, ... } = req.body;
// With:
const userId = getAuthenticatedUserId(req);
if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
const { targetType, targetId, changes, ... } = req.body;
```

- [ ] **Step 3: Remove `cors: true`**

This endpoint is server-to-server only (agent service → Firebase Functions). CORS is irrelevant. The `withApiKey` middleware's `setCorsHeaders()` handles the local dev case.

- [ ] **Step 4: Commit**

```bash
git add firebase_functions/functions/agents/apply-progression.js
git commit -m "security: use getAuthenticatedUserId in applyProgression

Previously read userId from req.body. Now derives from authenticated
context (X-User-Id header in API key lane). Removes cors: true
(server-to-server endpoint, no browser clients).

Closes audit findings C2, M6."
```

---

## Workstream 3: Firestore Rules

### Task 8: Block Client Writes to Server-Computed Subcollections [H1]

**Files:**
- Modify: `firebase_functions/firestore.rules`

- [ ] **Step 1: Read the current rules**

- [ ] **Step 2: Add server-computed collections to the wildcard exclusion list**

```
&& collection != "set_facts"
&& collection != "analytics_series_exercise"
&& collection != "analytics_series_muscle"
&& collection != "analytics_series_muscle_group"
&& collection != "analytics_rollups"
&& collection != "analytics_state"
&& collection != "weekly_stats"
&& collection != "subscription_events"
```

- [ ] **Step 3: Add explicit deny rules for root collections relying on fallback**

```
match /catalog_locks/{document=**} { allow read, write: if false; }
match /catalog_changes/{document=**} { allow read, write: if false; }
match /catalog_idempotency/{document=**} { allow read, write: if false; }
match /exercise_families/{document=**} { allow read, write: if false; }
match /llm_usage/{document=**} { allow read, write: if false; }
```

- [ ] **Step 4: BREAKAGE CHECK — iOS account deletion deletes from these subcollections**

`Povver/Povver/Repositories/UserRepository.swift:85-104` runs client-side subcollection deletion for `set_facts`, `analytics_series_exercise`, `analytics_series_muscle`, `analytics_rollups`, `analytics_state`, `weekly_stats`. Firestore `delete` requires `write` permission. The new rules must still allow authenticated users to **delete** (but not create/update) docs in their own subcollections.

**Option A (recommended):** Change the wildcard exclusion to block `create` and `update` only, allow `delete`:
```
match /users/{userId}/{collection}/{docId} {
  // For server-computed subcollections: allow delete only (for account cleanup)
  allow delete: if request.auth != null && request.auth.uid == userId
                && collection in ["set_facts", "analytics_series_exercise", ...];
  // Block create/update:
  allow create, update: if request.auth != null && request.auth.uid == userId
                        && collection != "set_facts"
                        && collection != "analytics_series_exercise"
                        // ... rest of exclusion list
}
```

**Option B:** Remove client-side subcollection deletion from iOS `UserRepository.swift` (server-side `delete-account.js` handles it via Admin SDK). But this changes iOS behavior and may leave orphaned data if the server function fails.

- [ ] **Step 5: Deploy**

```bash
firebase deploy --only firestore:rules
```

- [ ] **Step 6: Smoke test iOS app** (reads unaffected; test account deletion flow specifically)

- [ ] **Step 7: Commit**

```bash
git add firebase_functions/firestore.rules
git commit -m "security: block client writes to server-computed subcollections

Adds set_facts, analytics_*, weekly_stats, subscription_events to
wildcard exclusion list. Adds explicit deny rules for root collections
previously relying on deny-all fallback.

Closes audit findings H1, L13."
```

---

## Workstream 4: Cost Protection

### Task 11: Add `maxInstances` to v1 Functions [C6→M-cost]

**Files:**
- Modify: `firebase_functions/functions/index.js`

- [ ] **Step 1: Read `index.js` to identify all v1 exports**

- [ ] **Step 2: Apply tiered `maxInstances` (per cost/business review)**

Use tiered limits instead of blanket 50:

```javascript
const readOptions = { maxInstances: 30, timeoutSeconds: 60 };
const writeOptions = { maxInstances: 10, timeoutSeconds: 60 };
const agentOptions = { maxInstances: 10, timeoutSeconds: 120 };
```

Apply per function category:
- **Read-only** (getUser, getWorkout, getUserWorkouts, getUserTemplates, getRoutine, etc.) → `readOptions`
- **Write/compute** (completeActiveWorkout, createTemplate, runAnalyticsForUser, etc.) → `writeOptions`
- **Agent-facing** (getPlanningContext, applyProgression, getAnalysisSummary) → `agentOptions`

- [ ] **Step 3: Add `maxInstances: 10` to `processWorkoutCompletionTask`**

- [ ] **Step 4: Deploy and verify**

```bash
npm run deploy
```

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/index.js
git commit -m "cost: add tiered maxInstances to all Cloud Functions

Read endpoints: 30, write/compute: 10, agent-facing: 10.
Prevents unbounded instance scaling. Also caps
processWorkoutCompletionTask at 10.

Closes audit finding C6."
```

---

### Task 12: Cancel Upstream on Client Disconnect [H6]

**Files:**
- Modify: `firebase_functions/functions/strengthos/stream-agent-normalized.js`

- [ ] **Step 1: Read the callAgentService and disconnect handler sections**

- [ ] **Step 2: Identify which HTTP client is used for upstream call**

**IMPORTANT:** The `callAgentService` function may use `google-auth-library`'s `client.request()` (not raw `axios`). Check the actual code:
- If `client.request()`: The `google-auth-library` `GoogleAuth` client supports `AbortSignal` via the `signal` option (Node.js `fetch` adapter). Verify by checking the library version.
- If raw `axios`: Standard `signal` option works.

- [ ] **Step 3: Add AbortController**

```javascript
const abortController = new AbortController();

req.on('close', () => {
  clientDisconnected = true;
  clearInterval(heartbeatInterval);
  abortController.abort();
});

// Pass signal to whichever HTTP client is used:
// For google-auth-library client.request():
const response = await client.request({
  // ... existing config
  signal: abortController.signal,
});
// For axios:
// const response = await axios({ ...config, signal: abortController.signal });
```

- [ ] **Step 4: Handle AbortError gracefully**

Wrap the stream processing in a try/catch that ignores `AbortError`:

```javascript
} catch (err) {
  if (err.name === 'CanceledError' || err.code === 'ERR_CANCELED') {
    logger.info('[stream] upstream_canceled_on_disconnect', { correlationId });
    return;
  }
  // ... existing error handling
}
```

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/strengthos/stream-agent-normalized.js
git commit -m "fix: cancel upstream agent call on client disconnect

Adds AbortController to axios call. On client disconnect, upstream
SSE is aborted immediately instead of running for up to 180s
wasting LLM tokens.

Closes audit finding H6."
```

---

## Workstream 5: Auth Hardening

### Task 4: Standardize Active Workout Auth Pattern [H4→L-M]

**Files:**
- Modify: All 11 files in `firebase_functions/functions/active_workout/`

- [ ] **Step 1: Read each file, confirm the pattern**

- [ ] **Step 2: Replace `req.user?.uid || req.auth?.uid` with `getAuthenticatedUserId(req)` in all 11 files**

Add import where missing:
```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
```

- [ ] **Step 3: Run tests**

```bash
cd firebase_functions/functions && npm test
```

- [ ] **Step 4: Commit**

```bash
git add firebase_functions/functions/active_workout/
git commit -m "chore: standardize active_workout endpoints to getAuthenticatedUserId

Consistent auth derivation + IDOR-attempt logging across all 11
active_workout endpoints. Functionally equivalent but adds
defense-in-depth logging.

Closes audit finding H4."
```

---

### Task 5: Sanitize Cloud Tasks Handler Errors [C4→M]

**Files:**
- Modify: `firebase_functions/functions/triggers/workout-completion-task.js`

- [ ] **Step 1: Read the handler**

- [ ] **Step 2: Sanitize the error response**

Replace `res.status(500).send(err.message)` with:

```javascript
logger.error('[workout-completion-task] processing_failed', {
  userId, workoutId, error: err.message,
});
res.status(500).send('Internal processing error');
```

**Note (from pragmatic review):** Do NOT add X-CloudTasks-TaskName header validation — it's trivially spoofable and provides no real security. Cloud Run IAM is the actual auth gate here. Error sanitization is the valuable fix.

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/triggers/workout-completion-task.js
git commit -m "security: sanitize error messages in Cloud Tasks handler

Replaces raw err.message in 500 response with generic message.
Internal details logged server-side only. Cloud Run IAM handles
authentication.

Closes audit finding C4."
```

---

### Task 6: Fix `reviewRecommendation` — CORS + Race Condition [H5]

**Files:**
- Modify: `firebase_functions/functions/recommendations/review-recommendation.js`
- Reference: `firebase_functions/functions/agents/apply-progression.js` (check if `applyChangesToTarget` uses transactions)

- [ ] **Step 1: Read `review-recommendation.js`**

- [ ] **Step 2: Read `apply-progression.js` to check if `applyChangesToTarget` uses a transaction internally**

**BLOCKER (from pragmatic review):** If `applyChangesToTarget` runs its own transaction, wrapping the caller in another transaction will fail (Firestore doesn't support nested transactions). Check this BEFORE implementing Step 4.

- [ ] **Step 3: Remove `cors: true` and use `getAuthenticatedUserId`**

- [ ] **Step 4: Add concurrency protection**

**If `applyChangesToTarget` does NOT use transactions:** Wrap the full read-check-update-apply in `runTransaction`.

**If `applyChangesToTarget` DOES use transactions:** Use atomic compare-and-swap on the state field only:

```javascript
// Atomic state transition (outside transaction):
const result = await recRef.update({
  state: newState,
  // ... other fields
}, { precondition: { exists: true } });

// But check state first with a transaction on the recommendation doc only:
await db.runTransaction(async (t) => {
  const recDoc = await t.get(recRef);
  if (recDoc.data().state !== 'pending_review') throw new Error('INVALID_STATE');
  t.update(recRef, { state: newState, updated_at: admin.firestore.FieldValue.serverTimestamp() });
});
// Then call applyChangesToTarget outside the transaction
```

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/recommendations/review-recommendation.js
git commit -m "security: fix reviewRecommendation — remove CORS, add concurrency guard

Removes cors: true (no browser clients). Adds atomic state transition
to prevent double-apply race condition. Uses getAuthenticatedUserId.

Closes audit finding H5."
```

---

### Task 7: Agent Service Defense-in-Depth Auth [C1→LOW]

**Files:**
- Modify: `adk_agent/agent_service/app/main.py`

**Note (from pragmatic review):** Cloud Run IAM (`--no-allow-unauthenticated`) is the primary auth. This task adds a secondary application-level check as defense-in-depth. Severity is LOW, not Critical.

- [ ] **Step 1: Read `main.py`**

- [ ] **Step 2: Add API key validation**

```python
VALID_API_KEYS = set(k for k in os.environ.get("MYON_API_KEY", "").split(",") if k)

@app.post("/stream")
async def stream(request: Request):
    api_key = request.headers.get("x-api-key", "")
    if VALID_API_KEYS and api_key not in VALID_API_KEYS:
        return JSONResponse(status_code=401, content={"error": "Unauthorized"})
    # ... rest of handler
```

- [ ] **Step 3: Sanitize error messages in SSE events**

Replace `yield sse_event("error", {"message": str(e)})` with:
```python
logger.error(f"Stream error: {e}", exc_info=True)
yield sse_event("error", {"code": "INTERNAL_ERROR", "message": "An internal error occurred"})
```

Also sanitize the `/health?deep=1` endpoint (from pragmatic review):
Replace `f"error: {e}"` with `"error: service check failed"`.

- [ ] **Step 4: Run tests**

```bash
make test
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/main.py
git commit -m "security: add defense-in-depth auth + sanitize errors in agent service

Adds API key validation as secondary gate (Cloud Run IAM is primary).
Sanitizes error messages in SSE events and health check to prevent
internal detail leakage.

Closes audit findings C1, M2 (partial)."
```

---

## Workstream 6: Subscription Integrity

### Task 9: Add `expires_at` Check to Premium Gate [H3]

**Files:**
- Modify: `firebase_functions/functions/utils/subscription-gate.js`
- Reference: `firebase_functions/functions/subscriptions/app-store-webhook.js` (verify `subscription_expires_at` is written)

- [ ] **Step 1: PREREQUISITE — Verify `subscription_expires_at` is written by the webhook**

Read `app-store-webhook.js` and search for `subscription_expires_at` or `expires_at`. If this field is NOT populated by the webhook, the check would be dead code. **Do not proceed until verified.**

- [ ] **Step 2: Read `subscription-gate.js`**

- [ ] **Step 3: Add expiration check with 24h grace period**

```javascript
if (data.subscription_tier === 'premium') {
  if (data.subscription_expires_at) {
    const expiresAt = data.subscription_expires_at.toDate
      ? data.subscription_expires_at.toDate()
      : new Date(data.subscription_expires_at);
    const graceMs = 24 * 60 * 60 * 1000; // 24h for webhook delivery delays
    if (expiresAt.getTime() + graceMs < Date.now()) {
      logger.warn('[subscriptionGate] tier_premium_but_expired', {
        userId, expires_at: expiresAt.toISOString(),
      });
      return false;
    }
  }
  return true;
}
```

**Note (from cost/business review):** 24h grace period is appropriate. Apple documents webhook delays up to 24h during outages. Shorter periods risk false-negatives on legitimate subscribers.

- [ ] **Step 4: Replace `console.error` with `logger.error`**

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/utils/subscription-gate.js
git commit -m "security: add expires_at check to premium gate with 24h grace

Closes the window between subscription expiration and webhook
delivery. 24h grace period matches Apple's documented webhook
delay bounds.

Closes audit finding H3."
```

---

### Task 10: Add Transaction to Subscription Sync [H2]

**Files:**
- Modify: `firebase_functions/functions/subscriptions/sync-subscription-status.js`

**Note (from reviews):** This has LOW practical exploitability — Apple revokes JWS on expiry, blocking most attack scenarios. The fix adds defense-in-depth.

- [ ] **Step 1: Read the current sync handler**

- [ ] **Step 2: Wrap update in transaction with timestamp-based conflict resolution**

**IMPORTANT (from pragmatic review):** Do NOT use "skip if already premium" logic — it would block legitimate re-subscriptions. Use timestamp-based resolution instead:

```javascript
await db.runTransaction(async (t) => {
  const userDoc = await t.get(userRef);
  const currentData = userDoc.data() || {};

  // Timestamp-based conflict resolution:
  // If subscription was updated more recently than this sync's source data,
  // the webhook has already set authoritative state — don't overwrite.
  const currentUpdatedAt = currentData.subscription_updated_at?.toMillis?.() || 0;
  const transactionTimestamp = decodedTransaction.signedDate || 0;

  if (currentUpdatedAt > transactionTimestamp) {
    logger.info('[sync] skipping_stale_sync', { userId, currentUpdatedAt, transactionTimestamp });
    return;
  }

  t.update(userRef, {
    subscription_status: status,
    subscription_tier: tier,
    // ... other fields
    subscription_updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });
});
```

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/subscriptions/sync-subscription-status.js
git commit -m "security: add transaction with timestamp conflict resolution to sync

Uses transaction + timestamp comparison: if webhook wrote more
recently than the sync's source data, skip to preserve authoritative
webhook state. Allows legitimate re-subscriptions.

Closes audit finding H2."
```

---

## Workstream 7: Error Sanitization + Validation

### Task 14: Sanitize Error Messages Across All Endpoints [M2]

**Files:**
- Modify: `firebase_functions/functions/strengthos/stream-agent-normalized.js:1161,1258`
- Modify: `firebase_functions/functions/active_workout/complete-current-set.js:168`
- Modify: `firebase_functions/functions/active_workout/autofill-exercise.js:259`
- Modify: `firebase_functions/functions/active_workout/patch-active-workout.js:515`
- Modify: `adk_agent/agent_service/app/agent_loop.py:254` (if not done in Task 7)
- Modify: `firebase_functions/functions/health.js` (sanitize service info leakage — L6)

- [ ] **Step 1: Replace raw error forwarding with sanitized messages in each file**

Pattern:
```javascript
// Before:
return fail(res, 'INTERNAL', error.message, { message: error.message }, 500);
// After:
logger.error('[endpoint] operation_failed', { userId, error: error.message });
return fail(res, 'INTERNAL', 'An internal error occurred', null, 500);
```

For SSE:

**BREAKAGE CHECK:** Verify the iOS SSE parser (`DirectStreamingService.swift`) handles error events with object format. The Cloud Run path already sends `{ code, message }` objects. The Vertex AI fallback path currently sends raw strings — changing to object format must match what iOS expects. Read `DirectStreamingService.swift` to confirm the error parsing logic before changing.

```javascript
// Before:
sse.write({ type: 'error', error: `Vertex AI error: ${response.status} - ${errorBody.slice(0, 200)}` });
// After:
logger.error('[stream] upstream_error', { status: response.status, body: errorBody.slice(0, 500) });
sse.write({ type: 'error', error: { code: 'SERVICE_UNAVAILABLE', message: 'Service temporarily unavailable' } });
```

- [ ] **Step 2: Run tests**

- [ ] **Step 3: Commit**

```bash
git commit -am "security: sanitize error messages across all endpoints

Closes audit finding M2."
```

---

### Task 15: Add Zod Validation to Unvalidated Endpoints [M3]

**Files:**
- Modify: `firebase_functions/functions/active_workout/start-active-workout.js`
- Modify: `firebase_functions/functions/active_workout/add-exercise.js`
- Modify: `firebase_functions/functions/artifacts/artifact-action.js`

- [ ] **Step 1: Read `utils/validators.js` for existing patterns and constants**

- [ ] **Step 2: Add schemas and validate at top of each handler**

See original plan for schema definitions. Apply before business logic.

- [ ] **Step 3: Commit**

```bash
git commit -am "security: add Zod validation to start-workout, add-exercise, artifact-action

Closes audit finding M3."
```

---

### Task 13: Add Rate Limiting to Missing Endpoints [M4]

**Files:**
- Modify: `firebase_functions/functions/active_workout/complete-active-workout.js`
- Modify: `firebase_functions/functions/artifacts/artifact-action.js`

- [ ] **Step 1: Add `writeLimiter.check(userId)` after userId derivation in each**

- [ ] **Step 2: Commit**

```bash
git commit -am "security: add rate limiting to complete-workout, artifact-action

Closes audit finding M4."
```

---

## Workstream 8: Infrastructure

### Task 16: Docker Non-Root User [H8]

**Files:**
- Modify: `adk_agent/agent_service/Dockerfile`
- Modify: `mcp_server/Dockerfile`
- Modify: `adk_agent/training_analyst/Dockerfile`

- [ ] **Step 1: Read each Dockerfile to check base image**

**IMPORTANT (from pragmatic review):** Check if images use Debian (`python:3.11-slim`) or Alpine. Debian uses `adduser --disabled-password --no-create-home --gecos "" appuser`. Alpine uses `adduser -D -H appuser`.

- [ ] **Step 2: Add non-root user with correct syntax for each base image**

- [ ] **Step 3: Split dev deps in agent_service**

Move `pytest`, `pytest-asyncio` to `requirements-dev.txt`. Only install production deps in Dockerfile.

- [ ] **Step 4: Build and test each image**

- [ ] **Step 5: Commit**

```bash
git commit -am "security: run Docker containers as non-root, split dev deps

Closes audit findings H8, L12."
```

---

### Task 17: Deterministic Training Analysis Job IDs [M12]

**Files:**
- Modify: `firebase_functions/functions/training/process-workout-completion.js`

- [ ] **Step 1: Read the job creation code**

- [ ] **Step 2: Replace `.add()` with deterministic doc ID**

```javascript
const jobId = `pw-${userId}-${workoutId}`;
const jobRef = db.collection('training_analysis_jobs').doc(jobId);

// Check if already completed before overwriting (from pragmatic review)
const existing = await jobRef.get();
if (existing.exists && existing.data().status === 'completed') {
  logger.info('[process-workout-completion] job_already_completed', { jobId });
  return;
}

await jobRef.set(jobData);
```

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/training/process-workout-completion.js
git commit -m "fix: deterministic job IDs for training_analysis_jobs

Prevents duplicate analysis jobs from Cloud Tasks at-least-once
delivery. Checks for already-completed jobs before overwriting.

Closes audit finding M12."
```

---

### Task 18: Complete Account Deletion Subcollections [M16]

**Files:**
- Modify: `firebase_functions/functions/user/delete-account.js`

- [ ] **Step 1: Read current subcollection lists**

- [ ] **Step 2: Add missing nested subcollections**

```javascript
// Add to NESTED_SUBCOLLECTIONS:
canvases: ['cards', 'workspace_entries', 'up_next', 'events', 'idempotency'],
templates: ['changelog'],
```

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/user/delete-account.js
git commit -m "fix: complete account deletion — add missing subcollections

Adds workspace_entries/up_next/events/idempotency under canvases,
changelog under templates for complete data purge (Guideline 5.1.1(v)).

Closes audit finding M16."
```

---

## Workstream 9: iOS Hardening

### Task 19: Remove Bare `print()` Statements [M15]

- [ ] **Step 1: Check if recent commits already addressed this**

Commits `374861b` and `bdb6225` added a build phase guard and removed some prints. Verify whether the listed files still have the issue:

```bash
grep -rn "print(" Povver/Povver/UI/ --include="*.swift" | grep -v "#if DEBUG" | grep -v "// " | head -20
```

- [ ] **Step 2: If prints remain, wrap in `#if DEBUG` or remove**

- [ ] **Step 3: Build to verify the build phase guard catches any remaining**

- [ ] **Step 4: Commit (only if changes were needed)**

---

### Task 20: Add File Protection to Disk Cache [M8]

**Files:**
- Modify: `Povver/Povver/Services/CacheManager.swift`

- [ ] **Step 1: Read DiskCache implementation**

- [ ] **Step 2: Add `FileProtection.complete` after write**

```swift
try (fileURL as NSURL).setResourceValue(
    URLFileProtection.complete,
    forKey: .fileProtectionKey
)
```

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/Services/CacheManager.swift
git commit -m "fix(ios): add FileProtection.complete to disk cache

Closes audit finding M8."
```

---

## Summary

| Workstream | Tasks | Findings Closed |
|---|---|---|
| 1. App Store Blockers | 1, 21 | M1, App Store compliance |
| 2. Credential Exposure | 2, 3 | C3, C2/M6 |
| 3. Firestore Rules | 8 | H1, L13 |
| 4. Cost Protection | 11, 12 | C6, H6 |
| 5. Auth Hardening | 4, 5, 6, 7 | H4, C4, H5, C1 |
| 6. Subscription | 9, 10 | H3, H2 |
| 7. Error/Validation | 13, 14, 15 | M2, M3, M4, L6 (partial) |
| 8. Infrastructure | 16, 17, 18 | H8, L12, M12, M16 |
| 9. iOS | 19, 20 | M15, M8 |

**Total coverage:** 24 findings addressed by tasks, 11 explicitly deferred, 14 LOW findings tracked for future passes. **Zero findings unaccounted for.**

**Deferred (with rationale):**
- C5 (distributed rate limiter) — `maxInstances` provides sufficient cost ceiling for current scale
- H7 (MCP Server rate limiting) — Cloud Run IAM is primary gate; MCP Server has low traffic; revisit if usage grows
- H9/H10 (Docker digest pinning, Secret Manager) — infrastructure, need GCP console access
- M5 (sandbox environment check) — needs production config verification
- M7 (certificate pinning) — significant iOS effort, incremental addition
- M9/M10 (MCP client store) — self-healing (Claude Desktop re-registers)
- M11 (summary injection) — low blast radius for fitness domain
- M13 (CI/CD) — large scope, separate project
- M14 (unbounded collectionGroup) — performance, not security-critical
- M17 (`decodeJWSPayloadInsecure` exported from `apple-verifier.js`) — function is exported but unused outside the file; guarded by `FUNCTIONS_EMULATOR` check in all call sites; unexport in a future cleanup pass
- All LOW findings (L1-L16) — tracked for future passes (L6 partially addressed in Task 14, L12/L13 addressed in Tasks 16/8)

**Parallel action item (5 minutes, GCP Console):**
- Set GCP billing alert at 200% of current baseline monthly spend
