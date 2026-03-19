# Performance & Scalability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Scale Povver from <1k to 10k concurrent users by fixing 5 critical blockers (SSE cap, write storms, missing rate limiting, Vertex AI quota, zero observability) and improving iOS UX performance.

**Architecture:** Conservative, incremental scaling — raise capacity limits first (Phase 0-1), improve client UX (Phase 2), then refactor infrastructure for 10x headroom (Phase 3). Each phase is independently deployable and reversible. No database migrations, no breaking API changes.

**Tech Stack:** Firebase Cloud Functions v2 (Node.js), Firestore, GCP Cloud Monitoring, iOS/SwiftUI, Vertex AI Agent Engine

**Cost Constraint:** $0 revenue currently. No recurring monthly costs (no `minInstances`, no Redis, no paid tiers). All paid improvements are deferred to a "Monthly Paid Improvements" section and evaluated post-launch when revenue justifies spend.

**Design Document:** `docs/plans/2026-02-27-performance-scalability-design.md` (revised 2026-03-04)

---

## Phase 0 — Observability Foundation

### Why this is the most important phase

You cannot scale what you cannot measure. Today there are zero dashboards, zero alerting rules, and zero cost tracking. When the SSE cap is hit at 20 users, nobody gets paged. When a trigger storm burns $500 in writes, nobody notices until the bill arrives. Every subsequent phase depends on being able to measure its impact.

**Complexity:** Low | **Risk:** Low (read-only infrastructure, no code changes) | **Scalability Benefit:** Enables data-driven decisions for all subsequent phases

---

### Task 1: Set Up Cloud Monitoring Dashboard

**Files:**
- Modify: GCP Console (Cloud Monitoring)

**Step 1: Create SSE Health dashboard**

Navigate to GCP Console > Cloud Monitoring > Dashboards > Create Dashboard.

Add these widgets:
- **Active Instances**: `cloudfunctions.googleapis.com/function/active_instances` filtered by `function_name=streamAgentNormalized`
- **Execution Count**: `cloudfunctions.googleapis.com/function/execution_count` filtered by `function_name=streamAgentNormalized`, grouped by `status`
- **Execution Time P50/P95/P99**: `cloudfunctions.googleapis.com/function/execution_times` with percentile aggregation
- **Error Rate**: `cloudfunctions.googleapis.com/function/execution_count` with `status=error` / total

**Step 2: Create Function Performance dashboard**

Add widgets for:
- Top 10 functions by invocation rate
- P50/P95 latency by function name (top 10)
- Cold start frequency: filter for `execution_start_type=cold`

**Step 3: Create Firestore Operations dashboard**

Add widgets for:
- `firestore.googleapis.com/document/read_count` grouped by collection
- `firestore.googleapis.com/document/write_count` grouped by collection
- `firestore.googleapis.com/document/delete_count`

**Step 4: Verify dashboards show data**

Navigate to each dashboard and confirm widgets render with live data. If any widget shows "No data", verify the metric name and filter.

**Step 5: Commit (no code changes — document the dashboard URLs)**

```bash
# No code commit needed — dashboards are in GCP Console.
# Optionally document dashboard URLs in docs/SYSTEM_ARCHITECTURE.md
```

---

### Task 2: Set Up Alerting Rules

**Files:**
- Modify: GCP Console (Cloud Monitoring > Alerting)

**Step 1: Create SSE capacity alert**

GCP Console > Cloud Monitoring > Alerting > Create Policy:
- Metric: `cloudfunctions.googleapis.com/function/active_instances`
- Filter: `function_name=streamAgentNormalized`
- Condition: Above 80% of maxInstances (initially 16, then 80 after Phase 1.1) for 5 minutes
- Notification: Email (add PagerDuty/Slack later)
- Severity: Critical

**Step 2: Create error rate alert**

- Metric: `cloudfunctions.googleapis.com/function/execution_count` with `status=error`
- Condition: Error rate > 1% for any function for 5 minutes
- Notification: Email
- Severity: Warning

**Step 3: Create Firestore write spike alert**

- Metric: `firestore.googleapis.com/document/write_count`
- Condition: > 10,000 writes/minute for 5 minutes
- Notification: Email
- Severity: Warning (cost protection)

**Step 4: Verify alerts fire correctly**

Check that alert policies are listed under Alerting > Policies. Test by temporarily lowering a threshold.

---

### Task 3: Set Up Budget Alerts (Billing Export Already Done)

**Files:**
- Modify: GCP Console (Billing)

**Pre-condition:** BigQuery billing export is already live at `myon-53d85.billing_export.gcp_billing_export_resource_v1_01B5D7_6D8663_335DC4`. Verified 2026-03-04 — last 30 days shows $54 total ($44.61 Vertex AI, $6.75 Cloud Run, $0.96 Cloud Functions).

**Step 1: Set budget alerts**

GCP Console > Billing > Budgets & alerts > Create budget:
- Budget: $500/month → email alert at 50%, 80%, 100%
- Budget: $1,000/month → email alert at 100%
- Budget: $5,000/month → email alert at 100%

**Step 3: Verify budget appears in console**

Check Budgets & alerts page shows the newly created budgets.

**Step 4: Commit**

```bash
# No code commit — GCP Console configuration only.
```

---

## Phase 1 — Emergency Fixes

### Why this is the most important phase

Phase 1 addresses the 5 hard blockers that will cause user-facing failures before reaching 5k users. The SSE cap literally returns 503 to user #21. The Vertex AI quota blocks user #11. Rate limiting gaps allow a single bad actor to take down the entire system. These are not optimizations — they are production safety nets.

**Complexity:** Low-Medium | **Risk:** Low (mostly config changes + small utility code) | **Scalability Benefit:** SSE capacity 20 -> 100; all endpoints capped and rate-limited; Vertex AI quota raised; subscription checks cached

---

### Task 4: Raise SSE Connection Cap (maxInstances: 100)

**Architecture rationale:** We keep `concurrency: 1` because module-level shared mutable state (`eventStartTimes`, `toolArgsCache`, `currentActiveAgent` at stream-agent-normalized.js:453-457) would cause cross-stream data corruption at concurrency > 1. Instead we raise `maxInstances` from 20 to 100, giving 5x capacity with zero code risk. No `minInstances` — cold starts are acceptable at current scale and there's $0 revenue to justify always-on instances. This is the safest path: no code changes, no race conditions, no recurring cost, immediate 5x capacity.

**Files:**
- Modify: `firebase_functions/functions/index.js:~234`

