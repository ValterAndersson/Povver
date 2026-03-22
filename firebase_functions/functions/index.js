// Alias ops
const { upsertAlias } = require('./aliases/upsert-alias');
const { deleteAlias } = require('./aliases/delete-alias');
// Suggestions/Refine
const { suggestFamilyVariant } = require('./exercises/suggest-family-variant');
const { suggestAliases } = require('./exercises/suggest-aliases');
const { refineExercise } = require('./exercises/refine-exercise');
const { searchAliases } = require('./exercises/search-aliases');
const functions = require('firebase-functions');
const { onRequest: onRequestV2 } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');

// Initialize admin if not already initialized
if (!admin.apps.length) {
  admin.initializeApp();
}

// Middleware
const { withApiKey } = require('./auth/middleware');
const { getAuthenticatedUserId } = require('./utils/auth-helpers');

// Health Check
const { health } = require('./health/health');

// User Operations
const { getUser } = require('./user/get-user');
const { updateUser } = require('./user/update-user');
const { getUserPreferences } = require('./user/get-preferences');
const { updateUserPreferences } = require('./user/update-preferences');
const { upsertUserAttributes } = require('./user/upsert-attributes');
const { deleteAccount } = require('./user/delete-account');

// Workout Operations  
const { getUserWorkouts } = require('./workouts/get-user-workouts');
const { getWorkout } = require('./workouts/get-workout');
const { upsertWorkout } = require('./workouts/upsert-workout');
const { deleteWorkout } = require('./workouts/delete-workout');

// Template Operations
const { getUserTemplates } = require('./templates/get-user-templates');
const { getTemplate } = require('./templates/get-template');
const { createTemplate } = require('./templates/create-template');
const { updateTemplate } = require('./templates/update-template');
const { deleteTemplate } = require('./templates/delete-template');
const { createTemplateFromPlan } = require('./templates/create-template-from-plan');
const { patchTemplate } = require('./templates/patch-template');

// Routine Operations
const { getUserRoutines } = require('./routines/get-user-routines');
const { getRoutine } = require('./routines/get-routine');
const { createRoutine } = require('./routines/create-routine');
const { updateRoutine } = require('./routines/update-routine');
const { deleteRoutine } = require('./routines/delete-routine');
const { getActiveRoutine } = require('./routines/get-active-routine');
const { setActiveRoutine } = require('./routines/set-active-routine');
const { getNextWorkout } = require('./routines/get-next-workout');
const { patchRoutine } = require('./routines/patch-routine');

// Exercise Operations
const { getExercises } = require('./exercises/get-exercises');
const { getExercise } = require('./exercises/get-exercise');
const { searchExercises } = require('./exercises/search-exercises');
const { upsertExercise } = require('./exercises/upsert-exercise');
const { approveExercise } = require('./exercises/approve-exercise');
const { ensureExerciseExists } = require('./exercises/ensure-exercise-exists');
const { resolveExercise } = require('./exercises/resolve-exercise');
const { mergeExercises } = require('./exercises/merge-exercises');
const { backfillNormalizeFamily } = require('./exercises/backfill-normalize-family');
const { backupExercises, duplicateCatalog } = require('./maintenance/backup-exercises');
const { repointAlias } = require('./maintenance/repoint-alias');
const { repointShorthandAliases } = require('./maintenance/repoint-shorthand-aliases');
const { normalizeCatalog } = require('./exercises/normalize-catalog');
const { listFamilies } = require('./exercises/list-families');
const { normalizeCatalogPage } = require('./exercises/normalize-catalog-page');

// Active Workout Operations
const { proposeSession } = require('./active_workout/propose-session');
const { startActiveWorkout } = require('./active_workout/start-active-workout');
const { getActiveWorkout } = require('./active_workout/get-active-workout');
const { logSet } = require('./active_workout/log-set');
const { patchActiveWorkout } = require('./active_workout/patch-active-workout');
const { autofillExercise } = require('./active_workout/autofill-exercise');
const { addExercise } = require('./active_workout/add-exercise');
const { swapExercise } = require('./active_workout/swap-exercise');
const { completeActiveWorkout } = require('./active_workout/complete-active-workout');
const { cancelActiveWorkout } = require('./active_workout/cancel-active-workout');
const { completeCurrentSet } = require('./active_workout/complete-current-set');

// StrengthOS Operations
const { streamAgentNormalizedHandler } = require('./strengthos/stream-agent-normalized');
const { requireFlexibleAuth } = require('./auth/middleware');
const { upsertProgressReport, getProgressReports } = require('./strengthos/progress-reports');

// Artifact Operations
const { artifactAction } = require('./artifacts/artifact-action');

