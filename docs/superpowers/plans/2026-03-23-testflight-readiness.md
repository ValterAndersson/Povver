# TestFlight Readiness: Security & Quality Hardening

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all critical security vulnerabilities, high-priority quality gaps, and medium-priority hardening items before the first TestFlight build.

**Architecture:** Changes span two layers — Firebase Functions (backend security) and iOS app (client quality/safety). Backend changes are mostly independent — Task 1 (IDOR) and Task 2 (error leakage) share two files (`update-routine.js`, `update-template.js`), so Task 2 must run after Task 1 for those files. iOS changes are fully independent. No cross-layer dependencies exist.

**Architectural Decisions:**

1. **Deprecated endpoints (`update-routine.js`, `update-template.js`):** These are deprecated in favor of `patch-routine.js` / `patch-template.js` (which already use `getAuthenticatedUserId`). However, both deprecated endpoints still have active callers: `updateRoutine` is called by the agent service (`planner_skills.py:346`), and `updateTemplate` is called by iOS (`CloudFunctionService.swift:79`). **Decision:** Fix the IDOR vulnerability now. Migrate callers to `patch-*` endpoints in a follow-up task, then remove the deprecated endpoints entirely. Do not invest in refactoring or improving these files beyond the security fix — they are slated for removal.

2. **Error message leakage — centralized vs per-file:** A middleware-level error sanitizer would prevent future regressions, but is a larger refactor that touches the response pipeline for every endpoint. **Decision:** Fix per-file now (minimal risk, fast). Add `// TODO: migrate to centralized error handler` to the shared `mapErrorToResponse` function as a breadcrumb. The existing `mapErrorToResponse` in `shared/errors.js` is the right place to centralize this — it already handles error-to-HTTP mapping but currently passes `error.message` through. A follow-up should make it strip internal details from 500-level responses.

3. **`print()` prevention (iOS):** Fixing existing `print()` calls is necessary but doesn't prevent regressions. **Decision:** After fixing existing calls, add a Build Phase script that fails the build if bare `print(` appears outside `#if DEBUG` blocks in non-test Swift files. This is a ~5-line shell script and provides a permanent guard. Added as Task 14.

4. **`CloudFunctionService.swift` (iOS):** This file is noted as deprecated ("Prefer direct HTTP via ApiClient"). The force unwraps (Task 8) are in this deprecated file. **Decision:** Fix the force unwraps to prevent crashes, but do not invest in further improvements. Migration of remaining callers to `ApiClient` is out of scope.

**Tech Stack:** Node.js (Firebase Functions), Swift/SwiftUI (iOS), Firestore, Zod validation, StoreKit 2

---

## File Map

### Backend (Firebase Functions)

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `firebase_functions/functions/routines/create-routine.js` | IDOR fix: use `getAuthenticatedUserId` |
| Modify | `firebase_functions/functions/routines/update-routine.js` | IDOR fix + remove `error.message` leakage |
| Modify | `firebase_functions/functions/routines/delete-routine.js` | IDOR fix |
| Modify | `firebase_functions/functions/routines/set-active-routine.js` | IDOR fix |
| Modify | `firebase_functions/functions/templates/create-template.js` | IDOR fix |
| Modify | `firebase_functions/functions/templates/update-template.js` | IDOR fix + remove `error.message` leakage |
| Modify | `firebase_functions/functions/templates/delete-template.js` | IDOR fix |
| Modify | `firebase_functions/functions/user/update-user.js` | IDOR fix |
| Modify | `firebase_functions/functions/active_workout/log-set.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/active_workout/start-active-workout.js` | Remove `error.message` leakage + add rate limiting |
| Modify | `firebase_functions/functions/active_workout/complete-active-workout.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/active_workout/get-active-workout.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/active_workout/add-exercise.js` | Remove `error.message` leakage + input validation |
| Modify | `firebase_functions/functions/active_workout/swap-exercise.js` | Remove `error.message` leakage + input validation |
| Modify | `firebase_functions/functions/active_workout/cancel-active-workout.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/aliases/delete-alias.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/aliases/upsert-alias.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/artifacts/artifact-action.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/recommendations/review-recommendation.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/user/upsert-attributes.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/exercises/get-exercises.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/canvas/apply-action.js` | Remove `error.message` leakage + add input length validation |
| Modify | `firebase_functions/functions/canvas/propose-cards.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/canvas/emit-event.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/canvas/expire-proposals.js` | Remove `error.message` leakage + add query limit |
| Modify | `firebase_functions/functions/training/query-sets.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/exercises/upsert-exercise.js` | Remove `error.message` leakage |
| Modify | `firebase_functions/functions/analytics/compaction.js` | Add query limit |
| Create | `firebase_functions/functions/tests/idor-prevention.test.js` | Tests verifying IDOR fix in all 8 endpoints |