**Step 1: Read the current SSE config**

Read `firebase_functions/functions/index.js` around line 234 to confirm current config.

**Step 2: Update the config**

```javascript
// File: firebase_functions/functions/index.js
// Find and replace the streamAgentNormalized export:

// BEFORE:
exports.streamAgentNormalized = onRequestV2(
  { timeoutSeconds: 300, memory: '512MiB', maxInstances: 20, concurrency: 1 },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);

// AFTER:
exports.streamAgentNormalized = onRequestV2(
  {
    timeoutSeconds: 540,      // Full v2 HTTP allowance (9 min max)
    memory: '512MiB',
    maxInstances: 100,        // 5x capacity (was: 20)
    concurrency: 1,           // KEEP AT 1 — race conditions exist (see Phase 3, Task 16)
  },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);
```

**Step 3: Run existing tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass (config change only, no logic change)

**Step 4: Commit**

```bash
git add firebase_functions/functions/index.js
git commit -m "perf: raise SSE maxInstances to 100, timeout to 540s

5x SSE capacity (20 -> 100 concurrent streams) with zero code risk.
Keep concurrency: 1 due to module-level shared state race conditions.
Raise timeout to 540s (full v2 HTTP allowance).

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.1"
```

---

### Task 5: Add Subscription Gate Caching

**Architecture rationale:** In-memory cache with 1-minute TTL is the right tool here. Firestore's own caching is per-client-library and doesn't persist across cold starts. A 1-minute TTL (not 5 minutes — the original plan was too aggressive for upgrade UX) means a user who upgrades to premium waits at most 60 seconds before features unlock. Combined with instant cache invalidation on the webhook path, upgrades are effectively instant when the webhook fires first. The alternative (no cache) costs 500k+ unnecessary Firestore reads/week at 100k users and adds 20-50ms latency to every agent stream.

**Files:**
- Modify: `firebase_functions/functions/utils/subscription-gate.js`
- Modify: `firebase_functions/functions/subscriptions/app-store-webhook.js`

**Step 1: Read the current subscription gate**

Read `firebase_functions/functions/utils/subscription-gate.js` (full file, 46 lines).

**Step 2: Read the webhook to find the invalidation point**

Read `firebase_functions/functions/subscriptions/app-store-webhook.js` and find where subscription fields are updated.

**Step 3: Add caching to subscription-gate.js**

Replace the entire file with:

```javascript
// File: firebase_functions/functions/utils/subscription-gate.js
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

const PREMIUM_CACHE_TTL_MS = 60 * 1000; // 1 minute
const premiumCache = new Map();

/**
 * Check if a user has premium access.
 * Uses 1-minute in-memory cache. Call invalidatePremiumCache(userId)
 * after subscription changes for instant invalidation.
 *
 * @param {string} userId
 * @returns {Promise<boolean>}
 */
async function isPremiumUser(userId) {
  if (!userId) {
    return false;
  }

  const cached = premiumCache.get(userId);
  if (cached && Date.now() < cached.expiresAt) {
    return cached.isPremium;
  }

  try {
    const db = admin.firestore();
    const userDoc = await db.collection('users').doc(userId).get();

    if (!userDoc.exists) {
      premiumCache.set(userId, { isPremium: false, expiresAt: Date.now() + PREMIUM_CACHE_TTL_MS });
      return false;
    }

    const userData = userDoc.data();
    const isPremium = userData.subscription_override === 'premium' || userData.subscription_tier === 'premium';

    premiumCache.set(userId, { isPremium, expiresAt: Date.now() + PREMIUM_CACHE_TTL_MS });
    return isPremium;
  } catch (error) {
    logger.error('[subscription-gate] Error checking premium status', { userId, error: error.message });
    return false;
  }
}

/**
 * Invalidate cached premium status for a user.
 * Call this from the subscription webhook after updating subscription fields.
 *
 * @param {string} userId
 */
function invalidatePremiumCache(userId) {
  premiumCache.delete(userId);
}

module.exports = { isPremiumUser, invalidatePremiumCache };
```

**Step 4: Add cache invalidation to the webhook**

In `app-store-webhook.js`, after the line that updates subscription fields, add:

```javascript
const { invalidatePremiumCache } = require('../utils/subscription-gate');
// After subscription field update:
invalidatePremiumCache(userId);
```

**Step 5: Run existing tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass

**Step 6: Commit**

```bash
git add firebase_functions/functions/utils/subscription-gate.js firebase_functions/functions/subscriptions/app-store-webhook.js
git commit -m "perf: add 1-min in-memory cache to subscription gate

Eliminates redundant Firestore read on every isPremiumUser() call.
1-minute TTL with instant invalidation on webhook for upgrade UX.
Saves 500k+ Firestore reads/week at scale.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.2"
```

---

### Task 6: Add GCP Token Caching to exchange-token.js

**Architecture rationale:** GCP access tokens are valid for 60 minutes. The existing pattern in `stream-agent-normalized.js:110-127` already caches tokens with a 55-minute TTL and 5-minute safety margin. We copy this proven pattern to `exchange-token.js`, which currently creates a new `GoogleAuth` instance and fetches a fresh token on every single call. This adds 200-400ms to every iOS session start for zero benefit.

**Files:**
- Modify: `firebase_functions/functions/auth/exchange-token.js`

**Step 1: Read the current exchange-token.js**

Read `firebase_functions/functions/auth/exchange-token.js` (64 lines).

**Step 2: Add token caching**

Add at module level (before `exports.getServiceToken`):

```javascript
// GCP Auth Token Cache — tokens valid for ~60 min, cache for 55 min
let cachedGcpToken = null;
let gcpTokenExpiresAt = 0;

async function getCachedGcpToken() {
  const now = Date.now();
  if (cachedGcpToken && now < gcpTokenExpiresAt - (5 * 60 * 1000)) {
    return cachedGcpToken;
  }

  const auth = new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/cloud-platform']
  });
  const client = await auth.getClient();
  const tokenResponse = await client.getAccessToken();

  cachedGcpToken = tokenResponse.token || tokenResponse;
  gcpTokenExpiresAt = now + (55 * 60 * 1000);

  return cachedGcpToken;
}
```

Then in the handler, replace the 3 lines that create auth/client/token:

```javascript
// BEFORE:
const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
const client = await auth.getClient();
const tokenResponse = await client.getAccessToken();
const accessToken = tokenResponse.token || tokenResponse;

// AFTER:
const accessToken = await getCachedGcpToken();
```

