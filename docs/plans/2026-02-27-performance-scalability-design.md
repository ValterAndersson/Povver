# Performance & Scalability Design — Povver Platform

> **Document Purpose**: Comprehensive performance and scalability audit with ranked implementation plan. Written for LLM/agentic coding agents to execute without ambiguity.
>
> **Created**: 2026-02-27
> **Revised**: 2026-03-04 — Principal architect review with multi-agent adversarial validation. Corrected write counts (126 vs original 35-45), identified SSE race conditions blocking concurrency >1, added Phase 0 (observability), added missing security items, corrected rate limiting approach (Redis over Firestore), removed phantom workspace_entries claim.
> **Status**: Revised design, ready for implementation planning
> **Scope**: Full-stack review — iOS, Firebase Functions, Firestore, Vertex AI Agent Engine
> **Target**: Scale from current (<1k users) to 10k users (3-month horizon), architected for 100k

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Review Findings (2026-03-04)](#architecture-review-findings-2026-03-04)
3. [Current Architecture Quick Reference](#current-architecture-quick-reference)
4. [Phase 0 — Observability Foundation (Week 0)](#phase-0--observability-foundation-week-0)
   - [0.1 Cloud Monitoring Dashboards](#01-cloud-monitoring-dashboards)
   - [0.2 Alerting Rules](#02-alerting-rules)
   - [0.3 Cost Tracking](#03-cost-tracking)
5. [Phase 1 — Emergency Fixes (Weeks 1–2)](#phase-1--emergency-fixes-weeks-12)
   - [1.1 SSE Proxy Connection Cap (Conservative)](#11-sse-proxy-connection-cap-conservative)
   - [1.2 Subscription Gate Caching](#12-subscription-gate-caching)
   - [1.3 GCP Token Caching in exchange-token](#13-gcp-token-caching-in-exchange-token)
   - [1.4 Parallelize get-planning-context Reads](#14-parallelize-get-planning-context-reads)
   - [1.5 Set maxInstances on All Functions](#15-set-maxinstances-on-all-functions)
   - [1.6 Add Rate Limiting to Write Endpoints](#16-add-rate-limiting-to-write-endpoints)
   - [1.7 Enable Firebase App Check](#17-enable-firebase-app-check)
   - [1.8 Request Vertex AI Quota Increase](#18-request-vertex-ai-quota-increase)
   - [1.9 Recommendation Listener Cleanup](#19-recommendation-listener-cleanup)
6. [Phase 2 — UX Speed (Weeks 3–4)](#phase-2--ux-speed-weeks-34)
   - [2.1 iOS App Launch Waterfall](#21-ios-app-launch-waterfall)
   - [2.2 Repository Caching](#22-repository-caching)
   - [2.3 Server-Side Workout History Pagination](#23-server-side-workout-history-pagination)
7. [Phase 3 — Scale Infrastructure (Month 2)](#phase-3--scale-infrastructure-month-2)
   - [3.1 Fix SSE Race Conditions + Raise Concurrency](#31-fix-sse-race-conditions--raise-concurrency)
   - [3.2 Async Analytics Processing (Hybrid Model)](#32-async-analytics-processing-hybrid-model)
   - [3.3 Fix Trigger Idempotency](#33-fix-trigger-idempotency)
   - [3.4 Global Rate Limiting (Redis)](#34-global-rate-limiting-redis)
   - [3.5 Firestore TTL Policies](#35-firestore-ttl-policies)
   - [3.6 Training Analyst Horizontal Scaling](#36-training-analyst-horizontal-scaling)
8. [Phase 4 — Optimization (Deferred)](#phase-4--optimization-deferred)
   - [4.1 Function Bundle Splitting](#41-function-bundle-splitting)
   - [4.2 v1 to v2 Function Migration](#42-v1-to-v2-function-migration)
   - [4.3 Expand Fast Lane Patterns](#43-expand-fast-lane-patterns)
   - [4.4 Evaluate Cloud Run for SSE](#44-evaluate-cloud-run-for-sse)
9. [Appendix A — Current Bottleneck Map](#appendix-a--current-bottleneck-map)
10. [Appendix B — Cost Projections (Revised)](#appendix-b--cost-projections-revised)
11. [Appendix C — File Reference Index](#appendix-c--file-reference-index)
12. [Appendix D — Scaling Thresholds](#appendix-d--scaling-thresholds)

---

## Executive Summary

### Would the system scale to 10k concurrent users today?

**No.** Five critical blockers (revised from original three after multi-agent code review):

1. **SSE streaming capped at 20 concurrent connections** — `streamAgentNormalized` is configured with `maxInstances: 20, concurrency: 1` (index.js:234). User #21 gets a 503 error. **Additionally, concurrency cannot be raised above 1 without code changes** — module-level shared mutable state (`eventStartTimes`, `toolArgsCache`, `currentActiveAgent` at lines 453-457 of stream-agent-normalized.js) would cause cross-stream data corruption.

2. **Workout completion triggers ~126 synchronous Firestore writes** (revised from original 35–45 estimate). Breakdown: 30 set_facts + 28 series batch writes + 28 min/max transactions + 10 e1rm transactions + 10 exercise_usage_stats + 8 analytics rollups + 1 analysis job + ~11 other. Two analytics systems (legacy + token-safe) run in parallel. At 10k users × 4 workouts/week = 5M trigger writes/week.

3. **Rate limiting is per-instance AND only covers 1 of 67 endpoints** — The in-memory `Map()` resets on cold starts and only `streamAgentNormalized` uses it. The other 66 endpoints (including write-heavy ones like `upsertWorkout`, `logSet`, `artifactAction`) have zero rate limiting and no `maxInstances` caps.

4. **Vertex AI Agent Engine default quota: 10 concurrent sessions** — This will be hit before the SSE cap. Must request quota increase via GCP Console.

5. **Zero observability** — No monitoring dashboards, no alerting rules, no cost tracking. Cannot detect or respond to scaling issues.

### What's already good?

- **Local-first iOS workout tracking** — Optimistic UI updates mean users never wait for Firestore during set logging. Well-architected `MutationCoordinator` pattern.
- **4-lane agent routing** — Fast Lane bypasses LLM entirely for copilot commands (`"done"`, `"8 @ 100"`). Sub-500ms latency.
- **HTTP connection pooling** — Agent-to-Firebase calls reuse TCP connections via `requests.Session()` with `HTTPAdapter(pool_connections=10, pool_maxsize=20)`.
- **Pre-computed training analysis** — Heavy analytics are pre-computed by background workers, not computed on-demand.
- **ContextVar isolation** — Per-request state isolation prevents cross-user data leaks in concurrent Vertex AI environments.
- **Firestore is the right database** — Cost analysis confirms Firestore is cheaper and simpler than PostgreSQL up to 100k users. Migration would increase costs and break real-time iOS UX.
- **Self-compacting series data** — `analytics_series_exercise` has weekly compaction jobs that prevent document growth.

### Implementation Roadmap (Revised)

| Phase | Duration | Items | Key Metric |
|-------|----------|-------|------------|
| **Phase 0: Observability** | Week 0 (parallel with Phase 1) | #0.1–#0.3 | Dashboards + alerts + cost tracking live |
| **Phase 1: Emergency** | Weeks 1–2 | #1.1–#1.9 | SSE capacity 20→100; all endpoints capped; App Check enabled |
| **Phase 2: UX Speed** | Weeks 3–4 | #2.1–#2.3 | App launch improved; Firestore reads -80%; paginated history |
| **Phase 3: Scale Infra** | Month 2 | #3.1–#3.6 | SSE 100→2,000 (after race fix); trigger writes 126→20 sync; global rate limiting |
| **Phase 4: Optimize** | Deferred until >10k users | #4.1–#4.4 | Bundle splitting; v1→v2 migration; Fast Lane expansion |

---

## Current Architecture Quick Reference

Read these docs before starting any implementation:

| Doc | Path | What It Covers |
|-----|------|----------------|
| System Architecture | `docs/SYSTEM_ARCHITECTURE.md` | Cross-layer data flows, schema contracts, auth patterns |
| Firebase Functions | `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` | All endpoints, auth middleware, trigger documentation |
| iOS Architecture | `docs/IOS_ARCHITECTURE.md` | MVVM layers, services, repositories, views |
| Shell Agent | `docs/SHELL_AGENT_ARCHITECTURE.md` | 4-lane routing, ContextVars, tool definitions |
| Firestore Schema | `docs/FIRESTORE_SCHEMA.md` | All collections, document shapes, indexes, security rules |
| Security | `docs/SECURITY.md` | Auth model, IDOR prevention, input validation, rate limiting |

### Request Flow (Happy Path — Agent Streaming)

```
iOS App (DirectStreamingService.swift)
  │ POST /streamAgentNormalized (SSE)
  ▼
Firebase Function (stream-agent-normalized.js)
  │ 1. requireFlexibleAuth → verifyIdToken (JWT, ~5ms cached)
  │ 2. isPremiumUser(userId) → Firestore read (~30ms, NO CACHE) ← FIX #1.2
  │ 3. rateLimiter.check(userId) → in-memory Map (~0ms) ← FIX #3.2
  │ 4. getGcpToken() → cached or refresh (~10-200ms)
  │ 5. POST to Vertex AI :streamQuery (SSE)
  ▼
Vertex AI Agent Engine (agent_engine_app.py)
  │ 1. Parse context prefix → SessionContext
  │ 2. set_current_context(ctx)
  │ 3. route_request(message) → Lane routing
  │ 4. If Slow Lane: ShellAgent.run() → LLM + tools
  │    └─ tool_get_planning_context() → HTTP to Firebase → 4-6 Firestore reads (partially parallelized) ← FIX #1.4
  │ 5. Stream response chunks
  ▼
Firebase Function (event transformation)
  │ Parse NDJSON → transform → SSE events
  ▼
iOS App (handleIncomingStreamEvent)
```

---

## Architecture Review Findings (2026-03-04)

Multi-agent adversarial review with source code verification. These findings correct and supplement the original plan.

### Corrected Claims

| Original Claim | Verified Finding | Impact |
|----------------|-----------------|--------|
| 35–45 Firestore writes per workout completion | **~126 writes** (30 set_facts + 28 series + 28 min/max txns + 10 e1rm + 10 exercise_usage + 8 analytics + 1 job + 11 other) | Cost projections were 3x low |
| `concurrency: 10` is safe for SSE proxy | **UNSAFE** — module-level `eventStartTimes` Map, `toolArgsCache` Map, and `currentActiveAgent` variable (stream-agent-normalized.js:453-457) are shared across concurrent requests, causing cross-stream data corruption | Must fix race conditions before raising concurrency |
| 4+ sequential Firestore reads in planning context | **4-6 reads, partially parallelized** — templates use `Promise.all`, but user→routine→workouts path is sequential. Optimization is valid but impact is moderate (~100ms savings, not 150ms+) | Lower priority than originally stated |
| `workspace_entries` grows to 75M events/week | **Collection does not exist** in schema, codebase, or Firestore rules | Remove from plan |
| 5-minute subscription cache TTL is acceptable | **Too long** — user upgrades to premium, can't use features for up to 5 minutes. Unacceptable UX | Use 1-minute TTL + instant invalidation on webhook |
| Firestore-based daily cap for rate limiting | **Wrong tool** — Firestore writes add 200-600ms latency overhead per rate limit check, eventual consistency across regions exploitable | Use Memorystore Redis (~$50/month, 1-5ms latency) |

### Missing Critical Items (Not in Original Plan)

| Item | Severity | Finding |
|------|----------|---------|
| **Observability** | P0 | Zero monitoring dashboards, alerting, or cost tracking. Cannot detect or respond to scaling issues. Added as Phase 0. |
| **Only 1/67 endpoints rate-limited** | P1 | 66 endpoints have no rate limiting or `maxInstances` caps. `upsertWorkout`, `logSet`, `artifactAction`, `exchangeToken` are all unprotected. Added to Phase 1. |
| **Vertex AI quota (10 concurrent sessions)** | P1 | Default Agent Engine quota is 10 concurrent sessions per project. Will be hit before SSE cap at ~500 DAU. Added to Phase 1. |
| **Firebase App Check not enabled** | P2 | Free bot detection, 10-minute setup. Blocks automated abuse. Added to Phase 1. |
| **Trigger idempotency gaps** | P2 | `set_facts`, `series_*`, and `training_analysis_jobs` writes have no retry guards. Trigger retries cause duplicate/inflated data. Only `weekly_stats` (via `processed_ids`) and `exercise_usage_stats` (via `last_processed_workout_id`) are protected. Added to Phase 3. |
| **Dual analytics systems** | P2 | Legacy (`weekly_stats`, `analytics_rollups`, `analytics_series_*`) and token-safe (`set_facts`, `series_exercises`, `series_muscle_groups`, `series_muscles`) both write on every workout completion. Nobody deprecated the legacy system. Consider consolidation in Phase 4. |
| **Cloud Functions v2 timeout limit** | P2 | v2 HTTP functions have a 9-minute (540s) hard limit. Current `timeoutSeconds: 300` is safe but long agent streams could approach this. Consider Cloud Run migration for SSE long-term (Phase 4). |
| **Load testing strategy** | P2 | No methodology for validating scaling changes before production deployment. Should be added before Phase 3 changes. |
| **Rollback strategy** | P2 | v1→v2 migration and async analytics changes are high-risk. Need staged rollout with automated rollback triggers. |

### Items Deprioritized

| Item | Original Phase | Reason |
|------|---------------|--------|
| Planning Context Caching (#4.2) | Phase 4 | Already <150ms after parallelization fix. Marginal ROI. |
| iOS SSE Connection Reuse (#4.5) | Phase 4 | HTTP/2 already reuses connections. Claim of 200-500ms savings is misleading — refers to cold start overhead, not connection setup. |
| Batch Analytics Writes (#4.3) | Phase 4 | Merged into Phase 3 async analytics worker. Not a separate item. |

### Scaling Thresholds

The original plan treats 100k users as a binary target. The actual scaling journey has different breakpoints:

| Users | What Breaks First | Minimum Fix |
|-------|--------------------|-------------|
| **1k→5k** | SSE cap (20 connections during peak) | Raise `maxInstances` to 100 (Phase 1.1) |
| **5k→10k** | Cold starts noticeable (P95 spikes); Vertex AI quota hit | Set `minInstances` on hot paths; request quota increase |
| **10k→25k** | Per-instance rate limiting ineffective; analytics triggers slow | Deploy Redis rate limiter; begin async analytics migration |
| **25k→50k** | Firestore write costs ($400+/month from triggers alone) | Complete async analytics; consolidate dual analytics systems |
| **50k→100k** | Single-region latency for global users; support volume | Multi-region evaluation; bundle splitting; Cloud Run for SSE |

---

## Phase 0 — Observability Foundation (Week 0)

**Run in parallel with Phase 1. Cannot scale what you cannot measure.**

### 0.1 Cloud Monitoring Dashboards

Create dashboards in GCP Cloud Monitoring for:

- **SSE Health**: Current connection count vs maxInstances, P50/P95/P99 stream duration, 503 error rate
- **Function Performance**: Invocation rate by endpoint (top 10), P50/P95 latency by endpoint, cold start frequency
- **Firestore Operations**: Read/write rate by collection (identify hot collections), transaction contention rate
- **Agent System**: Fast Lane vs Slow Lane ratio, Vertex AI session count, agent tool latency
- **Error Rates**: 4xx and 5xx by endpoint, function crash rate

### 0.2 Alerting Rules

| Alert | Condition | Channel | Severity |
|-------|-----------|---------|----------|
| SSE capacity critical | connections > 80% of maxInstances for 5 min | PagerDuty / SMS | P0 |
| Error rate spike | any endpoint > 1% error rate for 5 min | Slack | P1 |
| Latency degradation | P95 > 5 seconds for `streamAgentNormalized` for 10 min | Slack | P1 |
| Firestore write spike | writes > 10k/minute for 5 min | Slack | P2 (cost warning) |
| Function budget alert | monthly cost > $500 / $1,000 / $5,000 thresholds | Email | P2 |

### 0.3 Cost Tracking

1. Enable BigQuery billing export in GCP Console
2. Set budget alerts at $500, $1,000, $5,000 monthly thresholds
3. Add structured logging with request IDs across function calls for trace correlation

#### Files to Modify

| File | Change |
|------|--------|
| GCP Console | Create Cloud Monitoring dashboards and alerting policies |
| GCP Console | Enable BigQuery billing export, set budget alerts |
| `firebase_functions/functions/utils/logger-helpers.js` | **NEW** — Request ID generation and propagation helper |

---

## Phase 1 — Emergency Fixes (Weeks 1–2)

### 1.1 SSE Proxy Connection Cap (Conservative)

**Priority**: P0 — System literally cannot serve >20 concurrent agent conversations
**Severity**: CRITICAL
**Effort**: Low (configuration change only — no code changes in this phase)

#### Problem

The SSE streaming proxy `streamAgentNormalized` is configured with hard limits that cap the entire system at 20 concurrent agent streams:

```javascript
// File: firebase_functions/functions/index.js
// Line: ~234
exports.streamAgentNormalized = onRequestV2(
  { timeoutSeconds: 300, memory: '512MiB', maxInstances: 20, concurrency: 1 },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);
```

- `maxInstances: 20` = Firebase will never spawn more than 20 function instances
- `concurrency: 1` = each instance handles exactly 1 request at a time
- **Result**: Maximum 20 simultaneous SSE streams across ALL users

#### Why concurrency CANNOT be raised above 1 yet

**CRITICAL: Race conditions in module-level shared state** (verified 2026-03-04).

Lines 453-457 of `stream-agent-normalized.js` declare mutable state at module level:

```javascript
const eventStartTimes = new Map();      // SHARED across concurrent requests
const toolArgsCache = new Map();         // SHARED across concurrent requests
let currentActiveAgent = 'orchestrator'; // SHARED across concurrent requests
```

With `concurrency > 1`, multiple SSE streams in the same instance would:
1. **Cross-contaminate tool timing** — Stream A's `eventStartTimes.set('tool_X', ts)` overwritten by Stream B
2. **Corrupt agent attribution** — Stream A sets `currentActiveAgent = 'coach'`, Stream B sees wrong agent
3. **Leak tool args** — Stream A's `toolArgsCache` visible to Stream B's completion handler

**Also**: GCP token cache (lines 110-111) has a thundering-herd race — multiple concurrent requests detecting expired token all refresh simultaneously.

**These race conditions must be fixed before raising concurrency. See Phase 3.1.**

#### Fix (Phase 1 — Conservative)

```javascript
// File: firebase_functions/functions/index.js
exports.streamAgentNormalized = onRequestV2(
  {
    timeoutSeconds: 540,      // Was: 300. Use full v2 HTTP allowance (9 min max).
    memory: '512MiB',
    maxInstances: 100,        // Was: 20. 5× capacity with zero code risk.
    concurrency: 1,           // KEEP AT 1 — race conditions exist (see Phase 3.1).
  },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);
```

**Capacity after fix**: 100 instances × 1 stream = **100 concurrent streams** (5× current)

**Why conservative**: Provides 5× capacity improvement with zero code changes and zero race condition risk. Buys time for proper Phase 3.1 refactor. Zero recurring cost — `minInstances` deferred until revenue justifies always-on instances.

**Full concurrency unlock**: After Phase 3.1 fixes race conditions → maxInstances: 200, concurrency: 10 = **2,000 concurrent streams**

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/index.js:~230-233` | Update `maxInstances` and `concurrency` |

#### Verification

1. Deploy the change: `cd firebase_functions/functions && npm run deploy`
2. Open 5 simultaneous agent conversations from different browser tabs
3. Verify all 5 stream without 503 errors
4. Check Cloud Console → Cloud Functions → `streamAgentNormalized` → Instances tab confirms multiple concurrent requests per instance

#### Cross-References

- SSE proxy implementation: `firebase_functions/functions/strengthos/stream-agent-normalized.js`
- iOS SSE client: `Povver/Povver/Services/DirectStreamingService.swift`
- Agent architecture: `docs/SHELL_AGENT_ARCHITECTURE.md` (section: "iOS Client Integration")

---

### 1.2 Subscription Gate Caching

**Priority**: P0 — Adds 20–50ms latency to every agent stream + every workout trigger
**Severity**: HIGH
**Effort**: Low

#### Problem

`isPremiumUser(userId)` does a fresh Firestore read on every call. No caching.

```javascript
// File: firebase_functions/functions/utils/subscription-gate.js
// Lines: 13-43
async function isPremiumUser(userId) {
  try {
    const db = admin.firestore();
    const userDoc = await db.collection('users').doc(userId).get();  // FRESH READ EVERY TIME

    if (!userDoc.exists) return false;

    const userData = userDoc.data();
    if (userData.subscription_override === 'premium') return true;
    if (userData.subscription_tier === 'premium') return true;

    return false;
  } catch (error) {
    return false;
  }
}
```

**Called from:**
- `strengthos/stream-agent-normalized.js` — Premium gate before every SSE stream
- `triggers/weekly-analytics.js:~575` — Every workout completion trigger
- `triggers/weekly-analytics.js:~752` — Every workout creation with end_time

**Impact at 100k users:**
- 500k+ unnecessary Firestore reads/week
- 20–50ms added latency to every agent stream start

#### Fix

Add a 1-minute in-memory cache (revised from original 5 minutes — 5 min is unacceptable UX for upgrade flow). Expose an `invalidatePremiumCache(userId)` function for the subscription webhook to call for instant invalidation.

```javascript
// File: firebase_functions/functions/utils/subscription-gate.js

const PREMIUM_CACHE_TTL_MS = 60 * 1000; // 1 minute (revised from 5 min — upgrade must be near-instant)
const premiumCache = new Map();

async function isPremiumUser(userId) {
  // Check cache first
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
    return false;
  }
}

function invalidatePremiumCache(userId) {
  premiumCache.delete(userId);
}

module.exports = { isPremiumUser, invalidatePremiumCache };
```

**Then call `invalidatePremiumCache(userId)` from the subscription webhook:**

```javascript
// File: firebase_functions/functions/subscriptions/app-store-webhook.js
// After updating subscription fields, add:
const { invalidatePremiumCache } = require('../utils/subscription-gate');
invalidatePremiumCache(userId);
```

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/utils/subscription-gate.js` | Add in-memory cache + invalidation export |
| `firebase_functions/functions/subscriptions/app-store-webhook.js` | Call `invalidatePremiumCache(userId)` after subscription update |

#### Verification

1. Run existing tests: `cd firebase_functions/functions && npm test`
2. Manual test: call `isPremiumUser` twice for same user, verify second call doesn't hit Firestore (check Cloud Logging)
3. Verify webhook invalidates cache correctly

#### Cross-References

- Subscription webhook: `firebase_functions/functions/subscriptions/app-store-webhook.js`
- User profile cache (reference pattern): `firebase_functions/functions/user/get-user.js:18-70` — existing 2-tier cache implementation to use as reference
- SSE proxy premium gate: `firebase_functions/functions/strengthos/stream-agent-normalized.js` (search for `isPremiumUser`)

---

### 1.3 GCP Token Caching in exchange-token

**Priority**: P0 — Adds 200–400ms to every iOS session start
**Severity**: HIGH
**Effort**: Low (copy existing pattern)

#### Problem

`exchange-token.js` fetches a fresh GCP access token on every call. The identical caching pattern already exists in `stream-agent-normalized.js` but was never applied here.

```javascript
// File: firebase_functions/functions/auth/exchange-token.js
// Current: NO caching — fresh GoogleAuth + getAccessToken() every call

// Compare with existing cache in:
// File: firebase_functions/functions/strengthos/stream-agent-normalized.js
// Lines: ~110-127 — proper token caching with 55-minute TTL
```

**Impact**: iOS calls `getServiceToken` on every conversation start. Without caching, each call pays:
- `GoogleAuth` client creation: ~50ms
- `getAccessToken()` network call: ~100–300ms
- Total: 200–400ms added to session start

#### Fix

Copy the token caching pattern from `stream-agent-normalized.js:110-127` into `exchange-token.js`:

```javascript
// File: firebase_functions/functions/auth/exchange-token.js
// Add at module level (outside handler):

let cachedGcpToken = null;
let gcpTokenExpiresAt = 0;

async function getCachedGcpToken() {
  const now = Date.now();
  // Return cached if valid (with 5-minute safety margin)
  if (cachedGcpToken && now < gcpTokenExpiresAt - (5 * 60 * 1000)) {
    return cachedGcpToken;
  }

  const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
  const client = await auth.getClient();
  const tokenResponse = await client.getAccessToken();

  cachedGcpToken = tokenResponse.token || tokenResponse;
  gcpTokenExpiresAt = now + (55 * 60 * 1000); // 55 minutes (tokens valid for 60)

  return cachedGcpToken;
}

// Then in the handler, replace:
//   const client = await auth.getClient();
//   const tokenResponse = await client.getAccessToken();
// With:
//   const accessToken = await getCachedGcpToken();
```

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/auth/exchange-token.js` | Add token caching (copy pattern from stream-agent-normalized.js:110-127) |

#### Verification

1. Call `getServiceToken` twice within 1 minute — second call should return instantly (check latency in Cloud Logging)
2. Verify token is valid for Vertex AI calls

#### Cross-References

- Existing token cache (reference implementation): `firebase_functions/functions/strengthos/stream-agent-normalized.js:110-127`
- Another instance of the same pattern: `firebase_functions/functions/canvas/open-canvas.js:30-42`
- iOS token consumer: `Povver/Povver/Services/DirectStreamingService.swift` — also check if iOS caches the returned token (it should cache until `expiryDate - 5min`)

---

### 1.4 Parallelize get-planning-context Reads

**Priority**: P0 — Adds 150ms+ latency to every agent planning request
**Severity**: HIGH
**Effort**: Low

#### Problem

`get-planning-context.js` performs 4+ sequential Firestore reads where they could run in parallel:

```javascript
// File: firebase_functions/functions/agents/get-planning-context.js
// Lines: ~140-262

// SEQUENTIAL (current — each awaits before next starts):
const userDoc = await firestore.collection('users').doc(callerUid).get();           // ~50ms
const attrsDoc = await firestore.collection('users').doc(callerUid)
  .collection('user_attributes').doc(callerUid).get();                               // ~50ms
// ... then routine read ...                                                         // ~50ms
// ... then template reads (Promise.all, but AFTER routine) ...                      // ~50ms
// Total: ~200ms minimum (4 sequential round-trips)

// PARALLEL (fix — all independent reads start simultaneously):
// Total: ~50ms (1 round-trip, all reads in parallel)
```

#### Fix

Restructure reads into two phases:
1. **Phase A** (parallel): User + attributes + workouts — these are independent
2. **Phase B** (depends on A): Routine + templates — needs `user.activeRoutineId` from Phase A

```javascript
// File: firebase_functions/functions/agents/get-planning-context.js
// Replace the sequential reads section (~lines 140-262) with:

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

// Phase B: Routine + templates (depends on user.activeRoutineId from Phase A)
let routine = null;
let templates = [];

if (user.activeRoutineId) {
  const routineDoc = await firestore.collection('users').doc(callerUid)
    .collection('routines').doc(user.activeRoutineId).get();
  routine = routineDoc.exists ? { id: routineDoc.id, ...routineDoc.data() } : null;

  if (routine && routine.template_ids && includeTemplates) {
    // Use getAll for batch read (1 RPC instead of N parallel gets)
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

**Key improvement**: `firestore.getAll(...refs)` is a single RPC call regardless of how many refs are passed. This replaces the current `Promise.all(refs.map(r => r.get()))` pattern which creates N parallel RPCs.

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/agents/get-planning-context.js` | Restructure sequential reads into parallel phases |

#### Verification

1. Run existing tests: `cd firebase_functions/functions && npm test`
2. Call `getPlanningContext` and compare response structure with pre-change response (should be identical)
3. Check Cloud Logging for reduced Firestore read latency

#### Cross-References

- Agent tool that calls this: `adk_agent/canvas_orchestrator/app/skills/coach_skills.py` → `get_training_context()`
- HTTP client: `adk_agent/canvas_orchestrator/app/libs/tools_common/http.py` (or `app/libs/tools_canvas/client.py`)
- Agent tools definition: `adk_agent/canvas_orchestrator/app/shell/tools.py` → `tool_get_training_context`

---

### 1.5 Set maxInstances on All Functions

**Priority**: P1 — 64/67 functions have no instance caps, enabling runaway scaling and bill shock
**Severity**: HIGH
**Effort**: Low (configuration only)

#### Problem

Only 3 functions have `maxInstances` set. The other 64 can scale to GCP's default limit (1,000 instances per function), enabling:
- Runaway scaling during traffic spikes → bill shock
- Resource exhaustion of downstream services (Firestore, Vertex AI)
- No backpressure mechanism

#### Fix

Set `maxInstances` in `index.js` for all functions by tier:

| Tier | Functions | maxInstances | Rationale |
|------|-----------|-------------|-----------|
| **Hot path** | `streamAgentNormalized` | 100 (Phase 1.1) | Already addressed |
| **Write-heavy** | `logSet`, `upsertWorkout`, `artifactAction`, `completeActiveWorkout` | 50 | Cap write amplification |
| **Read-heavy** | `getUserWorkouts`, `getUserTemplates`, `getRoutine`, `getTemplate`, `searchExercises`, `getPlanningContext` | 100 | Higher concurrency acceptable for reads |
| **Auth/Token** | `exchangeToken`, `getServiceToken` | 30 | Protect GCP metadata service |
| **Standard** | All remaining endpoints | 50 | Reasonable default |
| **Triggers** | All Firestore triggers | 30 | Prevent trigger storms |

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/index.js` | Add `maxInstances` to all v2 exports; for v1 functions, add it when migrating to v2 |

---

### 1.6 Add Rate Limiting to Write Endpoints

**Priority**: P1 — Write endpoints have zero abuse protection
**Severity**: HIGH
**Effort**: Low-Medium

#### Problem

Only `streamAgentNormalized` uses `agentLimiter`. Write-heavy endpoints like `logSet`, `upsertWorkout`, and `artifactAction` can be called without limit.

#### Fix

Extend the existing `rate-limiter.js` pattern to cover write endpoints:

```javascript
// File: firebase_functions/functions/utils/rate-limiter.js
// Add these alongside existing agentLimiter:

const writeLimiter = createRateLimiter({ windowMs: 60 * 1000, max: 60 });   // 60 writes/minute
const authLimiter = createRateLimiter({ windowMs: 60 * 1000, max: 10 });    // 10 auth calls/minute
```

Apply `writeLimiter.check(userId)` in: `logSet`, `upsertWorkout`, `artifactAction`, `completeActiveWorkout`, `startActiveWorkout`.

Apply `authLimiter.check(userId)` in: `exchangeToken`, `getServiceToken`.

**Note**: These are still per-instance limiters. Global limiting via Redis is in Phase 3.4. This provides burst protection at zero cost.

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/utils/rate-limiter.js` | Export `writeLimiter` and `authLimiter` |
| `firebase_functions/functions/active_workout/log-set.js` | Add `writeLimiter.check()` |
| `firebase_functions/functions/workouts/upsert-workout.js` | Add `writeLimiter.check()` |
| `firebase_functions/functions/artifacts/artifact-action.js` | Add `writeLimiter.check()` |
| `firebase_functions/functions/auth/exchange-token.js` | Add `authLimiter.check()` |

---

### 1.7 Enable Firebase App Check

**Priority**: P2 — Free bot detection, blocks automated abuse
**Severity**: MEDIUM
**Effort**: Low (10-minute setup)

#### Fix

1. Enable App Check in Firebase Console with DeviceCheck (iOS) attestation provider
2. Enforce App Check on critical endpoints (opt-in enforcement allows gradual rollout)
3. Add App Check token verification middleware to `stream-agent-normalized.js`

This blocks automated scripts from calling Firebase Functions without a legitimate iOS app attestation.

---

### 1.8 Request Vertex AI Quota Increase

**Priority**: P1 — Default 10 concurrent sessions will be hit before SSE cap
**Severity**: HIGH
**Effort**: Low (GCP Console request)

#### Problem

Vertex AI Agent Engine default quota is ~10 concurrent sessions per project. At even 500 DAU with 2 agent messages/session, peak concurrent sessions could easily exceed 10.

#### Fix

1. Go to GCP Console → IAM & Admin → Quotas → Vertex AI → Reasoning Engines
2. Request increase to 100 concurrent sessions
3. Monitor usage via Phase 0 dashboards

---

### 1.9 Recommendation Listener Cleanup

**Priority**: P2 — Wasteful but not a true leak
**Severity**: LOW (downgraded from original MEDIUM)
**Effort**: Low

**Revised assessment**: The listener runs as long as MainTabsView exists (app lifecycle), which is by design. It's not leaking across sessions. The real issue is that it runs even when the user isn't on the More tab.

Fix: Call `stopListening()` in `MoreView.onDisappear` and `startListening()` in `MoreView.onAppear`.

---

## Phase 2 — UX Speed (Weeks 3–4)

### 2.1 iOS App Launch Waterfall

**Priority**: P1 — User sees blank screen for 2.5–4 seconds on every login
**Severity**: HIGH
**Effort**: Medium

#### Problem

After authentication, `RootView` blocks on sequential operations before showing `MainTabsView`:

```
Time 0ms:    User authenticates
Time 50ms:   RootView.onChange triggers
             ├─ SessionPreWarmer.preWarmIfNeeded()        [~2-3s network call]
             └─ prefetchLibraryData()                    [4 parallel endpoints:]
                 ├─ getUserTemplates()
                 ├─ getUserRoutines()
                 ├─ getNextWorkout()
                 └─ getActiveWorkout()
Time 2500ms: MainTabsView finally renders
Time 2600ms: CoachTabView.onAppear fires REDUNDANT:
             ├─ SessionPreWarmer.preWarmIfNeeded() AGAIN [debounced to 10s]
             └─ loadRecentCanvases()                    [Firestore query]
```

**Result**: 2.5–4 seconds of blank screen. On poor mobile networks: 4–6 seconds.

#### Fix (Three Parts)

**Part A: Show MainTabsView immediately with skeletons**

```swift
// File: Povver/Povver/Views/RootView.swift
// Lines: ~49-56
// Change: Don't await prefetch before showing main content.
// Show MainTabsView immediately, let each tab load its own data.

// BEFORE:
.onChange(of: authService.isAuthenticated) { _, isAuth in
    if isAuth {
        Task {
            await SessionPreWarmer.shared.preWarmIfNeeded()  // BLOCKS
            await FocusModeWorkoutService.shared.prefetchLibraryData()  // BLOCKS
        }
        flow = .main
    }
}

// AFTER:
.onChange(of: authService.isAuthenticated) { _, isAuth in
    if isAuth {
        flow = .main  // Show tabs IMMEDIATELY
        Task {
            // Fire-and-forget background prefetch
            async let _ = SessionPreWarmer.shared.preWarmIfNeeded()
            async let _ = FocusModeWorkoutService.shared.prefetchLibraryData()
        }
    }
}
```

**Part B: Remove redundant pre-warm from CoachTabView**

```swift
// File: Povver/Povver/Views/Tabs/CoachTabView.swift
// Lines: ~63-66
// REMOVE the redundant SessionPreWarmer.preWarmIfNeeded() call.
// RootView already fires it. The 10-second debounce is too short for tab switching.
```

**Part C: Remove redundant prefetch fallback from MainTabsView**

```swift
// File: Povver/Povver/Views/MainTabsView.swift
// Lines: ~138-145
// REMOVE the fallback prefetchLibraryData() call.
// RootView guarantees execution. The guard check adds complexity for no benefit.
```

**Part D (Future): Batch bootstrap endpoint**

Create `POST /getAppBootstrapData` that returns templates + routines + next workout + active workout in one round-trip instead of 4 parallel calls. This is a larger change and can be deferred to Phase 3.

#### Files to Modify

| File | Change |
|------|--------|
| `Povver/Povver/Views/RootView.swift:~49-56` | Show `.main` before awaiting prefetch |
| `Povver/Povver/Views/Tabs/CoachTabView.swift:~63-66` | Remove redundant pre-warm call |
| `Povver/Povver/Views/MainTabsView.swift:~138-145` | Remove redundant prefetch fallback |

#### Verification

1. Build and run on simulator: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
2. Login → measure time from auth success to first tab content visible
3. Should be <500ms (vs 2.5–4s before)
4. Verify all tab content still loads correctly (just asynchronously)

#### Cross-References

- Prefetch implementation: `Povver/Povver/Services/FocusModeWorkoutService.swift:1765-1790`
- Pre-warmer: `Povver/Povver/Services/SessionPreWarmer.swift`
- Tab structure: `docs/IOS_ARCHITECTURE.md` (section: "Tab Structure")

---

### 2.2 Wire CacheManager Into Repositories

**Priority**: P1 — 500+ unnecessary Firestore reads per session
**Severity**: HIGH
**Effort**: Medium

#### Problem

`CacheManager.swift` implements a proper actor-based memory+disk cache with configurable TTL. **Zero call sites reference it.** Meanwhile:

- **Exercise catalog**: `ExerciseRepository` fetches all 500+ exercises from Firestore on every Library tab visit
- **Templates**: Fetched 3x redundantly (prefetch + Library + detail views)
- **Workout history**: Full collection read on every History tab visit (no pagination — see #2.3)

```swift
// File: Povver/Povver/Services/CacheManager.swift
// Lines: 1-344
// Complete actor-based cache implementation — UNUSED

// File: Povver/Povver/Repositories/ExerciseRepository.swift
// Lines: ~13-45
// Fetches from Firestore every time — NO CACHING
```

#### Fix

Wire `CacheManager` into the three highest-volume repositories:

**Exercise Catalog (60-minute TTL — near-immutable data):**

```swift
// File: Povver/Povver/Repositories/ExerciseRepository.swift

func getExercises() async throws -> [Exercise] {
    let cacheKey = "exercises:all"
    if let cached: [Exercise] = await CacheManager.shared.get(cacheKey) {
        return cached
    }

    let exercises = try await fetchFromFirestore() // existing implementation
    await CacheManager.shared.set(cacheKey, value: exercises, ttl: 3600) // 60 min
    return exercises
}
```

**Templates (5-minute TTL — user-mutable):**

```swift
// File: Povver/Povver/Repositories/TemplateRepository.swift

func getUserTemplates(userId: String) async throws -> [WorkoutTemplate] {
    let cacheKey = "templates:\(userId)"
    if let cached: [WorkoutTemplate] = await CacheManager.shared.get(cacheKey) {
        return cached
    }

    let templates = try await fetchFromFirestore(userId: userId)
    await CacheManager.shared.set(cacheKey, value: templates, ttl: 300) // 5 min
    return templates
}

// Invalidate on mutation:
func createTemplate(_ template: WorkoutTemplate) async throws {
    // ... existing create logic ...
    await CacheManager.shared.remove("templates:\(template.userId)")
}
```

**Routines (5-minute TTL — user-mutable, same pattern as templates):**

Apply the same pattern to `RoutineRepository`.

#### Files to Modify

| File | Change |
|------|--------|
| `Povver/Povver/Repositories/ExerciseRepository.swift` | Add CacheManager reads with 60min TTL |
| `Povver/Povver/Repositories/TemplateRepository.swift` | Add CacheManager reads with 5min TTL + invalidation on mutations |
| `Povver/Povver/Repositories/RoutineRepository.swift` | Add CacheManager reads with 5min TTL + invalidation on mutations |

#### Verification

1. Open Library tab → exercises load (cache miss)
2. Navigate away and back → exercises load instantly (cache hit)
3. Create a new template → navigate to templates list → new template appears (cache invalidated)
4. Wait 6 minutes → exercises re-fetched from Firestore (TTL expired)

#### Cross-References

- CacheManager implementation: `Povver/Povver/Services/CacheManager.swift`
- Existing prefetch cache in FocusModeWorkoutService: `Povver/Povver/Services/FocusModeWorkoutService.swift` — has its own `cachedTemplates` property that should be consolidated into CacheManager

---

### 2.3 Server-Side Workout History Pagination

**Priority**: P1 — User with 200 workouts = 200 Firestore reads on every History tab visit
**Severity**: MEDIUM
**Effort**: Medium

#### Problem

`HistoryView` fetches ALL workouts from Firestore, then paginates in memory:

```swift
// File: Povver/Povver/Views/Tabs/HistoryView.swift
// Lines: ~171-198
// Fetches ENTIRE workout history, then shows 25 at a time
// "Load More" appends from in-memory cache — no actual pagination benefit

// File: Povver/Povver/Repositories/WorkoutRepository.swift
// getWorkouts() has no limit parameter — returns everything
```

#### Fix (Two Parts)

**Part A: Backend — Add cursor pagination to getUserWorkouts**

The Firebase Function `getUserWorkouts` (or `getWorkout` / `get-user-workouts.js`) needs a `limit` and `startAfter` parameter.

```javascript
// File: firebase_functions/functions/workouts/get-user-workouts.js
// Add parameters:
//   limit: number (default 25, max 100)
//   startAfter: string (workout document ID for cursor)

const limit = Math.min(parseInt(req.query.limit) || 25, 100);
const startAfter = req.query.startAfter;

let query = firestore.collection('users').doc(userId)
  .collection('workouts')
  .orderBy('end_time', 'desc')
  .limit(limit + 1); // Fetch 1 extra to determine hasMore

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

return ok(res, { workouts, hasMore, cursor: workouts.length > 0 ? workouts[workouts.length - 1].id : null });
```

**Part B: iOS — Use cursor pagination in HistoryView**

```swift
// File: Povver/Povver/Views/Tabs/HistoryView.swift
// Replace full-collection fetch with paginated calls:

@Published var workouts: [Workout] = []
@Published var hasMore = true
@Published var cursor: String? = nil

func loadMore() async {
    guard hasMore, !isLoading else { return }
    isLoading = true

    let result = try await workoutRepository.getWorkouts(
        userId: userId,
        limit: 25,
        startAfter: cursor
    )

    workouts.append(contentsOf: result.workouts)
    hasMore = result.hasMore
    cursor = result.cursor
    isLoading = false
}
```

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/workouts/get-user-workouts.js` | Add `limit` and `startAfter` parameters |
| `Povver/Povver/Repositories/WorkoutRepository.swift` | Add paginated `getWorkouts(limit:startAfter:)` method |
| `Povver/Povver/Views/Tabs/HistoryView.swift` | Replace full fetch with cursor-based pagination |

#### Cross-References

- Workout model: `Povver/Povver/Models/Workout.swift`
- Existing pagination pattern (reference): check if `getUserTemplates` has pagination
- Firestore schema for workouts: `docs/FIRESTORE_SCHEMA.md` (section: workouts subcollection)

---

## Phase 3 — Scale Infrastructure (Month 2)

### 3.1 Fix SSE Race Conditions + Raise Concurrency

**Priority**: P0 — Required to unlock SSE concurrency beyond 1
**Severity**: CRITICAL
**Effort**: Medium (code refactor, must be tested carefully)

#### Problem

Module-level shared mutable state in `stream-agent-normalized.js` (lines 453-457) causes cross-stream data corruption when `concurrency > 1`:

```javascript
// Lines 453-457 — MODULE LEVEL (shared across all concurrent requests)
const eventStartTimes = new Map();
const toolArgsCache = new Map();
let currentActiveAgent = 'orchestrator';
```

Additionally, the GCP token cache (lines 110-111) has a thundering-herd race:

```javascript
let cachedGcpToken = null;     // Two concurrent requests both see expired → both refresh
let tokenExpiresAt = 0;
```

#### Fix

**Step 1: Move shared state into request scope**

```javascript
// Inside streamAgentNormalizedHandler, create per-request state:
const requestState = {
  eventStartTimes: new Map(),
  toolArgsCache: new Map(),
  currentActiveAgent: 'orchestrator'
};

// Pass requestState through closure to transformToIOSEvent:
const transform = createTransformer(requestState);
```

**Step 2: Fix token cache thundering herd**

```javascript
let tokenRefreshPromise = null;

async function getGcpAuthToken() {
  if (cachedGcpToken && Date.now() < tokenExpiresAt - TOKEN_BUFFER_MS) {
    return cachedGcpToken;
  }
  if (!tokenRefreshPromise) {
    tokenRefreshPromise = refreshToken().then(token => {
      tokenRefreshPromise = null;
      return token;
    });
  }
  return tokenRefreshPromise;
}
```

**Step 3: Raise concurrency after verification**

```javascript
exports.streamAgentNormalized = onRequestV2(
  {
    timeoutSeconds: 540,
    memory: '512MiB',
    maxInstances: 200,
    concurrency: 10,       // NOW safe after race condition fix
  },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);
```

**Capacity after fix**: 200 instances × 10 streams = **2,000 concurrent streams**

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/strengthos/stream-agent-normalized.js` | Move eventStartTimes, toolArgsCache, currentActiveAgent into handler scope. Fix token cache race. |
| `firebase_functions/functions/index.js` | Update config: maxInstances: 200, concurrency: 10, minInstances: 5 |

#### Verification

1. Deploy to staging with `concurrency: 2` first
2. Open 2+ concurrent agent conversations from same user
3. Verify tool timing data is correct per-stream (no cross-contamination)
4. Verify agent attribution is correct (no "coach" label on "orchestrator" streams)
5. Load test with 10 concurrent streams per instance
6. Monitor memory usage (should remain <100MB per instance even at 10 concurrent)

---

### 3.2 Async Analytics Processing (Hybrid Model)

**Priority**: P0 — Workout completion triggers ~126 synchronous Firestore writes (revised from 35–45)
**Severity**: CRITICAL
**Effort**: High

#### Problem

`onWorkoutCompleted` in `triggers/weekly-analytics.js` does massive synchronous work. Verified write count for a typical workout (10 exercises, 30 sets, 6 muscle groups):

```
Workout completion trigger fires (~126 total writes):
├── 1. Update weekly_stats/{weekId} (1 transaction)                          [1 write]
├── 2. Upsert analytics_rollup/{weekId} (1 transaction)                     [1 write]
├── 3. Append muscle_weekly_series (1 transaction per muscle)                [6 writes]
├── 4. Update watermark analytics_state/current                              [1 write]
├── 5. Append exercise_daily_series (1 transaction per exercise)             [10 writes]
├── 6. Generate set_facts (1 doc per set, batched)                           [30 writes]
├── 7. Update series (batch: exercises + muscle_groups + muscles)             [28 writes]
├── 8. updateMinMaxForSeries (1 transaction per series doc)                  [28 writes]
├── 9. updateE1rmMax (1 transaction per exercise)                            [10 writes]
├── 10. Check isPremiumUser (Firestore read — see #1.2)
├── 11. Enqueue training_analysis_job (if premium)                           [1 write]
├── 12. Update exercise_usage_stats (1 transaction per exercise)             [10 writes]
└── Total: ~126 writes, 5-15 seconds execution
```

**Note**: Two analytics systems run in parallel — legacy (`weekly_stats`, `analytics_rollups`, `analytics_series_*`) and token-safe (`set_facts`, `series_*`). This doubles the write volume. Consider consolidating in Phase 4.

**At 10k users × 4 workouts/week:**
- 40k trigger executions/week
- ~5M Firestore writes/week from triggers alone
- Cost: ~$9/week in Firestore writes (~$470/year)
- Trigger execution: 5–15s per workout (can timeout, causing retries and duplicate writes)

**Risk**: Firestore triggers are "at-least-once". Long-running triggers that timeout will retry, causing duplicate analytics. Only `weekly_stats` (via `processed_ids` array) and `exercise_usage_stats` (via `last_processed_workout_id`) have idempotency guards. The other ~100 writes (set_facts, series_*, min/max transactions) will duplicate on retry.

#### Fix (Hybrid Model — Revised)

Instead of moving ALL analytics to a background worker (which delays user-visible data), use a **hybrid model**: keep essential user-facing writes synchronous, enqueue heavy agent-facing analytics to a background worker.

**What stays synchronous (trigger writes immediately — user sees these):**
- `weekly_stats` update (1 write) — powers iOS progress charts
- `analytics_rollups` update (1 write) — weekly/monthly aggregates
- `exercise_usage_stats` updates (10 writes) — powers "recent exercises" sort
- `analytics_state/current` watermark (1 write)
- **Total: ~13 synchronous writes**

**What moves to background worker (agent-facing, can be eventual):**
- `set_facts` generation (30 writes)
- All `series_*` updates (28 batch + 28 min/max + 10 e1rm = 66 writes)
- `analytics_series_muscle` (6 writes)
- `analytics_series_exercise` (10 writes)
- `training_analysis_job` enqueue (1 write)
- **Total: ~113 writes processed asynchronously**

**Step 1: Slim the trigger**

```javascript
// File: firebase_functions/functions/triggers/weekly-analytics.js
// Keep essential writes synchronous, enqueue heavy analytics:

// Phase A: Essential writes (synchronous — user-visible data)
const essentialBatch = db.batch();
// ... weekly_stats, analytics_rollups, exercise_usage_stats ...
await essentialBatch.commit();

// Phase B: Enqueue heavy analytics for background processing
await db.collection('analytics_processing_queue').add({
  type: 'WORKOUT_ANALYTICS',
  userId,
  workoutId,
  status: 'queued',
  created_at: admin.firestore.FieldValue.serverTimestamp(),
  workout_snapshot: event.data.after.data(), // Avoid re-read
});

logger.info('[onWorkoutCompleted] Essential writes done, analytics enqueued', { userId, workoutId });
```

**Step 2: Background worker**

Create a Cloud Function triggered by `analytics_processing_queue` writes (or a scheduled poller):
- Processes `set_facts`, `series_*`, and training analysis jobs
- Uses `db.batch()` for writes (1 batch commit instead of 66 individual writes)
- Full idempotency (check `processing_status` field before processing)
- Retry with exponential backoff

**Step 3: User impact during worker delay**

| Analytics | Delay Tolerance | User Impact If Delayed |
|-----------|----------------|------------------------|
| Weekly stats, routine cursor | 0 (sync) | None — written synchronously |
| Exercise usage stats | 0 (sync) | None — written synchronously |
| set_facts | 5-30 min | Agent can't analyze latest workout (acceptable) |
| Series updates | 5-30 min | Progress charts slightly stale (acceptable) |
| Training analysis | 24 hours | Weekly review delayed (acceptable for premium) |

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/triggers/weekly-analytics.js` | Replace heavy trigger with job enqueue |
| `firebase_functions/functions/workers/analytics-processor.js` | **NEW FILE** — background analytics worker |
| `firebase_functions/functions/index.js` | Export new worker function |

#### Cross-References

- Current trigger implementation: `firebase_functions/functions/triggers/weekly-analytics.js` (lines 430–788)
- Set facts generator: `firebase_functions/functions/training/set-facts-generator.js`
- Exercise usage stats: `firebase_functions/functions/triggers/weekly-analytics.js` (search for `updateExerciseUsageStats`)
- Training analysis job queue: `firebase_functions/functions/triggers/weekly-analytics.js` (search for `training_analysis_jobs`)
- Existing worker pattern (reference): `adk_agent/training_analyst/workers/analyst_worker.py`

---

### 3.3 Fix Trigger Idempotency

**Priority**: P1 — Trigger retries cause duplicate/inflated analytics data
**Severity**: HIGH
**Effort**: Medium

#### Problem

Firestore triggers are "at-least-once". If the trigger times out (5-15s execution), it retries automatically. Only 2 of 9 write paths have idempotency guards:

| Write Path | Has Guard? | Retry Behavior |
|------------|-----------|----------------|
| `weekly_stats` | **Yes** (`processed_ids` array) | Safe — skips if already processed |
| `exercise_usage_stats` | **Yes** (`last_processed_workout_id`) | Safe — skips if already processed |
| `set_facts` | **No** | Writes duplicate docs (merge=true mitigates, but wasteful) |
| `series_exercises` | **No** | `FieldValue.increment()` — **inflates stats on retry** |
| `series_muscle_groups` | **No** | `FieldValue.increment()` — **inflates stats on retry** |
| `series_muscles` | **No** | `FieldValue.increment()` — **inflates stats on retry** |
| `updateMinMaxForSeries` | **No** | Transactions are idempotent (compare-and-set), but wasteful |
| `analytics_rollups` | **Partial** | Relies on weekly_stats check upstream |
| `training_analysis_jobs` | **No** | Creates duplicate jobs |

#### Fix

Add a global idempotency check at the start of the trigger:

```javascript
// At top of onWorkoutCompleted:
const processingRef = db.collection('users').doc(userId)
  .collection('workout_processing').doc(workoutId);

const existing = await processingRef.get();
if (existing.exists && existing.data().status === 'completed') {
  logger.info('[onWorkoutCompleted] Already processed, skipping', { userId, workoutId });
  return;
}

// Mark as processing (idempotency fence)
await processingRef.set({
  status: 'processing',
  started_at: admin.firestore.FieldValue.serverTimestamp()
});

// ... do all analytics work ...

// Mark as completed
await processingRef.update({ status: 'completed', completed_at: admin.firestore.FieldValue.serverTimestamp() });
```

Add 7-day TTL on `workout_processing` docs.

---

### 3.4 Global Rate Limiting (Redis)

**Priority**: P0 — Current in-memory rate limiter is bypassable across instances
**Severity**: CRITICAL
**Effort**: Medium

#### Problem

The `rate-limiter.js` uses a per-instance `Map()` that resets on cold starts and doesn't share state across instances. With Phase 1.1 raising maxInstances to 100, a single user could effectively make `100 × 120 = 12,000` agent requests/hour.

#### Why NOT Firestore (Original Plan Was Wrong)

The original plan proposed Firestore-based rate limiting. This is the **wrong tool**:
- Firestore write latency: 100-300ms per rate limit check (adds 200-600ms overhead)
- At 10k concurrent users: 10k+ writes/sec to `rate_limits` collection
- Eventual consistency across regions allows exploitation
- Cost: $1.80/day just for rate limit writes at 10k users

#### Fix — Memorystore for Redis

Deploy a basic Redis instance and use atomic `INCR` + `EXPIRE` for rate limiting:

```javascript
// File: firebase_functions/functions/utils/rate-limiter.js
const redis = require('redis').createClient(process.env.REDIS_URL);

async function checkGlobalRateLimit(userId, limit = 120, windowSec = 3600) {
  const key = `rl:${userId}:${Math.floor(Date.now() / (windowSec * 1000))}`;
  const count = await redis.incr(key);
  if (count === 1) await redis.expire(key, windowSec);
  return count <= limit;
}
```

| Metric | Firestore Approach | Redis Approach |
|--------|-------------------|----------------|
| Latency per check | 200-600ms | 1-5ms |
| Monthly cost (10k users) | ~$54 | ~$50 (1GB basic instance) |
| Consistency | Eventual | Strong (single-instance) |
| Accuracy | Approximate | Exact |

**Deployment**:
```bash
gcloud redis instances create povver-rate-limiter \
  --size=1 --region=us-central1 --tier=basic
```

Keep the existing per-instance `Map()` as a first-pass burst limiter (zero latency). Redis serves as the authoritative global limiter.

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/utils/rate-limiter.js` | Add Redis-based `checkGlobalRateLimit()` alongside existing in-memory limiter |
| `firebase_functions/functions/strengthos/stream-agent-normalized.js` | Call `checkGlobalRateLimit()` before streaming |
| `firebase_functions/functions/package.json` | Add `redis` dependency |
| GCP Console | Deploy Memorystore Redis instance |
| VPC / Serverless VPC Connector | Required for Cloud Functions to reach Memorystore |

#### Cross-References

- Current rate limiter: `firebase_functions/functions/utils/rate-limiter.js`
- Security doc: `docs/SECURITY.md`

---

### 3.5 Firestore TTL Policies

**Priority**: P1 — Unbounded collection growth
**Severity**: MEDIUM
**Effort**: Low-Medium

#### Problem

Several collections grow without bounds:

| Collection | Growth Rate (10k users) | Recommendation |
|------------|--------------------------|----------------|
| `set_facts` | 45 docs/user/week → 117M docs in 5 years (at 10k users) | 2-year TTL |
| `idempotency` (in active_workouts) | 24 docs/workout | 7-day TTL |
| `workout_processing` (new, from #3.3) | 1 doc/user/workout | 7-day TTL |
| `rate_limits` (new, from #3.4) | N/A if using Redis | Only needed if Firestore fallback |
| `template changelog` | Has 90-day `expires_at` but verify TTL policy is deployed | Verify |

> **Note**: `workspace_entries` was listed in the original plan but does not exist in the schema, codebase, or Firestore rules. Removed.

#### Fix

1. Add `expires_at` field to documents in each collection
2. Configure Firestore TTL policy via Firebase Console or `gcloud` CLI:

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

3. Backfill `expires_at` on existing documents (batch script)

#### Files to Modify

| File | Change |
|------|--------|
| `firebase_functions/functions/training/set-facts-generator.js` | Add `expires_at` field (2 years from `workout_date`) |
| `firebase_functions/functions/active_workout/log-set.js` | Add `expires_at` to idempotency docs (7 days) |
| `firebase_functions/functions/triggers/weekly-analytics.js` | Add `expires_at` to workout_processing docs (7 days) |
| `scripts/backfill_ttl.js` | **NEW** — backfill `expires_at` on existing documents |

---

### 3.6 Training Analyst Horizontal Scaling

**Priority**: P1 — Serial queue processor cannot keep up at 10k+ users
**Severity**: MEDIUM
**Effort**: Low (configuration change)

#### Problem

Training analyst Cloud Run Job runs with `parallelism: 1` — sequential queue processing. At 10k users (23k jobs/week), sequential processing takes ~32 hours/week. At 100k users, it cannot keep up.

#### Fix

```yaml
# File: adk_agent/training_analyst/cloud-run-worker.yaml
parallelism: 10  # Was: 1. Run 10 workers in parallel.
```

**Capacity**: 10x throughput. Scales to ~100k users.

**Long-term (>100k users)**: Migrate to Cloud Tasks + Cloud Run Service for auto-scaling 0-100 workers.

---

## Phase 4 — Optimization (Deferred Until >10k Users)

### 4.1 Function Bundle Splitting

**Effort**: High | **Impact**: Cold starts from 2-4s to ~500ms
**Priority**: P2 — Only worth complexity at scale

Split 107 functions into 4 codebases using Firebase's `codebase` feature: core (user/workout/template CRUD), agent (SSE, canvas), analytics (triggers, series), catalog (exercise admin). Set `minInstances` on hot codebases only.

**File**: `firebase.json`, `firebase_functions/functions/index.js`

### 4.2 v1 to v2 Function Migration

**Effort**: Medium | **Impact**: 80x instance efficiency for migrated functions
**Priority**: P2 — 55/107 functions still v1 (51%)

Staged migration: 1 function at a time, 24h monitoring between each. Priority: `getUser` → template CRUD → routine CRUD → exercise reads.

**Risk mitigation**: v1 and v2 have different env var patterns (`functions.config()` vs `process.env`). Test each migration in isolation.

### 4.3 Expand Fast Lane Patterns

**Effort**: Low | **Impact**: ~5-10% reduction in LLM costs (revised from 10%)

Add more regex patterns to `adk_agent/canvas_orchestrator/app/shell/router.py` for common queries that don't need LLM reasoning:

| Pattern | Intent | Response | Saves |
|---------|--------|----------|-------|
| `^(help\|\\?)$` | HELP | Static help text | $0.15/req |
| `^status$` | STATUS | Cached routine/workout info | $0.15/req |
| `^(summary\|recap)$` | SUMMARY | Cached workout summary | $0.15/req |

**File**: `adk_agent/canvas_orchestrator/app/shell/router.py:~58-79`

### 4.4 Evaluate Cloud Run for SSE (Long-Term)

**Effort**: High | **Impact**: 60-minute timeout (vs 9-minute v2 limit), better autoscaling

Cloud Functions v2 HTTP functions have a 540-second (9-minute) hard timeout. For long agent conversations, Cloud Run offers:
- Up to 60-minute request timeout
- CPU-based autoscaling (better for I/O-bound SSE)
- Lower cold start latency (~500ms vs ~2s)
- Native HTTP/2 and WebSocket support

**Trigger**: Evaluate when agent sessions regularly approach 5-minute durations or when SSE concurrency needs exceed 2,000.

**Migration path**: Containerize `streamAgentNormalized` handler → Deploy to Cloud Run → Route via Firebase Hosting rewrites.

### Deprioritized Items (Removed from Active Plan)

| Item | Original Phase | Reason for Removal |
|------|---------------|-------------------|
| **Planning Context Caching** | Phase 4 | Already <150ms after #1.4 parallelization. Caching adds invalidation complexity for ~50ms savings. Marginal ROI. |
| **iOS SSE Connection Reuse** | Phase 4 | HTTP/2 already reuses connections. The 200-500ms claim refers to cold start overhead, not connection setup. Misleading. |
| **Batch Analytics Writes** | Phase 4 | Merged into Phase 3.2 (async analytics worker uses batched writes internally). Not a separate item. |
| **Consolidate Dual Analytics Systems** | N/A | Legacy (`weekly_stats`, `analytics_rollups`) and token-safe (`set_facts`, `series_*`) both run on every workout. Consolidation would halve write volume but requires iOS app migration to read from `series_*` instead of `weekly_stats`. Consider when approaching 50k users. |

---

## Appendix A — Current Bottleneck Map (Revised)

```
USER ACTION                    BOTTLENECK                           FIX ITEM
───────────────────────────────────────────────────────────────────────────────
No Monitoring                  Zero observability into system health  #0.1-0.3

App Launch                     Login flow blocks on 2 sequential     #2.1
                                awaits before showing MainTabsView
                               No caching on exercise catalog        #2.2
                               Full workout history load              #2.3

Open Agent Chat                SSE proxy capped at 20 instances      #1.1
                               GCP token not cached (exchange)        #1.3
                               Premium check not cached               #1.2

Send Agent Message             Planning context: 4 sequential reads  #1.4
                               Rate limiter per-instance only         #3.2

During Workout (log set)       [OK — local-first, optimistic UI]     —

Complete Workout                Trigger fan-out: 35-45 writes         #3.1
                               Premium check (uncached) in trigger    #1.2

Browse Library                 Exercise catalog: 500+ reads           #2.2
Browse History                 Full collection scan                   #2.3

Endpoint Security              66/67 endpoints have no rate limit     #1.5, #1.6
                               or maxInstances cap

Complete Workout                Trigger fires ~126 Firestore writes   #3.2
                               No idempotency on retry for ~100       #3.3
                                of those writes

Background (cold start)        107 functions loaded per instance      #4.1
Background (data growth)       Unbounded set_facts, idempotency       #3.5
Background (agent quota)       Vertex AI default 10 concurrent        #1.8
```

---

## Appendix B — Cost Projections (Revised)

> **Note**: Original cost projections were based on 100k DAU with incorrect write counts (35-45 vs actual ~126). Revised projections below use verified data and target 10k users (3-month horizon) with extrapolation to 100k.

### At 10k Active Users (3-Month Target)

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| Firestore Reads | ~$100 | 50 reads/session × 10k users × 2 sessions/day |
| Firestore Writes | ~$60 | 126 writes/workout × 40k workouts/month |
| Firestore Storage | ~$10 | ~50GB total |
| LLM Tokens (Gemini 2.5 Flash) | ~$1,200 | 10k users × $0.12/user/month |
| Firebase Functions | ~$50 | Invocations + compute |
| Vertex AI Agent Engine | ~$50 | Session overhead |
| **Total** | **~$1,470/mo** | |

**Revenue at 10k users (5% conversion, $8.49 net/user)**: ~$4,245/month → **71% gross margin**

### Extrapolated to 100k Active Users

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| Firestore Reads | ~$600 | With caching optimizations (#2.2) |
| Firestore Writes | ~$350 | With async analytics (#3.2) reducing sync writes by 85% |
| Firestore Storage + Indexes | ~$500 | 2TB+ at scale |
| LLM Tokens (Gemini 2.5 Flash) | ~$4,800 | **Largest cost driver** |
| Firebase Functions | ~$400 | With v2 migration + bundle splitting |
| Redis (Memorystore) | ~$50 | Rate limiting |
| Vertex AI Agent Engine | ~$200 | Session overhead |
| **Total** | **~$6,900/mo** | |

**Revenue at 100k users (5% conversion, $8.49 net/user)**: ~$42,450/month → **84% gross margin**

### Original Estimates (Struck — Incorrect)

~~Original projections estimated $765k/month at 100k users. This was based on incorrect assumptions: 500+ reads/session (actual: 50-100 with caching), 200k LLM requests/day at $0.15 avg (actual: $0.002-0.003/request with Gemini 2.5 Flash), and 35-45 trigger writes (actual: ~126, but optimizable to ~13 sync). Firestore is NOT the cost crisis originally portrayed — LLM tokens are the dominant cost at scale.~~

| Component | Monthly Cost | Savings |
|-----------|-------------|---------|
| Firestore Reads | ~$18k | -80% (caching) |
| Firestore Writes | ~$5k | -80% (async analytics) |
| LLM Tokens | ~$540k | -15% (expanded Fast Lane) |
| Firebase Functions | ~$12k | -40% (v2 migration, fewer instances) |
| **Total** | **~$575k/mo** | **-$190k/mo (25%)** |

---

## Appendix C — File Reference Index

### Firebase Functions (Backend)

| File | Relevance | Fix Items |
|------|-----------|-----------|
| `firebase_functions/functions/index.js` | Function exports, v2 configs | #1.1, #3.3, #3.5 |
| `firebase_functions/functions/strengthos/stream-agent-normalized.js` | SSE proxy, premium gate, rate limit | #1.1, #1.2, #3.2 |
| `firebase_functions/functions/agents/get-planning-context.js` | Sequential reads | #1.4, #4.2 |
| `firebase_functions/functions/auth/exchange-token.js` | Token caching gap | #1.3 |
| `firebase_functions/functions/utils/subscription-gate.js` | Premium check, no cache | #1.2 |
| `firebase_functions/functions/utils/rate-limiter.js` | Per-instance rate limiter | #3.2 |
| `firebase_functions/functions/triggers/weekly-analytics.js` | Trigger fan-out (35-45 writes) | #3.1 |
| `firebase_functions/functions/training/set-facts-generator.js` | Set facts generation | #3.1, #3.4 |
| `firebase_functions/functions/active_workout/log-set.js` | Hot-path set logging | #3.4 (TTL) |
| `firebase_functions/functions/active_workout/complete-active-workout.js` | Completion flow | #3.1 |
| `firebase_functions/functions/user/get-user.js` | Reference cache implementation | #1.2 (pattern) |
| `firebase_functions/functions/subscriptions/app-store-webhook.js` | Subscription updates | #1.2 (invalidation) |
| `firebase_functions/functions/workouts/get-user-workouts.js` | Workout history query | #2.3 |
| `firebase_functions/functions/canvas/open-canvas.js` | Reference token cache | #1.3 (pattern) |

### iOS (Client)

| File | Relevance | Fix Items |
|------|-----------|-----------|
| `Povver/Povver/Views/RootView.swift` | App launch waterfall | #2.1 |
| `Povver/Povver/Views/MainTabsView.swift` | Redundant prefetch | #2.1 |
| `Povver/Povver/Views/Tabs/CoachTabView.swift` | Redundant pre-warm | #2.1 |
| `Povver/Povver/Views/Tabs/HistoryView.swift` | Client-side pagination | #2.3 |
| `Povver/Povver/Services/CacheManager.swift` | Unused cache infrastructure | #2.2 |
| `Povver/Povver/Services/DirectStreamingService.swift` | SSE client, connection reuse | #4.5 |
| `Povver/Povver/Services/SessionPreWarmer.swift` | Pre-warming logic | #2.1 |
| `Povver/Povver/Services/FocusModeWorkoutService.swift` | Prefetch orchestration | #2.1 |
| `Povver/Povver/Repositories/ExerciseRepository.swift` | No caching | #2.2 |
| `Povver/Povver/Repositories/TemplateRepository.swift` | No caching | #2.2 |
| `Povver/Povver/Repositories/RoutineRepository.swift` | No caching | #2.2 |
| `Povver/Povver/Repositories/WorkoutRepository.swift` | No pagination | #2.3 |
| `Povver/Povver/Repositories/RecommendationRepository.swift` | Listener leak | #1.5 |
| `Povver/Povver/ViewModels/RecommendationsViewModel.swift` | Missing cleanup | #1.5 |

### Agent System (Vertex AI)

| File | Relevance | Fix Items |
|------|-----------|-----------|
| `adk_agent/canvas_orchestrator/app/shell/router.py` | Fast Lane patterns | #4.1 |
| `adk_agent/canvas_orchestrator/app/shell/tools.py` | Tool definitions | #4.2 |
| `adk_agent/canvas_orchestrator/app/skills/coach_skills.py` | Planning context consumer | #1.4, #4.2 |
| `adk_agent/canvas_orchestrator/app/libs/tools_common/http.py` | HTTP connection pooling | (already good) |
| `adk_agent/canvas_orchestrator/app/libs/tools_canvas/client.py` | Firebase client | #1.4 |
| `adk_agent/training_analyst/workers/analyst_worker.py` | Background worker | #4.4 |

### Configuration & Infrastructure

| File | Relevance | Fix Items |
|------|-----------|-----------|
| `firebase.json` | Function deployment config | #3.3 |
| `firestore.rules` | Security rules | #3.2, #3.4 |
| `firestore.indexes.json` | Composite indexes | (verify) |

### Documentation (Update After Implementation)

| File | When to Update |
|------|----------------|
| `docs/SYSTEM_ARCHITECTURE.md` | After #3.1 (SSE refactor), #3.2 (async analytics), #3.4 (rate limiting) |
| `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` | After #3.2, #4.1, #4.2 |
| `docs/IOS_ARCHITECTURE.md` | After #2.1, #2.2, #2.3 |
| `docs/FIRESTORE_SCHEMA.md` | After #3.3 (workout_processing), #3.5 (TTL fields) |
| `docs/SECURITY.md` | After #1.5 (maxInstances), #1.6 (rate limiting), #3.4 (global rate limiting) |

---

## Appendix D — Scaling Thresholds

Break-glass reference for what to prioritize at each growth stage.

### 1k → 5k Users

**What breaks**: SSE connection cap (20) hit during peak workout hours (6-9 PM).

**Minimum fix**: Raise `maxInstances` to 100 (Phase 1.1 — config change only).

**Cost**: ~$300-500/month total infrastructure.

### 5k → 10k Users

**What breaks**: Cold starts noticeable (P95 latency spikes). Vertex AI quota (10 sessions) exceeded. Rate limiting ineffective (multiple instances).

**Minimum fix**:
- Phase 0 (observability — you MUST have monitoring before this scale)
- Phase 1.1-1.8 (SSE cap, caching, maxInstances, App Check, Vertex AI quota)
- Phase 2.2-2.3 (repository caching, workout pagination)

**Cost**: ~$1,500/month total infrastructure.

### 10k → 25k Users

**What breaks**: Per-instance rate limiting exploitable. Analytics trigger writes become expensive ($200+/month). Training analyst queue falls behind.

**Minimum fix**:
- Phase 3.1 (SSE race conditions → concurrency: 10)
- Phase 3.2 (hybrid analytics model)
- Phase 3.4 (Redis rate limiting)
- Phase 3.6 (training analyst parallelism)

**Cost**: ~$3,000/month total infrastructure (+ $50 Redis).

### 25k → 50k Users

**What breaks**: Firestore write costs from dual analytics systems. Bundle size causing slow cold starts.

**Minimum fix**:
- Consider consolidating legacy + token-safe analytics (halves writes)
- Phase 4.1 (bundle splitting)
- Phase 4.2 (v1→v2 migration)

**Cost**: ~$5,000/month total infrastructure.

### 50k → 100k Users

**What breaks**: Single-region latency for global users. Cloud Functions v2 timeout limit. Function instance costs.

**Minimum fix**:
- Phase 4.4 (Cloud Run for SSE)
- Multi-region evaluation
- Consider read replicas or edge caching

**Cost**: ~$7,000/month total infrastructure.