### iOS App

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Povver/Povver/Views/ConversationScreen.swift:299,436` | Add error handling for artifact actions |
| Modify | `Povver/Povver/Services/AuthService.swift:396-418` | Add error handling for Apple token revocation |
| Modify | `Povver/Povver/Services/CloudFunctionService.swift:53,71,78,101,108` | Replace force unwraps with safe unwraps |
| Modify | `Povver/Povver/Repositories/UserRepository.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Repositories/WorkoutRepository.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Services/ActiveWorkoutManager.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Services/MutationCoordinator.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Services/WorkoutSessionLogger.swift` | Replace `print()` + add file protection |
| Modify | `Povver/Povver/ViewModels/OnboardingViewModel.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Views/Settings/ConnectedAppsView.swift` | Replace `print()` + clipboard expiration |
| Modify | `Povver/Povver/Views/Settings/SubscriptionView.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Views/Settings/ProfileEditView.swift` | Replace `print()` with `AppLogger` |
| Modify | `Povver/Povver/Views/Settings/PreferencesView.swift` | Replace `print()` with `AppLogger` |
| Delete | `Povver/Povver/Services/SessionPreWarmer.swift` | Dead code removal |
| Delete | `Povver/Povver/Views/ChatHomeView.swift` | Dead code removal |
| Delete | `Povver/Povver/Views/ChatHomeEntry.swift` | Dead code removal |

---

## Task 1: Fix IDOR in 8 Backend Endpoints

**Priority:** CRITICAL — any authenticated user can currently read/write any other user's data through these endpoints.

**Files:**
- Modify: `firebase_functions/functions/routines/create-routine.js:17-18`
- Modify: `firebase_functions/functions/routines/update-routine.js:17-19`
- Modify: `firebase_functions/functions/routines/delete-routine.js:15-16`
- Modify: `firebase_functions/functions/routines/set-active-routine.js:15-16`
- Modify: `firebase_functions/functions/templates/create-template.js:16-18`
- Modify: `firebase_functions/functions/templates/update-template.js:16-17`
- Modify: `firebase_functions/functions/templates/delete-template.js:15-16`
- Modify: `firebase_functions/functions/user/update-user.js:14-17`
- Create: `firebase_functions/functions/tests/idor-prevention.test.js`

**Pattern:** Each file currently does `const { userId, ... } = req.body || {};`. Replace with:

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
// ...
const userId = getAuthenticatedUserId(req);
if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
```

Remove the `userId` destructuring from `req.body` and remove any `if (!userId)` checks that were validating the body-sourced value (those are now handled by the null check on `getAuthenticatedUserId`).

- [ ] **Step 1: Write the IDOR prevention test file**

Create `firebase_functions/functions/tests/idor-prevention.test.js`:

```javascript
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

/**
 * These tests verify that endpoints which previously read userId from req.body
 * now correctly use getAuthenticatedUserId(), which derives userId from the
 * verified auth token in bearer-lane requests.
 *
 * The actual IDOR prevention logic is tested in auth-helpers.test.js.
 * These tests verify the INTEGRATION — that each handler file imports and
 * uses getAuthenticatedUserId rather than reading req.body.userId directly.
 */

const IDOR_FIXED_FILES = [
  '../routines/create-routine',
  '../routines/update-routine',
  '../routines/delete-routine',
  '../routines/set-active-routine',
  '../templates/create-template',
  '../templates/update-template',
  '../templates/delete-template',
  '../user/update-user',
];

describe('IDOR prevention: all flexible-auth endpoints use getAuthenticatedUserId', () => {
  const fs = require('fs');
  const path = require('path');

  for (const modPath of IDOR_FIXED_FILES) {
    const fileName = modPath.split('/').pop();
    test(`${fileName} imports getAuthenticatedUserId`, () => {
      const filePath = path.resolve(__dirname, modPath + '.js');
      const source = fs.readFileSync(filePath, 'utf-8');
      assert.ok(
        source.includes("getAuthenticatedUserId"),
        `${fileName}.js must import and use getAuthenticatedUserId`
      );
      // Must NOT destructure userId from req.body for auth purposes
      // (may still destructure other fields from req.body)
      const bodyUserIdPattern = /const\s*\{[^}]*userId[^}]*\}\s*=\s*req\.body/;
      assert.ok(
        !bodyUserIdPattern.test(source),
        `${fileName}.js must NOT destructure userId from req.body`
      );
    });
  }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd firebase_functions/functions && npm test -- --test-name-pattern="IDOR prevention"`
Expected: 8 FAIL — all files currently destructure userId from req.body.

- [ ] **Step 3: Fix `create-routine.js`**

Replace the handler to use `getAuthenticatedUserId`:

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { fail } = require('../utils/response');

async function createRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routine } = req.body || {};
  // ... rest unchanged
```

- [ ] **Step 4: Fix `update-routine.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

async function updateRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routineId, routine } = req.body || {};
  if (!routineId || !routine) return fail(res, 'INVALID_ARGUMENT', 'Missing required parameters', ['routineId','routine'], 400);
  // ... rest unchanged
```

- [ ] **Step 5: Fix `delete-routine.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { fail } = require('../utils/response');

async function deleteRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routineId } = req.body || {};
  // ... rest unchanged
```

- [ ] **Step 6: Fix `set-active-routine.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { fail } = require('../utils/response');

async function setActiveRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routineId } = req.body || {};
  // ... rest unchanged
```

- [ ] **Step 7: Fix `create-template.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

async function createTemplateHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { template } = req.body || {};
  // ... rest unchanged
```

- [ ] **Step 8: Fix `update-template.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

async function updateTemplateHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { templateId: bodyTemplateId, template } = req.body || {};
  // ... rest unchanged (remove userId from destructuring)
```

- [ ] **Step 9: Fix `delete-template.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { fail } = require('../utils/response');

async function deleteTemplateHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { templateId } = req.body || {};
  // ... rest unchanged
```

- [ ] **Step 10: Fix `update-user.js`**

```javascript
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ok, fail } = require('../utils/response');

async function updateUserHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { userData } = req.body || {};
  // ... rest unchanged, but also convert raw res.status().json() calls to ok()/fail()
```

- [ ] **Step 11: Run the IDOR test to verify it passes**

Run: `cd firebase_functions/functions && npm test -- --test-name-pattern="IDOR prevention"`
Expected: 8 PASS

- [ ] **Step 12: Run full backend test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass.

- [ ] **Step 13: Commit**

```bash
git add firebase_functions/functions/routines/ firebase_functions/functions/templates/ firebase_functions/functions/user/update-user.js firebase_functions/functions/tests/idor-prevention.test.js
git commit -m "fix(security): use getAuthenticatedUserId in 8 IDOR-vulnerable endpoints

All requireFlexibleAuth endpoints now derive userId from the verified
auth token instead of req.body. Prevents authenticated users from
accessing other users' routines, templates, and profile data.

Adds IDOR prevention regression tests."
```

---

## Task 2: Remove Error Message Leakage from Backend

**Priority:** HIGH — internal error details (Firestore messages, paths) exposed to clients.

**Files:** ~20 endpoint files (see File Map above)

**Pattern:** Replace `{ message: error.message }` in 500-level error responses with a generic string. Keep `error.message` in validation errors (400-level) where it contains user-relevant info.

```javascript
// BEFORE (leaks internals):
return fail(res, 'INTERNAL', 'Failed to update routine', { message: error.message }, 500);