**Step 3: Run existing tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add firebase_functions/functions/auth/exchange-token.js
git commit -m "perf: cache GCP token in exchange-token.js (55-min TTL)

Copy proven pattern from stream-agent-normalized.js:110-127.
Saves 200-400ms per iOS session start.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.3"
```

---

### Task 7: Parallelize get-planning-context Reads

**Architecture rationale:** `get-planning-context.js` makes 4+ sequential Firestore reads where 3 are independent. By using `Promise.all` for independent reads and `firestore.getAll()` for batch template reads (1 RPC regardless of count), we reduce total latency from ~200ms to ~100ms. This is a straightforward parallelization with no risk — read order doesn't matter for independent data.

**Files:**
- Modify: `firebase_functions/functions/agents/get-planning-context.js`

**Step 1: Read the current file**

Read `firebase_functions/functions/agents/get-planning-context.js` to find the sequential reads section (~lines 140-262).

**Step 2: Restructure into parallel phases**

Replace the sequential reads with:

```javascript
// Phase A: All independent reads in parallel
const [userDoc, attrsDoc, workoutsSnapshot] = await Promise.all([
  firestore.collection('users').doc(callerUid).get(),
  firestore.collection('users').doc(callerUid)
    .collection('user_attributes').doc(callerUid).get(),
  includeRecentWorkouts
    ? firestore.collection('users').doc(callerUid)
        .collection('workouts')
        .orderBy('end_time', 'desc')
        .limit(workoutLimit)
        .get()
    : Promise.resolve(null),
]);

const user = userDoc.exists ? userDoc.data() : {};
const attributes = attrsDoc.exists ? attrsDoc.data() : {};

// Phase B: Routine + templates (depends on user.activeRoutineId)
let routine = null;
let templates = [];

if (user.activeRoutineId) {
  const routineDoc = await firestore.collection('users').doc(callerUid)
    .collection('routines').doc(user.activeRoutineId).get();
  routine = routineDoc.exists ? { id: routineDoc.id, ...routineDoc.data() } : null;

  if (routine && routine.template_ids && includeTemplates) {
    const templateRefs = routine.template_ids.map(tid =>
      firestore.collection('users').doc(callerUid).collection('templates').doc(tid)
    );
    if (templateRefs.length > 0) {
      const templateDocs = await firestore.getAll(...templateRefs);
      templates = templateDocs
        .filter(doc => doc.exists)
        .map(doc => ({ id: doc.id, ...doc.data() }));
    }
  }
}
```

**Step 3: Run existing tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass. Response shape must be identical.

**Step 4: Commit**

```bash
git add firebase_functions/functions/agents/get-planning-context.js
git commit -m "perf: parallelize get-planning-context Firestore reads

Phase A (parallel): user + attributes + workouts.
Phase B (sequential, depends on A): routine + templates via getAll().
Reduces latency from ~200ms to ~100ms.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.4"
```

---

### Task 8: Set maxInstances on All Functions

**Architecture rationale:** 64 of 67 functions have no `maxInstances`, meaning GCP can spin up 1,000 instances per function during traffic spikes. This is a bill-shock vector — a single malicious client or bug causing retries could spawn thousands of instances. Setting `maxInstances` by tier provides backpressure without capacity constraints for normal usage. These are all config-only changes in `index.js` — zero code risk.

**Files:**
- Modify: `firebase_functions/functions/index.js`

**Step 1: Read index.js to inventory all exports**

Read `firebase_functions/functions/index.js` to find all v2 function exports that lack `maxInstances`.

**Step 2: Add maxInstances to v2 function exports by tier**

For each v2 function without `maxInstances`, add the appropriate tier:

| Tier | Functions | maxInstances |
|------|-----------|-------------|
| Write-heavy | `logSet`, `upsertWorkout`, `artifactAction`, `completeActiveWorkout` | 50 |
| Read-heavy | `getUserWorkouts`, `getUserTemplates`, `getRoutine`, `getTemplate`, `searchExercises`, `getPlanningContext` | 100 |
| Auth/Token | `exchangeToken`, `getServiceToken` | 30 |
| Standard | All remaining v2 endpoints | 50 |
| Triggers | All Firestore triggers | 30 |

Note: v1 functions don't support `maxInstances`. They'll get it when migrated to v2 (Phase 4).

**Step 3: Run tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All pass (config only)

**Step 4: Commit**

```bash
git add firebase_functions/functions/index.js
git commit -m "perf: set maxInstances on all v2 functions by tier

Prevents runaway scaling and bill shock.
Tiers: write-heavy (50), read-heavy (100), auth (30), standard (50), triggers (30).

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.5"
```

---

### Task 9: Add Rate Limiting to Write Endpoints

**Architecture rationale:** The `rate-limiter.js` already exports `writeLimiter` and `authLimiter` — they're just not wired to any endpoints except `streamAgentNormalized` (which uses `agentLimiter`). This task connects existing infrastructure. Per-instance rate limiting isn't globally accurate, but it provides burst protection at zero latency cost. Global limiting via Redis comes in Phase 3 (Task 21).

**Files:**
- Modify: `firebase_functions/functions/active_workout/log-set.js`
- Modify: `firebase_functions/functions/workouts/upsert-workout.js`
- Modify: `firebase_functions/functions/artifacts/artifact-action.js`
- Modify: `firebase_functions/functions/auth/exchange-token.js`

**Step 1: Read each target file to find the handler entry point**

Read the handler function of each file to find where to insert the rate limit check (after auth, before business logic).

**Step 2: Add writeLimiter to write endpoints**

In each write endpoint handler, after auth middleware resolves `userId`, add:

```javascript
const { writeLimiter } = require('../utils/rate-limiter');
const { fail } = require('../utils/response');

// After userId is resolved:
if (!writeLimiter.check(userId)) {
  return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
}
```

**Step 3: Add authLimiter to exchange-token**

In `exchange-token.js`, after `verifyIdToken` succeeds:

```javascript
const { authLimiter } = require('../utils/rate-limiter');

// After const userId = decodedToken.uid:
if (!authLimiter.check(userId)) {
  return res.status(429).json({ error: 'Rate limited', message: 'Too many auth requests' });
}
```

**Step 4: Run tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All pass

**Step 5: Commit**

```bash
git add firebase_functions/functions/active_workout/log-set.js firebase_functions/functions/workouts/upsert-workout.js firebase_functions/functions/artifacts/artifact-action.js firebase_functions/functions/auth/exchange-token.js
git commit -m "security: wire writeLimiter and authLimiter to 4 endpoints

