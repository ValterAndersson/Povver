#!/usr/bin/env node
/**
 * Backfill exercise names on templates from the exercise catalog.
 * Idempotent — safe to re-run. Skips exercises that already have names.
 *
 * Usage: GOOGLE_APPLICATION_CREDENTIALS=$FIREBASE_SA_KEY node scripts/backfill_template_exercise_names.js [--dry-run]
 */
const admin = require('firebase-admin');
admin.initializeApp();
const db = admin.firestore();

const dryRun = process.argv.includes('--dry-run');

async function main() {
  console.log(`Backfill template exercise names${dryRun ? ' (DRY RUN)' : ''}`);

  const usersSnap = await db.collection('users').limit(10000).get();
  let usersProcessed = 0, templatesUpdated = 0, exercisesResolved = 0;

  // Pre-load exercise catalog into memory (< 2000 docs, ~1MB)
  const exerciseCatalog = new Map();
  const catSnap = await db.collection('exercises').limit(5000).get();
  catSnap.docs.forEach(d => exerciseCatalog.set(d.id, d.data().name || d.id));
  console.log(`Loaded ${exerciseCatalog.size} exercises from catalog`);

  for (const userDoc of usersSnap.docs) {
    const userId = userDoc.id;
    const templatesSnap = await db.collection('users').doc(userId)
      .collection('templates').limit(500).get();

    for (const tDoc of templatesSnap.docs) {
      const data = tDoc.data();
      const exercises = data.exercises || [];
      let needsUpdate = false;
      const updated = exercises.map(ex => {
        if (!ex.name && ex.exercise_id && exerciseCatalog.has(ex.exercise_id)) {
          needsUpdate = true;
          exercisesResolved++;
          return { ...ex, name: exerciseCatalog.get(ex.exercise_id) };
        }
        return ex;
      });

      if (needsUpdate) {
        if (!dryRun) {
          await tDoc.ref.update({ exercises: updated });
        }
        templatesUpdated++;
      }
    }
    usersProcessed++;
    if (usersProcessed % 100 === 0) console.log(`Processed ${usersProcessed} users...`);
  }

  console.log(`Done. Users: ${usersProcessed}, Templates updated: ${templatesUpdated}, Exercises resolved: ${exercisesResolved}`);
}

main().catch(e => { console.error(e); process.exit(1); });
