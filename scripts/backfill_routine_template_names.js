#!/usr/bin/env node
/**
 * Backfill template_names on routines from template documents.
 * Idempotent — safe to re-run.
 *
 * Usage: GOOGLE_APPLICATION_CREDENTIALS=$FIREBASE_SA_KEY node scripts/backfill_routine_template_names.js [--dry-run]
 */
const admin = require('firebase-admin');
admin.initializeApp();
const db = admin.firestore();

const dryRun = process.argv.includes('--dry-run');

async function main() {
  console.log(`Backfill routine template_names${dryRun ? ' (DRY RUN)' : ''}`);

  const usersSnap = await db.collection('users').limit(10000).get();
  let usersProcessed = 0, routinesUpdated = 0;

  for (const userDoc of usersSnap.docs) {
    const userId = userDoc.id;
    const routinesSnap = await db.collection('users').doc(userId)
      .collection('routines').limit(100).get();

    for (const rDoc of routinesSnap.docs) {
      const data = rDoc.data();
      const templateIds = data.template_ids || data.templateIds || [];
      if (templateIds.length === 0) continue;

      // Batch-read all referenced templates
      const templateRefs = templateIds.map(tid =>
        db.collection('users').doc(userId).collection('templates').doc(tid)
      );
      const templateDocs = await db.getAll(...templateRefs);

      const templateNames = {};
      templateDocs.forEach((doc, i) => {
        templateNames[templateIds[i]] = doc.exists ? (doc.data().name || 'Untitled') : 'Deleted';
      });

      // Only update if template_names is missing or different
      const existing = data.template_names || {};
      const needsUpdate = JSON.stringify(existing) !== JSON.stringify(templateNames);

      if (needsUpdate) {
        if (!dryRun) {
          await rDoc.ref.update({ template_names: templateNames });
        }
        routinesUpdated++;
      }
    }
    usersProcessed++;
    if (usersProcessed % 100 === 0) console.log(`Processed ${usersProcessed} users...`);
  }

  console.log(`Done. Users: ${usersProcessed}, Routines updated: ${routinesUpdated}`);
}

main().catch(e => { console.error(e); process.exit(1); });