logSet, upsertWorkout, artifactAction use writeLimiter (60/min).
exchangeToken uses authLimiter (10/min).
Existing per-instance limiters from rate-limiter.js.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.6"
```

---

### Task 10: Request Vertex AI Quota Increase

**Architecture rationale:** Vertex AI Agent Engine defaults to ~10 concurrent sessions per project. At 500 DAU with 2 agent messages/session, peak concurrency easily exceeds 10. This is a GCP Console form submission — zero code, zero risk.

**Files:**
- None (GCP Console only)

**Step 1: Request quota increase**

GCP Console > IAM & Admin > Quotas > filter for "Vertex AI" > "Reasoning Engines" > Request increase to 100 concurrent sessions.

**Step 2: Verify quota appears in console**

Check that the quota increase shows as "Pending" or "Approved".

---

### Task 11: Enable Firebase App Check

**Architecture rationale:** App Check uses Apple's DeviceCheck attestation to verify requests come from legitimate iOS app installs. It blocks automated scripts and bot traffic at the Firebase infrastructure layer — before requests reach Cloud Functions. Setup is ~10 minutes in Firebase Console + a few lines of iOS code. Zero latency impact (attestation token is cached client-side).

**Files:**
- Modify: Firebase Console (App Check)
- Modify: `Povver/Povver/PovverApp.swift` (or app delegate)

**Step 1: Enable App Check in Firebase Console**

Firebase Console > App Check > Register your iOS app with DeviceCheck provider.

**Step 2: Add App Check to iOS app**

```swift
// In PovverApp.swift or AppDelegate:
import FirebaseAppCheck

// In init or application(_:didFinishLaunchingWithOptions:):
let providerFactory = AppCheckDebugProviderFactory() // Use DeviceCheckProviderFactory() in production
AppCheck.setAppCheckProviderFactory(providerFactory)
```

**Step 3: Enable enforcement on critical endpoints**

Firebase Console > App Check > Enforce on: Cloud Functions (start with enforcement in "monitor" mode for 1 week, then enable).

**Step 4: Build and test on simulator**

Run: Build the app with Xcode to verify App Check initializes without errors.

**Step 5: Commit**

```bash
git add Povver/Povver/PovverApp.swift
git commit -m "security: enable Firebase App Check (DeviceCheck attestation)

Blocks automated/bot traffic at infrastructure layer.
Using debug provider for development, DeviceCheck for production.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.7"
```

---

### Task 12: Fix Recommendation Listener Lifecycle

**Architecture rationale:** The recommendation Firestore listener runs for the entire app lifecycle even when the user isn't on the More tab. Moving `startListening()`/`stopListening()` to `onAppear`/`onDisappear` of `MoreView` follows standard SwiftUI lifecycle patterns and eliminates unnecessary Firestore reads.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/MoreView.swift` (or wherever RecommendationsViewModel is used)

**Step 1: Read current listener setup**

Read `RecommendationsViewModel.swift` and `MoreView.swift` to find where the listener starts.

**Step 2: Move listener to MoreView lifecycle**

```swift
// In MoreView.swift:
.onAppear {
    viewModel.startListening()
}
.onDisappear {
    viewModel.stopListening()
}
```

**Step 3: Build and test**

Run: Build the app, navigate to More tab (listener starts), navigate away (listener stops).

**Step 4: Commit**

```bash
git add Povver/Povver/Views/Tabs/MoreView.swift
git commit -m "perf: scope recommendation listener to MoreView lifecycle

Start on onAppear, stop on onDisappear. Eliminates background reads.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 1.9"
```

---

## Phase 2 — UX Speed

### Why this is the most important phase (after safety)

Phase 1 prevents failures. Phase 2 makes the app feel fast. Users currently see a 2.5-4 second blank screen on every login. The exercise catalog (500+ exercises) is re-fetched from Firestore on every Library tab visit. Workout history loads every single workout document regardless of scroll position. These are the UX improvements users will actually feel.

**Complexity:** Medium | **Risk:** Medium (client-side changes affect UX, need careful testing) | **Scalability Benefit:** 80% reduction in Firestore reads; app launch from 2.5s to <500ms; paginated history prevents OOM on large histories

---

### Task 13: Fix iOS App Launch Waterfall

**Architecture rationale:** The current `RootView` blocks on `SessionPreWarmer.preWarmIfNeeded()` and `prefetchLibraryData()` BEFORE setting `flow = .main`. Both operations are fire-and-forget background work — the user doesn't need their results to see the tab bar. By flipping the order (set `flow = .main` immediately, then fire background tasks), the user sees the app instantly. Each tab loads its own data with skeleton states.

**Files:**
- Modify: `Povver/Povver/Views/RootView.swift:~49-56`
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift:~63-66`
- Modify: `Povver/Povver/Views/MainTabsView.swift:~138-145`

**Step 1: Read RootView.swift**

Read `Povver/Povver/Views/RootView.swift` to find the `.onChange(of: authService.isAuthenticated)` block.

**Step 2: Show MainTabsView immediately**

```swift
// BEFORE (blocks):
.onChange(of: authService.isAuthenticated) { _, isAuth in
    if isAuth {
        Task {
            await SessionPreWarmer.shared.preWarmIfNeeded()
            await FocusModeWorkoutService.shared.prefetchLibraryData()
        }
        flow = .main
    }
}

// AFTER (immediate):
.onChange(of: authService.isAuthenticated) { _, isAuth in
    if isAuth {
        flow = .main  // Show tabs IMMEDIATELY
        Task {
            await SessionPreWarmer.shared.preWarmIfNeeded()
            await FocusModeWorkoutService.shared.prefetchLibraryData()
        }
    }
}
```

**Step 3: Remove redundant pre-warm from CoachTabView**

Read `Povver/Povver/Views/Tabs/CoachTabView.swift` and remove the redundant `SessionPreWarmer.preWarmIfNeeded()` call in `.onAppear`.

**Step 4: Remove redundant prefetch from MainTabsView**

Read `Povver/Povver/Views/MainTabsView.swift` and remove the fallback `prefetchLibraryData()` call.

**Step 5: Build and test**

Run: Build on simulator, login, verify MainTabsView appears immediately.

**Step 6: Commit**

```bash
git add Povver/Povver/Views/RootView.swift Povver/Povver/Views/Tabs/CoachTabView.swift Povver/Povver/Views/MainTabsView.swift
git commit -m "perf: show MainTabsView immediately on login (non-blocking prefetch)