// AFTER (safe):
return fail(res, 'INTERNAL', 'Failed to update routine', null, 500);
```

Always log the real error server-side before returning the generic response:

```javascript
logger.error('[endpointName] operation failed', { error: error.message, stack: error.stack });
return fail(res, 'INTERNAL', 'Operation failed', null, 500);
```

- [ ] **Step 1: Fix all `active_workout/` endpoints**

Files: `log-set.js`, `start-active-workout.js`, `complete-active-workout.js`, `get-active-workout.js`, `add-exercise.js`, `swap-exercise.js`, `cancel-active-workout.js`

In each file, find the catch block that returns `{ message: error.message }` and replace with `null`. Ensure `logger.error` (not `console.error`) is called before the return.

- [ ] **Step 2: Fix all `aliases/`, `artifacts/`, `canvas/`, `recommendations/` endpoints**

Files: `delete-alias.js`, `upsert-alias.js`, `artifact-action.js`, `apply-action.js`, `propose-cards.js`, `emit-event.js`, `expire-proposals.js`, `review-recommendation.js`

Same pattern: replace `{ message: error.message }` with `null`, ensure server-side logging.

- [ ] **Step 3: Fix remaining endpoints**

Files: `update-template.js`, `update-routine.js`, `upsert-attributes.js`, `get-exercises.js`, `upsert-exercise.js`, `query-sets.js`

Same pattern.

- [ ] **Step 4: Also replace `console.error` with `logger.error` in all touched files**

`console.error` works but lacks structured metadata. Use `logger.error` from `firebase-functions` consistently.

- [ ] **Step 5: Run full backend test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add firebase_functions/functions/
git commit -m "fix(security): stop leaking error.message in 500 responses

Replace raw error.message in client-facing error responses with generic
messages. Internal details now logged server-side only via logger.error.
Also migrates console.error to structured logger.error."
```

---

## Task 3: Add Rate Limiting to Write Endpoints

**Priority:** HIGH — `authLimiter` and `writeLimiter` are defined but never used anywhere.

**Files:**
- Modify: `firebase_functions/functions/active_workout/log-set.js`
- Modify: `firebase_functions/functions/active_workout/start-active-workout.js`
- Modify: `firebase_functions/functions/mcp/generate-api-key.js`
- Modify: `firebase_functions/functions/subscriptions/sync-subscription-status.js`

**Pattern:** Import the appropriate limiter and add a check after the existing userId derivation, before business logic:

```javascript
const { writeLimiter } = require('../utils/rate-limiter');

// Inside handler, AFTER the existing userId derivation (these files already
// derive userId from req.user?.uid || req.auth?.uid — they do NOT need
// getAuthenticatedUserId imported; they already have it or use equivalent):
if (!writeLimiter.check(userId)) {
  return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
}
```

Use `authLimiter` for `syncSubscriptionStatus` and `generateMcpApiKey` (sensitive operations). Use `writeLimiter` for `logSet` and `startActiveWorkout`. Each of these files already derives userId securely — just add the limiter check using the existing `userId` variable.

- [ ] **Step 1: Add `writeLimiter` to `log-set.js` and `start-active-workout.js`**

Import `writeLimiter` from `../utils/rate-limiter`. Add check after userId derivation, before business logic.

- [ ] **Step 2: Add `authLimiter` to `generate-api-key.js` and `sync-subscription-status.js`**

Import `authLimiter` from `../utils/rate-limiter`. Add check after userId derivation.

- [ ] **Step 3: Run full backend test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add firebase_functions/functions/active_workout/ firebase_functions/functions/mcp/generate-api-key.js firebase_functions/functions/subscriptions/sync-subscription-status.js
git commit -m "fix(security): apply rate limiting to write and auth-sensitive endpoints