// Canvas Operations
const { applyAction } = require('./canvas/apply-action');
const { proposeCards } = require('./canvas/propose-cards');
const { expireProposals } = require('./canvas/expire-proposals');
const { emitEvent } = require('./canvas/emit-event');
const { purgeCanvas } = require('./canvas/purge-canvas');

// Analytics
const { runAnalyticsForUser } = require('./analytics/controller');
const { analyticsCompactionScheduled, compactAnalyticsForUser } = require('./analytics/compaction');
const { publishWeeklyJob } = require('./analytics/publish-weekly-job');
const { recalculateWeeklyForUser } = require('./analytics/recalculate-weekly-for-user');
// Agents
const { getPlanningContext } = require('./agents/get-planning-context');
const { applyProgression } = require('./agents/apply-progression');

// Token-safe Training Analytics v2
const { querySets, aggregateSets } = require('./training/query-sets');
const { getMuscleGroupSummary, getMuscleSummary, getExerciseSummary } = require('./training/progress-summary');
const { getActiveSnapshotLite } = require('./training/context-pack');
const { getActiveEvents } = require('./training/active-events');
const { getAnalysisSummary } = require('./training/get-analysis-summary');

// MCP API Key Operations
const { generateMcpApiKey } = require('./mcp/generate-api-key');
const { listMcpApiKeys } = require('./mcp/list-api-keys');
const { revokeMcpApiKey } = require('./mcp/revoke-api-key');

// MCP OAuth Connection Operations
const { getMcpConnectionStatus } = require('./mcp/get-connection-status');
const { revokeMcpTokens } = require('./mcp/revoke-tokens');

// Subscription Operations
const { appStoreWebhook } = require('./subscriptions/app-store-webhook');
const { syncSubscriptionStatus } = require('./subscriptions/sync-subscription-status');

// Recommendation Operations
const { reviewRecommendation } = require('./recommendations/review-recommendation');

// Firestore Triggers
const {
  onTemplateCreated,
  onTemplateUpdated,
  onWorkoutCreated
} = require('./triggers/muscle-volume-calculations');
const {
  onWorkoutDeleted,
  weeklyStatsRecalculation,
  manualWeeklyStatsRecalculation,
} = require('./triggers/weekly-analytics');
const { processWorkoutCompletionTask } = require('./triggers/workout-completion-task');
const { workoutCompletionWatchdog } = require('./triggers/workout-completion-watchdog');
const { onAnalysisInsightCreated, onWeeklyReviewCreated, expireStaleRecommendations } = require('./triggers/process-recommendations');

// Export all functions as Firebase HTTPS functions
exports.health = functions.https.onRequest(health);

// User Operations
exports.getUser = functions.https.onRequest((req, res) => withApiKey(getUser)(req, res));
exports.updateUser = functions.https.onRequest((req, res) => withApiKey(updateUser)(req, res));
exports.getUserPreferences = functions.https.onRequest((req, res) => withApiKey(getUserPreferences)(req, res));
// updateUserPreferences is a v2 onRequest with requireFlexibleAuth — called by iOS app
exports.updateUserPreferences = updateUserPreferences;
exports.upsertUserAttributes = functions.https.onRequest((req, res) => withApiKey(upsertUserAttributes)(req, res));
// Account deletion — v2 onRequest with requireFlexibleAuth (bearer only, iOS app)
exports.deleteAccount = deleteAccount;

// Workout Operations
exports.getUserWorkouts = functions.https.onRequest((req, res) => withApiKey(getUserWorkouts)(req, res));
exports.getWorkout = functions.https.onRequest((req, res) => withApiKey(getWorkout)(req, res));
// upsertWorkout is a v2 onRequest with requireFlexibleAuth - used by import scripts, not exposed to agents
exports.upsertWorkout = upsertWorkout;
// deleteWorkout is a v2 onRequest with requireFlexibleAuth - iOS app calls
exports.deleteWorkout = deleteWorkout;

// Template Operations
// getUserTemplates is already a v2 onRequest function with requireFlexibleAuth from get-user-templates.js
exports.getUserTemplates = getUserTemplates;
// getTemplate is already a v2 onRequest function with requireFlexibleAuth from get-template.js
exports.getTemplate = getTemplate;
exports.createTemplate = functions.https.onRequest((req, res) => withApiKey(createTemplate)(req, res));
exports.updateTemplate = functions.https.onRequest((req, res) => withApiKey(updateTemplate)(req, res));
exports.deleteTemplate = functions.https.onRequest((req, res) => withApiKey(deleteTemplate)(req, res));
exports.createTemplateFromPlan = functions.https.onRequest((req, res) => requireFlexibleAuth(createTemplateFromPlan)(req, res));
exports.patchTemplate = functions.https.onRequest((req, res) => requireFlexibleAuth(patchTemplate)(req, res));