Move flow = .main before async prefetch. Remove redundant pre-warm
from CoachTabView and redundant prefetch from MainTabsView.
App launch: 2.5-4s -> <500ms.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 2.1"
```

---

### Task 14: Wire CacheManager into Repositories

**Architecture rationale:** `CacheManager.swift` is a complete actor-based memory+disk cache with configurable TTL — already implemented, zero call sites. Meanwhile, `ExerciseRepository` fetches 500+ exercises from Firestore on every Library tab visit. Wiring existing infrastructure saves 80% of redundant Firestore reads. TTLs are conservative: 60 minutes for near-immutable exercise catalog, 5 minutes for user-mutable templates/routines with instant invalidation on mutations.

**Files:**
- Modify: `Povver/Povver/Repositories/ExerciseRepository.swift`
- Modify: `Povver/Povver/Repositories/TemplateRepository.swift`
- Modify: `Povver/Povver/Repositories/RoutineRepository.swift`

**Step 1: Read CacheManager.swift API**

Read `Povver/Povver/Services/CacheManager.swift` to understand the `get`/`set`/`remove` API.

**Step 2: Read ExerciseRepository.swift**

Read the current implementation to find the fetch method.

**Step 3: Add caching to ExerciseRepository (60-min TTL)**

```swift
func getExercises() async throws -> [Exercise] {
    let cacheKey = "exercises:all"
    if let cached: [Exercise] = await CacheManager.shared.get(cacheKey) {
        return cached
    }

    let exercises = try await fetchFromFirestore()
    await CacheManager.shared.set(cacheKey, value: exercises, ttl: 3600)
    return exercises
}
```

**Step 4: Add caching to TemplateRepository (5-min TTL + invalidation)**

```swift
func getUserTemplates(userId: String) async throws -> [WorkoutTemplate] {
    let cacheKey = "templates:\(userId)"
    if let cached: [WorkoutTemplate] = await CacheManager.shared.get(cacheKey) {
        return cached
    }

    let templates = try await fetchFromFirestore(userId: userId)
    await CacheManager.shared.set(cacheKey, value: templates, ttl: 300)
    return templates
}

// In mutation methods (create/update/delete):
await CacheManager.shared.remove("templates:\(userId)")
```

**Step 5: Apply same pattern to RoutineRepository**

Same as TemplateRepository with `routines:\(userId)` cache key and 5-min TTL.

**Step 6: Build and test**

Run: Build on simulator. Open Library tab (cache miss -> Firestore fetch). Navigate away, come back (cache hit -> instant). Create a template -> verify it appears immediately (cache invalidated).

**Step 7: Commit**

```bash
git add Povver/Povver/Repositories/ExerciseRepository.swift Povver/Povver/Repositories/TemplateRepository.swift Povver/Povver/Repositories/RoutineRepository.swift
git commit -m "perf: wire CacheManager into Exercise, Template, Routine repositories

Exercise catalog: 60-min TTL (near-immutable).
Templates/Routines: 5-min TTL + instant invalidation on mutations.
Eliminates ~80% of redundant Firestore reads per session.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 2.2"
```

---

### Task 15: Add Server-Side Workout History Pagination

**Architecture rationale:** The current `HistoryView` fetches ALL workouts from Firestore and paginates client-side. For a user with 200 workouts, that's 200 document reads on every History tab visit. Cursor-based pagination (using `startAfter` with the last document) is the standard Firestore pattern — it reads only 25 documents per page and supports infinite scrolling. The `limit + 1` technique determines `hasMore` without a separate count query.

**Files:**
- Modify: `firebase_functions/functions/workouts/get-user-workouts.js`
- Modify: `Povver/Povver/Repositories/WorkoutRepository.swift`
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift`

**Step 1: Read the current backend endpoint**

Read `firebase_functions/functions/workouts/get-user-workouts.js` to understand current query structure.

**Step 2: Add pagination parameters to backend**

```javascript
const limit = Math.min(parseInt(req.query.limit) || 25, 100);
const startAfter = req.query.startAfter;

let query = firestore.collection('users').doc(userId)
  .collection('workouts')
  .orderBy('end_time', 'desc')
  .limit(limit + 1);

if (startAfter) {
  const cursorDoc = await firestore.collection('users').doc(userId)
    .collection('workouts').doc(startAfter).get();
  if (cursorDoc.exists) {
    query = query.startAfter(cursorDoc);
  }
}

const snapshot = await query.get();
const workouts = snapshot.docs.slice(0, limit).map(doc => ({ id: doc.id, ...doc.data() }));
const hasMore = snapshot.docs.length > limit;

return ok(res, {
  workouts,
  hasMore,
  cursor: workouts.length > 0 ? workouts[workouts.length - 1].id : null
});
```

**Step 3: Run backend tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All pass

**Step 4: Read the current iOS WorkoutRepository**

Read `Povver/Povver/Repositories/WorkoutRepository.swift` to find the `getWorkouts` method.

**Step 5: Add paginated fetch to WorkoutRepository**

Add a new method (keep existing for backward compatibility if needed):

```swift
func getWorkoutsPaginated(userId: String, limit: Int = 25, startAfter: String? = nil) async throws -> (workouts: [Workout], hasMore: Bool, cursor: String?) {
    // Call the updated backend endpoint with limit and startAfter params
}
```

**Step 6: Update HistoryView to use cursor pagination**

Replace the full-collection fetch with incremental loading using the paginated method.

**Step 7: Build and test**

Run: Build on simulator, open History tab, verify 25 workouts load. Scroll to bottom, verify "Load More" fetches next 25.

**Step 8: Commit**

```bash
git add firebase_functions/functions/workouts/get-user-workouts.js Povver/Povver/Repositories/WorkoutRepository.swift Povver/Povver/Views/Tabs/HistoryView.swift
git commit -m "perf: server-side workout history pagination (cursor-based)

Backend: limit + startAfter params, limit+1 technique for hasMore.
iOS: cursor-based pagination in HistoryView, loads 25 per page.
User with 200 workouts: 200 reads -> 25 reads on first visit.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 2.3"
```

---

## Phase 3 — Scale Infrastructure

### Why this is the most important phase (for 10k+ users)

Phase 3 addresses the structural issues that will break between 10k-25k users. The SSE proxy can't use concurrency > 1 due to race conditions (each stream gets its own instance — expensive). Workout completion triggers 126 Firestore writes synchronously (timeouts, retries, inflated data). Rate limiting is per-instance only (bypassed by hitting different instances). These are the engineering investments that buy 10x headroom.