writeLimiter (300/min) on logSet, startActiveWorkout.
authLimiter (10/min) on generateMcpApiKey, syncSubscriptionStatus.
These limiters were defined but never used."
```

---

## Task 4: Add Input Validation to Under-Validated Endpoints

**Priority:** MEDIUM — missing string length and numeric bounds on user-controlled fields.

**Files:**
- Modify: `firebase_functions/functions/active_workout/add-exercise.js`
- Modify: `firebase_functions/functions/active_workout/swap-exercise.js`
- Modify: `firebase_functions/functions/canvas/apply-action.js`

- [ ] **Step 1: Add validation to `add-exercise.js`**

After existing `!workoutId || !exerciseId` check, add:
```javascript
const { MAX_NAME_LENGTH, MAX_WEIGHT_KG } = require('../utils/validators');
if (name && name.length > MAX_NAME_LENGTH) return fail(res, 'INVALID_ARGUMENT', 'Exercise name too long', null, 400);
// In set validation loop, add upper bound:
if (set.weight !== undefined && set.weight > MAX_WEIGHT_KG) return fail(res, 'INVALID_ARGUMENT', 'Weight exceeds maximum', null, 400);
```

- [ ] **Step 2: Add validation to `swap-exercise.js`**

Add length check on `reason`:
```javascript
if (reason && reason.length > 5000) return fail(res, 'INVALID_ARGUMENT', 'Reason too long', null, 400);
```

- [ ] **Step 3: Add validation to `apply-action.js` for text fields**

For `ADD_INSTRUCTION` and `ADD_NOTE` actions, validate text length:
```javascript
const MAX_TEXT_LENGTH = 5000;
if (text && text.length > MAX_TEXT_LENGTH) return fail(res, 'INVALID_ARGUMENT', 'Text too long', null, 400);
```

- [ ] **Step 4: Run full backend test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/active_workout/ firebase_functions/functions/canvas/apply-action.js
git commit -m "fix(security): add input validation bounds to under-validated endpoints

add-exercise: name length, weight upper bound
swap-exercise: reason length
apply-action: instruction/note text length"
```

---

## Task 5: Add Query Limits to Unbounded Firestore Queries

**Priority:** MEDIUM — queries that could return unbounded results.

**Files:**
- Modify: `firebase_functions/functions/analytics/compaction.js:81`
- Modify: `firebase_functions/functions/canvas/apply-action.js:604`
- Modify: `firebase_functions/functions/canvas/expire-proposals.js:53`

- [ ] **Step 1: Add `.limit()` to each unbounded query**

```javascript
// compaction.js:81 — add limit to series collection read
seriesCol.limit(10000).get()  // Safety bound — no user should have >10k series docs

// apply-action.js:604 — add limit to up_next read
upCol.orderBy('priority', 'desc').orderBy('inserted_at', 'asc').limit(500).get()

// expire-proposals.js:53 — add limit to canvases read
db.collection(`users/${userId}/canvases`).limit(500).get()
```

- [ ] **Step 2: Run full backend test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/analytics/compaction.js firebase_functions/functions/canvas/apply-action.js firebase_functions/functions/canvas/expire-proposals.js
git commit -m "fix(security): add query limits to unbounded Firestore reads