// Routine Operations
// getUserRoutines is already a v2 onRequest function with requireFlexibleAuth from get-user-routines.js
exports.getUserRoutines = getUserRoutines;
exports.getRoutine = functions.https.onRequest((req, res) => requireFlexibleAuth(getRoutine)(req, res));
exports.createRoutine = functions.https.onRequest((req, res) => withApiKey(createRoutine)(req, res));
exports.updateRoutine = functions.https.onRequest((req, res) => withApiKey(updateRoutine)(req, res));
exports.deleteRoutine = functions.https.onRequest((req, res) => withApiKey(deleteRoutine)(req, res));
exports.getActiveRoutine = functions.https.onRequest((req, res) => withApiKey(getActiveRoutine)(req, res));
exports.setActiveRoutine = functions.https.onRequest((req, res) => withApiKey(setActiveRoutine)(req, res));
exports.getNextWorkout = getNextWorkout;
exports.patchRoutine = functions.https.onRequest((req, res) => requireFlexibleAuth(patchRoutine)(req, res));

// Exercise Operations
exports.getExercises = functions.https.onRequest((req, res) => withApiKey(getExercises)(req, res));
exports.getExercise = functions.https.onRequest((req, res) => withApiKey(getExercise)(req, res));
// searchExercises is already a v2 onRequest function from search-exercises.js
exports.searchExercises = searchExercises;
exports.upsertExercise = functions.https.onRequest((req, res) => withApiKey(upsertExercise)(req, res));
exports.approveExercise = functions.https.onRequest((req, res) => withApiKey(approveExercise)(req, res));
exports.ensureExerciseExists = functions.https.onRequest((req, res) => withApiKey(ensureExerciseExists)(req, res));
exports.resolveExercise = functions.https.onRequest((req, res) => withApiKey(resolveExercise)(req, res));
exports.mergeExercises = functions.https.onRequest((req, res) => withApiKey(mergeExercises)(req, res));
exports.backfillNormalizeFamily = functions.https.onRequest((req, res) => withApiKey(backfillNormalizeFamily)(req, res));
exports.backupExercises = functions.https.onRequest((req, res) => withApiKey(backupExercises)(req, res));
exports.duplicateCatalog = functions.https.onRequest((req, res) => withApiKey(duplicateCatalog)(req, res));
exports.repointAlias = functions.https.onRequest((req, res) => withApiKey(repointAlias)(req, res));
exports.repointShorthandAliases = functions.https.onRequest((req, res) => withApiKey(repointShorthandAliases)(req, res));
exports.upsertAlias = functions.https.onRequest((req, res) => withApiKey(upsertAlias)(req, res));
exports.deleteAlias = functions.https.onRequest((req, res) => withApiKey(deleteAlias)(req, res));
exports.suggestFamilyVariant = functions.https.onRequest((req, res) => withApiKey(suggestFamilyVariant)(req, res));
exports.suggestAliases = functions.https.onRequest((req, res) => withApiKey(suggestAliases)(req, res));
exports.refineExercise = functions.https.onRequest((req, res) => withApiKey(refineExercise)(req, res));
exports.searchAliases = functions.https.onRequest((req, res) => withApiKey(searchAliases)(req, res));
exports.normalizeCatalog = functions.https.onRequest((req, res) => withApiKey(normalizeCatalog)(req, res));
exports.listFamilies = functions.https.onRequest((req, res) => withApiKey(listFamilies)(req, res));
exports.normalizeCatalogPage = functions.https.onRequest((req, res) => withApiKey(normalizeCatalogPage)(req, res));

// Active Workout Operations (all v2 — already wrapped with onRequest + requireFlexibleAuth internally)
exports.proposeSession = proposeSession;
exports.startActiveWorkout = startActiveWorkout;
exports.getActiveWorkout = getActiveWorkout;
exports.logSet = logSet;
exports.patchActiveWorkout = patchActiveWorkout;
exports.autofillExercise = autofillExercise;
exports.addExercise = addExercise;
exports.swapExercise = swapExercise;
exports.completeActiveWorkout = completeActiveWorkout;
exports.cancelActiveWorkout = cancelActiveWorkout;
exports.completeCurrentSet = completeCurrentSet;