**Complexity:** High | **Risk:** Medium-High (code refactors, new infrastructure, background workers) | **Scalability Benefit:** SSE 100 -> 2,000 concurrent; trigger writes 126 -> 13 sync; global rate limiting; training analyst 10x throughput

---

### Task 16: Fix SSE Race Conditions (Move Shared State into Request Scope)

**Architecture rationale:** `stream-agent-normalized.js` declares `eventStartTimes`, `toolArgsCache`, and `currentActiveAgent` at module level (lines 453-457). In Node.js Cloud Functions v2 with `concurrency > 1`, multiple requests share the same module scope — meaning Stream A's tool timing data bleeds into Stream B. The fix is straightforward: create a per-request state object and pass it through closures. This is the standard pattern for concurrent Node.js — no new dependencies, no architecture changes.

The token cache thundering-herd fix uses a promise singleton: if a refresh is in flight, subsequent callers await the same promise instead of triggering parallel refreshes.

**Files:**
- Modify: `firebase_functions/functions/strengthos/stream-agent-normalized.js`

**Step 1: Read the full handler to understand state usage**

Read `firebase_functions/functions/strengthos/stream-agent-normalized.js` lines 440-600 to trace how `eventStartTimes`, `toolArgsCache`, and `currentActiveAgent` are used.

**Step 2: Create per-request state factory**

Replace lines 452-457 (module-level state) with a factory function:

```javascript
// REMOVE these module-level declarations:
// const eventStartTimes = new Map();
// const toolArgsCache = new Map();
// let currentActiveAgent = 'orchestrator';

// ADD this factory function:
function createRequestState() {
  return {
    eventStartTimes: new Map(),
    toolArgsCache: new Map(),
    currentActiveAgent: 'orchestrator',
  };
}
```

**Step 3: Pass request state through the handler**

In the `streamAgentNormalizedHandler` function, create state at the start:

```javascript
const requestState = createRequestState();
```

Then update all references to `eventStartTimes`, `toolArgsCache`, and `currentActiveAgent` to use `requestState.eventStartTimes`, `requestState.toolArgsCache`, `requestState.currentActiveAgent`.

**Step 4: Refactor transformToIOSEvent to accept request state**

```javascript
function createTransformer(requestState) {
  return function transformToIOSEvent(adkEvent) {
    // Use requestState.currentActiveAgent instead of currentActiveAgent
    // Use requestState.eventStartTimes instead of eventStartTimes
    // Use requestState.toolArgsCache instead of toolArgsCache
    // ... rest of transform logic unchanged
  };
}
```

**Step 5: Fix token cache thundering herd**

```javascript
let tokenRefreshPromise = null;

async function getGcpAuthToken() {
  const now = Date.now();
  if (cachedGcpToken && now < tokenExpiresAt - TOKEN_BUFFER_MS) {
    return cachedGcpToken;
  }
  if (!tokenRefreshPromise) {
    tokenRefreshPromise = (async () => {
      const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
      cachedGcpToken = await auth.getAccessToken();
      tokenExpiresAt = Date.now() + (55 * 60 * 1000);
      tokenRefreshPromise = null;
      return cachedGcpToken;
    })();
  }
  return tokenRefreshPromise;
}
```

**Step 6: Run tests**

Run: `cd firebase_functions/functions && npm test`
Expected: All pass

**Step 7: Commit**

```bash
git add firebase_functions/functions/strengthos/stream-agent-normalized.js
git commit -m "fix: move SSE shared state into request scope, fix token thundering herd

Move eventStartTimes, toolArgsCache, currentActiveAgent from module
level into per-request state factory. Eliminates cross-stream data
corruption when concurrency > 1.

Fix token cache thundering herd with promise singleton pattern.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 3.1"
```

---

### Task 17: Raise SSE Concurrency After Race Fix

**Architecture rationale:** With race conditions fixed in Task 16, each Cloud Functions instance can safely handle 10 concurrent SSE streams. 200 instances x 10 streams = 2,000 concurrent streams — enough for 25k+ users. No `minInstances` — evaluate post-launch when revenue justifies always-on instances (see Monthly Paid Improvements).

**Files:**
- Modify: `firebase_functions/functions/index.js:~234`

**Step 1: Update SSE config**

```javascript
exports.streamAgentNormalized = onRequestV2(
  {
    timeoutSeconds: 540,
    memory: '512MiB',
    maxInstances: 200,        // Was: 100 (Phase 1). 200 x 10 = 2,000 concurrent streams.
    concurrency: 10,          // NOW SAFE after Task 16 race condition fix.
  },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);
```

**Step 2: Deploy to staging first with concurrency: 2**

Deploy with `concurrency: 2` first. Open 2+ concurrent conversations from same browser. Verify no cross-contamination of tool timing or agent attribution.

**Step 3: Raise to concurrency: 10 after verification**

After confirming no issues, deploy with `concurrency: 10`.

**Step 4: Run tests**

Run: `cd firebase_functions/functions && npm test`

**Step 5: Commit**

```bash
git add firebase_functions/functions/index.js
git commit -m "perf: raise SSE concurrency to 10 after race condition fix

200 instances x 10 streams = 2,000 concurrent streams.
Safe after Task 16 moved shared state to request scope.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 3.1"
```

---

### Task 18: Implement Async Analytics (Hybrid Model)

**Architecture rationale:** Workout completion currently triggers 126 synchronous Firestore writes. The hybrid model keeps 13 essential user-facing writes synchronous (weekly_stats, analytics_rollups, exercise_usage_stats) and enqueues the remaining 113 agent-facing writes to a background worker. This is better than full-async (which delays user-visible data) and better than full-sync (which times out and retries). The background worker uses batched writes (1 commit vs 113 individual writes) and has full idempotency.

**Files:**
- Modify: `firebase_functions/functions/triggers/weekly-analytics.js`
- Create: `firebase_functions/functions/workers/analytics-processor.js`
- Modify: `firebase_functions/functions/index.js`

**Step 1: Read the current trigger**

Read `firebase_functions/functions/triggers/weekly-analytics.js` lines 430-788 to understand the full trigger flow and identify which writes are user-facing vs agent-facing.

**Step 2: Slim the trigger to essential writes only**

Keep synchronous:
- `weekly_stats` update (1 write)
- `analytics_rollups` update (1 write)
- `exercise_usage_stats` updates (10 writes)
- `analytics_state/current` watermark (1 write)

Enqueue everything else:

```javascript
// After essential writes complete:
await db.collection('analytics_processing_queue').add({
  type: 'WORKOUT_ANALYTICS',
  userId,
  workoutId,
  status: 'queued',
  created_at: admin.firestore.FieldValue.serverTimestamp(),
  workout_snapshot: workoutData,
});
```

**Step 3: Create the background worker**

```javascript
// File: firebase_functions/functions/workers/analytics-processor.js
// Triggered by analytics_processing_queue writes
// Processes: set_facts, series_*, training_analysis_jobs
// Uses batched writes, full idempotency, retry with backoff
```

**Step 4: Export the worker in index.js**

Add the new function export to `index.js`.

**Step 5: Run tests**

Run: `cd firebase_functions/functions && npm test`

**Step 6: Commit**

```bash
git add firebase_functions/functions/triggers/weekly-analytics.js firebase_functions/functions/workers/analytics-processor.js firebase_functions/functions/index.js
git commit -m "perf: hybrid async analytics - 126 sync writes to 13 sync + 113 async

Essential user-facing writes stay synchronous (weekly_stats, rollups,
exercise_usage_stats). Heavy agent-facing writes (set_facts, series_*,
training_analysis) enqueued to background worker.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 3.2"
```

---

### Task 19: Fix Trigger Idempotency

**Architecture rationale:** Firestore triggers are "at-least-once" — if a trigger times out, it retries. Currently only 2 of 9 write paths check for duplicate processing. The `FieldValue.increment()` calls in series updates are particularly dangerous: retries inflate stats permanently. A global idempotency fence using a `workout_processing` subcollection (check status before processing, mark complete after) prevents all retries from causing data corruption. The 7-day TTL prevents unbounded growth.

**Files:**
- Modify: `firebase_functions/functions/triggers/weekly-analytics.js`

**Step 1: Read the trigger entry point**

Read `firebase_functions/functions/triggers/weekly-analytics.js` to find the `onWorkoutCompleted` entry.

**Step 2: Add idempotency fence at trigger start**

```javascript
// At top of onWorkoutCompleted:
const processingRef = db.collection('users').doc(userId)
  .collection('workout_processing').doc(workoutId);

const existing = await processingRef.get();
if (existing.exists && existing.data().status === 'completed') {
  logger.info('[onWorkoutCompleted] Already processed, skipping', { userId, workoutId });
  return;
}

await processingRef.set({
  status: 'processing',
  started_at: admin.firestore.FieldValue.serverTimestamp(),
  expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000), // TTL: 7 days
});

// ... do all analytics work ...

await processingRef.update({
  status: 'completed',
  completed_at: admin.firestore.FieldValue.serverTimestamp(),
});
```

**Step 3: Apply same pattern to onWorkoutCreatedWithEnd**

The second trigger also needs the fence.

**Step 4: Run tests**

Run: `cd firebase_functions/functions && npm test`

**Step 5: Commit**

```bash
git add firebase_functions/functions/triggers/weekly-analytics.js
git commit -m "fix: add idempotency fence to workout completion triggers

Check workout_processing/{workoutId} before processing.
Prevents duplicate writes on trigger retry (at-least-once semantics).
7-day TTL on processing docs.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 3.3"
```

---

### Task 20: Set Up Firestore TTL Policies

**Architecture rationale:** Several collections grow without bounds. `set_facts` at 10k users generates 45 docs/user/week = 23M docs/year. Firestore TTL policies automatically delete expired documents — zero code, zero cron jobs, zero cost for deletions. The `expires_at` field is set at write time; Firestore handles cleanup.

**Files:**
- Modify: `firebase_functions/functions/training/set-facts-generator.js` (add `expires_at`)
- Modify: `firebase_functions/functions/active_workout/log-set.js` (add `expires_at` to idempotency docs)
- GCP CLI: Deploy TTL policies

**Step 1: Read set-facts-generator.js**

Read `firebase_functions/functions/training/set-facts-generator.js` to find where set_facts documents are created.

**Step 2: Add expires_at to set_facts writes**

In the set_facts document creation, add:

```javascript
expires_at: new Date(workoutDate.getTime() + 2 * 365 * 24 * 60 * 60 * 1000) // 2-year TTL
```

**Step 3: Add expires_at to idempotency docs in log-set.js**

Read `firebase_functions/functions/active_workout/log-set.js` and add to idempotency doc writes:

```javascript
expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000) // 7-day TTL
```

**Step 4: Deploy TTL policies via gcloud**

```bash
gcloud firestore fields ttls update expires_at \
  --collection-group=set_facts \
  --project=myon-53d85

gcloud firestore fields ttls update expires_at \
  --collection-group=workout_processing \
  --project=myon-53d85

gcloud firestore fields ttls update expires_at \
  --collection-group=idempotency \
  --project=myon-53d85
```

**Step 5: Run tests**

Run: `cd firebase_functions/functions && npm test`

**Step 6: Commit**

```bash
git add firebase_functions/functions/training/set-facts-generator.js firebase_functions/functions/active_workout/log-set.js
git commit -m "perf: add expires_at fields for Firestore TTL auto-cleanup

set_facts: 2-year TTL. idempotency/workout_processing: 7-day TTL.
Deploy TTL policies via gcloud firestore fields ttls update.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 3.5"
```

---

### ~~Task 21: Deploy Redis Global Rate Limiting~~ → Deferred to Monthly Paid Improvements