Prevents OOM and cost amplification from unexpectedly large collections."
```

---

## Task 6: Fix Silent Failures in iOS Artifact Actions

**Priority:** CRITICAL — users get no feedback when accept/dismiss actions fail.

**Files:**
- Modify: `Povver/Povver/Views/ConversationScreen.swift:294-302,431-441`

- [ ] **Step 1: Replace `try?` with proper error handling for accept action**

At line ~299, replace:
```swift
Task { _ = try? await AgentsApi.artifactAction(userId: uid, conversationId: conversationId, artifactId: artifactId, action: "accept") }
```
with:
```swift
Task {
    do {
        _ = try await AgentsApi.artifactAction(userId: uid, conversationId: conversationId, artifactId: artifactId, action: "accept")
    } catch {
        await MainActor.run { vm.errorMessage = "Failed to accept plan. Please try again." }
    }
}
```

- [ ] **Step 2: Replace `try?` with proper error handling for dismiss action**

At line ~436, same pattern:
```swift
Task {
    do {
        _ = try await AgentsApi.artifactAction(userId: uid, conversationId: conversationId, artifactId: artifactId, action: "dismiss")
    } catch {
        await MainActor.run { vm.errorMessage = "Failed to dismiss. Please try again." }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Views/ConversationScreen.swift
git commit -m "fix(ios): add error handling for artifact accept/dismiss actions

Users now see error feedback when accept or dismiss fails instead of
silent failure."
```

---

## Task 7: Fix Apple Token Revocation Compliance

**Priority:** CRITICAL — App Store requirement 5.1.1(v).

**Files:**
- Modify: `Povver/Povver/Services/AuthService.swift:396-418`

- [ ] **Step 1: Add error handling for Apple token revocation**

Replace the `try?` block at line ~400-404:

```swift
if linkedProviders.contains(.apple) {
    if let userDoc = try? await UserRepository.shared.getUser(userId: userId),
       let authCode = userDoc.appleAuthorizationCode {
        do {
            try await Auth.auth().revokeToken(withAuthorizationCode: authCode)
        } catch {
            // Token revocation failed — Apple credential may remain active.
            // Log but proceed with deletion — the auth code may have expired
            // (Apple auth codes are single-use, so if it was already used for
            // a prior revocation attempt, this is expected).
            AppLogger.shared.error(.app, "Apple token revocation failed", error)
        }
    }
}
```

The key change: replace `try?` with `do/catch` and log the failure. We still proceed with deletion because:
1. Apple auth codes are single-use — if previously consumed, revocation will always fail
2. Blocking deletion on revocation failure would trap users who can't delete their accounts
3. The server-side `deleteAccount` Cloud Function also handles cleanup

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/Services/AuthService.swift
git commit -m "fix(ios): log Apple token revocation failures during account deletion

Replaces silent try? with logged do/catch. Proceeds with deletion but
records the failure for audit trail. Addresses App Store guideline
5.1.1(v) compliance."
```

---

## Task 8: Replace Force Unwraps in CloudFunctionService

**Priority:** HIGH — potential crashes in production.

**Files:**
- Modify: `Povver/Povver/Services/CloudFunctionService.swift:53,71,78,101,108`

- [ ] **Step 1: Replace all `String(data:encoding:)!` with safe unwraps**

Replace each occurrence of:
```swift
String(data: data, encoding: .utf8)!
```
with:
```swift
String(data: data, encoding: .utf8) ?? ""
```

An empty string is safe here because these values are being passed as function parameters — the backend will reject empty values with a validation error, which is better than a crash.

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/Services/CloudFunctionService.swift
git commit -m "fix(ios): replace force unwraps with safe fallbacks in CloudFunctionService

Prevents potential crashes from String(data:encoding:) returning nil."
```

---

## Task 9: Replace Unguarded `print()` with `AppLogger`

**Priority:** HIGH — userId and operational data logged in release builds.

**Files:** (see File Map — 13 iOS files)

**Pattern:** Replace every bare `print(...)` with the appropriate `AppLogger.shared` call. `AppLogger` no-ops in release builds.

**AppLogger API reference** (from `Services/DebugLogger.swift`):
- `AppLogger.shared.error(_ cat: Cat, _ msg: String, _ err: Error? = nil)` — for errors
- `AppLogger.shared.info(_ cat: Cat, _ msg: String)` — for status/debug info
- `Cat` enum: `.app`, `.http`, `.store`, `.agent`, `.work`
- No `.warning()` or `.debug()` methods exist — use `.error()` or `.info()` only

```swift
// BEFORE:
print("[UserRepository] Error fetching user: \(error)")

// AFTER:
AppLogger.shared.error(.store, "Error fetching user", error)
```

```swift
// BEFORE:
print("[ActiveWorkoutManager] Loading preferences for \(userId)")

// AFTER:
AppLogger.shared.info(.work, "Loading preferences")
```

Category mapping:
- Repository/Firestore errors → `.store`
- Service/manager errors → `.work` (workout-related) or `.app` (general)
- View/UI errors → `.app`
- Network errors → `.http`

**Important:** Do not include userId in the log message — `AppLogger` intentionally omits user identifiers. Search each file for `print(` to find all occurrences rather than relying solely on line numbers, which may have drifted.

- [ ] **Step 1: Fix `Repositories/UserRepository.swift`** (lines 19, 28, 67, 69, 80)
- [ ] **Step 2: Fix `Repositories/WorkoutRepository.swift`** (lines 18, 38)
- [ ] **Step 3: Fix `Services/ActiveWorkoutManager.swift`** (lines 34, 46, 51, 71, 81, 84, 187, 196, 208, 231)
- [ ] **Step 4: Fix `Services/MutationCoordinator.swift`** (line 558)
- [ ] **Step 5: Fix `Services/WorkoutSessionLogger.swift`** (line 208)
- [ ] **Step 6: Fix `ViewModels/OnboardingViewModel.swift`** (line 174)
- [ ] **Step 7: Fix `Views/Settings/ConnectedAppsView.swift`** (lines 327, 347, 365)
- [ ] **Step 8: Fix `Views/Settings/SubscriptionView.swift`** (line 268)
- [ ] **Step 9: Fix `Views/Settings/ProfileEditView.swift`** (lines 447, 453)
- [ ] **Step 10: Fix `Views/Settings/PreferencesView.swift`** (lines 127, 150)

- [ ] **Step 11: Verify no bare `print(` remains outside `#if DEBUG`**

Search: `grep -rn "print(" Povver/Povver/ --include="*.swift" | grep -v "#if DEBUG" | grep -v "Preview" | grep -v "AppLogger"`
Expected: No matches in the modified files.

- [ ] **Step 12: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 13: Commit**

```bash
git add Povver/Povver/
git commit -m "fix(ios): replace bare print() with AppLogger in release-accessible code

Prevents userId and operational data from being logged to device console
in release builds. AppLogger no-ops in release via @inline(__always)."
```

---

## Task 10: Add File Protection to Workout Logs + Crashlytics Breadcrumb Cleanup

**Priority:** MEDIUM — health-adjacent data written without encryption, sent to Crashlytics.

**Files:**
- Modify: `Povver/Povver/Services/WorkoutSessionLogger.swift:177-179,206`

- [ ] **Step 1: Add NSFileProtection to workout log files**

After writing the file at line ~206, add:
```swift
try (fileURL as NSURL).setResourceValue(
    URLFileProtection.complete,
    forKey: .fileProtectionKey
)
```

Also set protection on the directory in `logDirectory()`:
```swift
try FileManager.default.setAttributes(
    [.protectionKey: FileProtectionType.complete],
    ofItemAtPath: dir.path
)
```

- [ ] **Step 2: Reduce Crashlytics breadcrumb detail**

At line ~178, replace:
```swift
let summary = "\(type.rawValue)\(details.map { " \($0)" } ?? "")"
```
with:
```swift
let summary = type.rawValue  // Log event type only — no workout details to Crashlytics
```

This keeps the breadcrumb useful for crash correlation (knowing which event type was last processed) without sending exercise names, weights, or reps to a third-party service.

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/Services/WorkoutSessionLogger.swift
git commit -m "fix(ios): add file protection to workout logs, reduce Crashlytics detail

Sets NSFileProtection.complete on workout log files so they are
unreadable when device is locked. Crashlytics breadcrumbs now log
event type only, not workout details (exercise names, weights, reps)."
```

---

## Task 11: Add Clipboard Expiration for MCP API Keys

**Priority:** MEDIUM — API key persists in clipboard indefinitely.

**Files:**
- Modify: `Povver/Povver/Views/Settings/ConnectedAppsView.swift:231`

- [ ] **Step 1: Replace clipboard copy with expiring version**

Replace:
```swift
UIPasteboard.general.string = generatedKey
```
with:
```swift
UIPasteboard.general.setItems(
    [[UIPasteboard.typeAutomatic: generatedKey]],
    options: [.expirationDate: Date().addingTimeInterval(120)]
)
```

This auto-clears the API key from clipboard after 2 minutes.

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver/Views/Settings/ConnectedAppsView.swift
git commit -m "fix(ios): auto-expire MCP API key from clipboard after 2 minutes"
```

---

## Task 12: Remove Dead Code Files

**Priority:** LOW — code hygiene before TestFlight.

**Files:**
- Delete: `Povver/Povver/Services/SessionPreWarmer.swift`
- Delete: `Povver/Povver/Views/ChatHomeView.swift`
- Delete: `Povver/Povver/Views/ChatHomeEntry.swift`

- [ ] **Step 1: Verify files are truly unreferenced**

Search for imports/references to `SessionPreWarmer`, `ChatHomeView`, `ChatHomeEntry` across the project. Confirm zero references (excluding the files themselves and preview providers).

- [ ] **Step 2: Remove from Xcode project and filesystem**

Delete the three files. If they are referenced in `project.pbxproj`, they also need to be removed from the Xcode project file. The safest approach is to remove them via Xcode or by editing `project.pbxproj`.

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A Povver/
git commit -m "chore(ios): remove dead code files

SessionPreWarmer.swift — empty stub from session elimination.
ChatHomeView.swift, ChatHomeEntry.swift — unreachable predecessor views
replaced by CoachTabView."
```

---

## Task 13: Add `ITSAppUsesNonExemptEncryption` to Info.plist

**Priority:** LOW — saves manual compliance prompt on every TestFlight upload.

**Files:**
- Modify: Xcode project build settings (Info.plist keys are generated via build settings with `GENERATE_INFOPLIST_FILE = YES`)

- [ ] **Step 1: Add the key via Xcode build settings**

Add to the target's build settings or via `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` in the project.pbxproj, or add it to a supplementary Info.plist.

The app uses only standard HTTPS (TLS via URLSession), which is exempt from export compliance requirements.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Povver/
git commit -m "chore(ios): add ITSAppUsesNonExemptEncryption=NO to skip compliance prompt"
```

---

## Task 14: Add Build Phase Guard Against Bare `print()` in Release Code

**Priority:** MEDIUM — prevents regression of Task 9 fixes.

**Files:**
- Modify: `Povver/Povver.xcodeproj/project.pbxproj` (add Run Script build phase)

**Rationale:** Task 9 fixes ~46 `print()` calls. Without a guard, new ones will accumulate. A build phase script catches them at compile time.

- [ ] **Step 1: Add a Run Script build phase to the Povver target**

Script name: "Lint: No bare print() in release code"
Position: Before "Compile Sources"

```bash
if [ "$CONFIGURATION" = "Release" ]; then
  FOUND=$(grep -rn "print(" "$SRCROOT/Povver" --include="*.swift" \
    | grep -v "//.*print(" \
    | grep -v "#if DEBUG" \
    | grep -v "Preview" \
    | grep -v "AppLogger" \
    | grep -v ".build/" || true)
  if [ -n "$FOUND" ]; then
    echo "error: Bare print() found in release code. Use AppLogger instead:"
    echo "$FOUND"
    exit 1
  fi
fi
```

This only fails Release builds — Debug builds allow `print()` for quick iteration. The grep exclusions avoid false positives from comments, DEBUG blocks, previews, and AppLogger references.

- [ ] **Step 2: Build in Release mode to verify the script works**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Release build`
Expected: BUILD SUCCEEDED (assuming Task 9 is already done)

- [ ] **Step 3: Commit**

```bash
git add Povver/Povver.xcodeproj/project.pbxproj
git commit -m "chore(ios): add build phase guard against bare print() in release builds

Fails Release builds if bare print() is found in Swift source files.
Prevents regression of print-to-AppLogger migration."
```

---

## Execution Order

Tasks are grouped by independence for maximum parallelism:

**Wave 1a — Backend (parallel):**
- Task 1: IDOR fixes (CRITICAL)
- Task 3: Rate limiting (HIGH)
- Task 4: Input validation (MEDIUM)
- Task 5: Query limits (MEDIUM)

**Wave 1b — Backend (after Task 1, since they share `update-routine.js` and `update-template.js`):**
- Task 2: Error message leakage (HIGH)

**Wave 2 — iOS (all independent, can run in parallel):**
- Task 6: Artifact action error handling (CRITICAL)
- Task 7: Apple token revocation (CRITICAL)
- Task 8: Force unwrap fixes (HIGH)
- Task 9: Print → AppLogger (HIGH)
- Task 10: File protection + Crashlytics (MEDIUM)
- Task 11: Clipboard expiration (MEDIUM)
- Task 12: Dead code removal (LOW)
- Task 13: Export compliance key (LOW)

**Wave 2b — iOS (after Task 9, depends on print() being fixed first):**
- Task 14: Build phase guard against print() (MEDIUM)

**Wave 3 — Verification:**
- Full backend test suite: `cd firebase_functions/functions && npm test`
- Full iOS build: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
- Deploy backend: `cd firebase_functions/functions && npm run deploy`