// StrengthOS Operations
exports.streamAgentNormalized = onRequestV2(
  { timeoutSeconds: 300, memory: '512MiB', maxInstances: 20, concurrency: 1 },
  requireFlexibleAuth(streamAgentNormalizedHandler)
);
exports.upsertProgressReport = functions.https.onRequest((req, res) => withApiKey(upsertProgressReport)(req, res));
exports.getProgressReports = functions.https.onRequest((req, res) => requireFlexibleAuth(getProgressReports)(req, res));

// Artifact Operations
exports.artifactAction = artifactAction;

// Recommendation Operations
exports.reviewRecommendation = reviewRecommendation;

// Canvas Operations
exports.applyAction = functions.https.onRequest((req, res) => requireFlexibleAuth(applyAction)(req, res));
exports.proposeCards = functions.https.onRequest((req, res) => withApiKey(proposeCards)(req, res));
exports.expireProposals = functions.https.onRequest((req, res) => withApiKey(expireProposals)(req, res));
exports.emitEvent = functions.https.onRequest((req, res) => withApiKey(emitEvent)(req, res));
exports.purgeCanvas = functions.https.onRequest((req, res) => requireFlexibleAuth(purgeCanvas)(req, res));
// No-op stubs removed in Phase 7 (openCanvas, bootstrapCanvas, initializeSession, preWarmSession).
// Conversation ID is now generated client-side; agent service creates docs on first message.
exports.runAnalyticsForUser = functions.https.onRequest((req, res) => requireFlexibleAuth(runAnalyticsForUser)(req, res));
exports.compactAnalyticsForUser = functions.https.onRequest((req, res) => requireFlexibleAuth(compactAnalyticsForUser)(req, res));
exports.publishWeeklyJob = functions.https.onRequest((req, res) => requireFlexibleAuth(publishWeeklyJob)(req, res));
exports.recalculateWeeklyForUser = functions.https.onRequest((req, res) => requireFlexibleAuth(recalculateWeeklyForUser)(req, res));
// Agents
exports.getPlanningContext = functions.https.onRequest((req, res) => requireFlexibleAuth(getPlanningContext)(req, res));
// applyProgression is a v2 onRequest function with built-in CORS
exports.applyProgression = applyProgression;

// Firestore Triggers (these don't need API key middleware)
exports.onTemplateCreated = onTemplateCreated;
exports.onTemplateUpdated = onTemplateUpdated;
exports.onWorkoutCreated = onWorkoutCreated;
exports.onWorkoutDeleted = onWorkoutDeleted;
exports.processWorkoutCompletionTask = processWorkoutCompletionTask;
exports.workoutCompletionWatchdog = workoutCompletionWatchdog;
exports.onAnalysisInsightCreated = onAnalysisInsightCreated;
exports.onWeeklyReviewCreated = onWeeklyReviewCreated;

// Scheduled Functions
exports.expireStaleRecommendations = expireStaleRecommendations;
exports.weeklyStatsRecalculation = weeklyStatsRecalculation;
exports.analyticsCompactionScheduled = analyticsCompactionScheduled;

// Callable Functions
exports.manualWeeklyStatsRecalculation = manualWeeklyStatsRecalculation;

// ============================================================================
// Token-safe Training Analytics v2
// See: docs/TRAINING_ANALYTICS_API_V2_SPEC.md
// ============================================================================

// Query endpoints (v2 onRequest with requireFlexibleAuth)
exports.querySets = querySets;
exports.aggregateSets = aggregateSets;

// Progress summary endpoints (agent-first)
exports.getMuscleGroupSummary = getMuscleGroupSummary;
exports.getMuscleSummary = getMuscleSummary;
exports.getExerciseSummary = getExerciseSummary;

// Active workout lite (replaces heavy full-state reads)
exports.getActiveSnapshotLite = getActiveSnapshotLite;

// Active workout events (paginated event stream)
exports.getActiveEvents = getActiveEvents;

// Training Analysis (pre-computed insights)
exports.getAnalysisSummary = getAnalysisSummary;

// ============================================================================
// Subscription Operations
// ============================================================================

// App Store webhook (v2 onRequest, NO auth middleware - Apple calls directly)
exports.appStoreWebhook = appStoreWebhook;

// Client subscription sync (v2 onRequest with requireFlexibleAuth - iOS app only)
exports.syncSubscriptionStatus = syncSubscriptionStatus;

// ============================================================================
// MCP API Key Management (v2 onRequest with requireFlexibleAuth - iOS app only)
// ============================================================================
exports.generateMcpApiKey = generateMcpApiKey;
exports.listMcpApiKeys = listMcpApiKeys;
exports.revokeMcpApiKey = revokeMcpApiKey;
exports.getMcpConnectionStatus = getMcpConnectionStatus;
exports.revokeMcpTokens = revokeMcpTokens;