> **Moved to [Monthly Paid Improvements](#monthly-paid-improvements-post-revenue)** — requires Memorystore Redis (~$50/month) + VPC connector. Per-instance rate limiting (Tasks 8-9) provides burst protection at zero cost until revenue justifies global limiting.

---

### Task 21: Scale Training Analyst Worker

**Architecture rationale:** Training analyst Cloud Run Job runs with `parallelism: 1` — sequential processing. At 10k users generating 23k analysis jobs/week, sequential processing takes ~32 hours. Setting `parallelism: 10` gives 10x throughput with zero code changes. Jobs already use unique document IDs for deduplication.

**Files:**
- Modify: `adk_agent/training_analyst/cloud-run-worker.yaml` (or equivalent config)

**Step 1: Read current config**

Read `adk_agent/training_analyst/cloud-run-worker.yaml` to find the current `parallelism` setting.

**Step 2: Raise parallelism to 10**

```yaml
parallelism: 10  # Was: 1
```

**Step 3: Deploy and verify**

Deploy the updated worker config and verify it processes jobs in parallel.

**Step 4: Commit**

```bash
git add adk_agent/training_analyst/cloud-run-worker.yaml
git commit -m "perf: raise training analyst parallelism to 10

10x throughput for background analysis jobs.
Scales to ~100k users before needing Cloud Tasks migration.

Ref: docs/plans/2026-02-27-performance-scalability-design.md Phase 3.6"
```

---

### Task 22: Update Documentation

**Files:**
- Modify: `docs/SYSTEM_ARCHITECTURE.md`
- Modify: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
- Modify: `docs/IOS_ARCHITECTURE.md`
- Modify: `docs/FIRESTORE_SCHEMA.md`
- Modify: `docs/SECURITY.md`

**Step 1: Update SYSTEM_ARCHITECTURE.md**

Add notes about:
- SSE concurrency model (per-request state, concurrency: 10)
- Hybrid analytics model (sync essential writes + async worker)
- Per-instance rate limiting tiers

**Step 2: Update FIREBASE_FUNCTIONS_ARCHITECTURE.md**

Document:
- `analytics-processor.js` worker
- `analytics_processing_queue` collection
- maxInstances tiers
- Rate limiting tiers

**Step 3: Update IOS_ARCHITECTURE.md**

Document:
- CacheManager wiring in repositories
- Non-blocking app launch
- Paginated workout history

**Step 4: Update FIRESTORE_SCHEMA.md**

Add:
- `workout_processing` subcollection (idempotency fence)
- `analytics_processing_queue` collection
- TTL fields (`expires_at`) on `set_facts`, `idempotency`, `workout_processing`

**Step 5: Update SECURITY.md**

Document:
- Rate limiting tiers (per-instance in-memory)
- maxInstances tiers
- App Check enforcement

**Step 6: Commit**

```bash
git add docs/SYSTEM_ARCHITECTURE.md docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md docs/IOS_ARCHITECTURE.md docs/FIRESTORE_SCHEMA.md docs/SECURITY.md
git commit -m "docs: update architecture docs for performance/scalability changes

SSE concurrency model, hybrid analytics, global rate limiting,
CacheManager wiring, pagination, TTL policies, App Check.

Ref: docs/plans/2026-02-27-performance-scalability-design.md"
```

---

## Summary: Complexity, Risk, and Benefit Matrix

| Task | Phase | Complexity | Risk | Scalability Benefit |
|------|-------|-----------|------|---------------------|
| 1-3: Observability | 0 | Low | Low | Enables all subsequent measurement |
| 4: SSE maxInstances | 1 | Low | Low | 20 -> 100 concurrent streams |
| 5: Subscription cache | 1 | Low | Low | -500k Firestore reads/week at scale |
| 6: Token cache | 1 | Low | Low | -200ms per session start |
| 7: Parallel reads | 1 | Low | Low | -100ms per agent message |
| 8: maxInstances all | 1 | Low | Low | Bill shock protection |
| 9: Rate limiting | 1 | Low | Low | Abuse protection on write endpoints |
| 10: Vertex AI quota | 1 | Low | Low | 10 -> 100 concurrent agent sessions |
| 11: App Check | 1 | Low | Low | Block bot traffic |
| 12: Listener cleanup | 1 | Low | Low | Eliminate background reads |
| 13: App launch | 2 | Medium | Medium | 2.5s -> <500ms launch |
| 14: CacheManager | 2 | Medium | Medium | -80% Firestore reads |
| 15: Pagination | 2 | Medium | Medium | O(n) -> O(25) per History visit |
| 16: SSE race fix | 3 | High | Medium | Unlocks concurrency > 1 |
| 17: SSE concurrency | 3 | Low | Low | 100 -> 2,000 concurrent streams |
| 18: Async analytics | 3 | High | High | 126 -> 13 sync writes per workout |
| 19: Idempotency | 3 | Medium | Medium | Prevents data corruption on retry |
| 20: TTL policies | 3 | Low | Low | Prevents unbounded collection growth |
| 21: Analyst scaling | 3 | Low | Low | 10x background analysis throughput |
| 22: Update docs | 3 | Low | Low | Keeps architecture docs accurate |

---

## Monthly Paid Improvements (Post-Revenue)

These improvements have recurring monthly costs. They should be evaluated once the app generates revenue. Each item includes the cost, the scaling threshold where it becomes necessary, and the performance benefit.

### M1: SSE minInstances (Eliminate Cold Starts)

**Monthly cost:** ~$30-75/month (2-5 warm instances)
**When to deploy:** When P95 agent response time shows cold start spikes in Cloud Monitoring dashboards, or when user complaints about initial agent message delay become frequent.

**What it does:** Keeps 2-5 Cloud Function instances always running so the first agent request never hits a cold start (2-4s penalty). Without this, the first user after a quiet period waits noticeably longer.

```javascript
// In index.js, streamAgentNormalized config:
minInstances: 2,  // Start with 2, raise based on traffic patterns
```

**Decision trigger:** Check Cloud Monitoring for `execution_start_type=cold` frequency. If >10% of SSE invocations are cold starts during peak hours, deploy this.

---

### M2: Global Rate Limiting via Redis

**Monthly cost:** ~$50/month (Memorystore basic 1GB) + VPC connector
**When to deploy:** When per-instance rate limiting is provably insufficient — likely at 10k+ users where requests spread across 50+ instances, making per-instance limits ineffective.

**What it does:** Replaces the current per-instance `Map()` rate limiter with a shared Redis instance that provides globally accurate rate limiting. Atomic `INCR + EXPIRE` at 1-5ms latency.

**Why not Firestore instead:** Firestore writes add 200-600ms latency per rate limit check, eventual consistency across regions is exploitable, and 10k+ writes/sec to a `rate_limits` collection costs more than Redis.

**Infrastructure required:**
```bash
# 1. Deploy Redis
gcloud redis instances create povver-rate-limiter \
  --size=1 --region=us-central1 --tier=basic --project=myon-53d85

# 2. VPC connector (Cloud Functions -> Memorystore)
gcloud compute networks vpc-access connectors create povver-vpc \
  --region=us-central1 --range=10.8.0.0/28 --project=myon-53d85
```

**Code changes:** Add `redis` npm dependency, `checkGlobalRateLimit()` in `rate-limiter.js`, wire into `streamAgentNormalized` and write endpoints. See design doc Phase 3.4 for full implementation.

**Decision trigger:** Check if abuse is happening across multiple instances (a single user exceeding intended limits because per-instance limiters reset on different instances). Or when maxInstances > 50 on write-heavy endpoints.

