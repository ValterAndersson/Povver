/**
 * stream-onboarding-routine.js — Dedicated SSE endpoint for onboarding routine generation.
 *
 * Isolated from streamAgentNormalized to avoid touching the main streaming path.
 * No premium gate — this is the one free AI call to convert the user.
 * Server-side prompt — client sends structured params, not raw text.
 * Atomic usedOnboardingBypass flag — exactly one call per user lifetime.
 */

const { GoogleAuth } = require('google-auth-library');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { v4: uuidv4 } = require('uuid');

const AGENT_SERVICE_URL = process.env.AGENT_SERVICE_URL;

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();

// ─── SSE Writer ──────────────────────────────────────────────────────────────

function createSSE(res) {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders?.();

  const write = (obj) => {
    try {
      res.write(`data: ${JSON.stringify(obj)}\n\n`);
    } catch (_) { /* client disconnected */ }
  };

  const close = () => {
    try { res.end(); } catch (_) {}
  };

  return { write, close };
}

// ─── Agent Service Call ──────────────────────────────────────────────────────

async function callAgentService(userId, conversationId, message, correlationId) {
  const auth = new GoogleAuth();
  const client = await auth.getIdTokenClient(AGENT_SERVICE_URL);
  const response = await client.request({
    url: `${AGENT_SERVICE_URL}/stream`,
    method: 'POST',
    data: {
      user_id: userId,
      conversation_id: conversationId,
      message,
      correlation_id: correlationId,
    },
    responseType: 'stream',
    timeout: 120000,
  });
  return response.data;
}

// ─── Prompt Builder ──────────────────────────────────────────────────────────

function buildOnboardingPrompt(fitnessLevel, frequency, equipment) {
  const splitAdvice = frequency <= 3
    ? 'full body'
    : frequency <= 4
      ? 'upper/lower'
      : 'push/pull/legs or upper/lower';

  return `New user onboarding. Create a training routine with these exact parameters:
- Experience level: ${fitnessLevel}
- Training frequency: ${frequency} days per week
- Equipment access: ${equipment}
- Goal: hypertrophy (muscle building)

Use propose_routine to build it. Pick an appropriate split for the frequency (${splitAdvice}). \
Choose exercises from the catalog appropriate for the equipment level. \
Set reps in the 8-12 range, RIR 2-3 for ${fitnessLevel} level. \
Do not ask any questions — generate the routine immediately.`;
}

// ─── Conversational User Message ─────────────────────────────────────────────

function buildUserFacingMessage(frequency, equipment) {
  const equipmentLabel = {
    full_gym: 'full gym equipment',
    home_gym: 'a home gym setup',
    bodyweight: 'minimal equipment',
  }[equipment] || equipment;

  return `Create a training routine for me — I train ${frequency} days a week with ${equipmentLabel}`;
}

// ─── SSE Relay ───────────────────────────────────────────────────────────────

function relayStream(stream, sse, conversationId, userId, frequency) {
  return new Promise((resolve, reject) => {
    let partial = '';
    let accumulatedAgentText = '';
    let routineName = null;
    const convRef = db.collection('users').doc(userId)
      .collection('conversations').doc(conversationId);

    stream.on('data', (chunk) => {
      partial += chunk.toString('utf8');
      const lines = partial.split('\n');
      partial = lines.pop();

      for (const rawLine of lines) {
        const trimmed = rawLine.trim();
        if (!trimmed || trimmed.startsWith('event:') || !trimmed.startsWith('data:')) continue;

        const jsonStr = trimmed.slice(5).trim();
        if (!jsonStr) continue;

        try {
          const evt = JSON.parse(jsonStr);
          const eventType = evt.type || 'unknown';

          if (eventType === 'message' && evt.text) {
            accumulatedAgentText += evt.text;
            sse.write({ type: 'text_delta', text: evt.text });
          } else if (eventType === 'tool_start') {
            sse.write({ type: 'tool_started', name: evt.tool || 'tool', args: evt.args || {} });
          } else if (eventType === 'tool_end') {
            sse.write({ type: 'tool_result', name: evt.tool || 'tool', summary: evt.result || '' });
          } else if (eventType === 'artifact') {
            if (evt.artifact_type === 'routine_summary' && evt.artifact_content?.name) {
              routineName = evt.artifact_content.name;
            }
            // Wrap in content dict to match streamAgentNormalized format
            sse.write({
              type: 'artifact',
              content: {
                artifact_type: evt.artifact_type,
                artifact_id: evt.artifact_id,
                artifact_content: evt.artifact_content,
              },
            });
          } else if (eventType === 'status') {
            sse.write({ type: 'status', content: evt });
          } else if (eventType === 'heartbeat') {
            sse.write({ type: 'heartbeat' });
          } else if (eventType === 'error') {
            sse.write({ type: 'error', error: evt });
          }
        } catch (_) { /* skip unparseable lines */ }
      }
    });

    stream.on('end', async () => {
      // Persist agent response
      if (accumulatedAgentText) {
        await convRef.collection('messages').add({
          type: 'agent_response',
          content: accumulatedAgentText,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        }).catch(err => logger.warn('agent response persist failed', { error: String(err?.message || err) }));
      }

      // Update conversation metadata with routine name
      if (routineName) {
        await convRef.set({
          title: routineName,
          lastMessage: `Created your ${routineName} — ${frequency} days per week`,
          status: 'active',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true }).catch(err =>
          logger.warn('conversation metadata update failed', { error: String(err?.message || err) })
        );
      }

      resolve({ routineName });
    });

    stream.on('error', (err) => reject(err));
  });
}

// ─── Main Handler ────────────────────────────────────────────────────────────

async function streamOnboardingRoutineHandler(req, res) {
  const sse = createSSE(res);
  let clientDisconnected = false;

  const hb = setInterval(() => {
    if (!clientDisconnected) sse.write({ type: 'heartbeat' });
  }, 2500);

  req.on('close', () => {
    clientDisconnected = true;
    clearInterval(hb);
  });

  const done = (err) => {
    clearInterval(hb);
    if (!clientDisconnected) {
      if (err) sse.write({ type: 'error', error: { code: 'GENERATION_FAILED', message: 'An error occurred' } });
      sse.write({ type: 'done' });
    }
    sse.close();
  };

  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      sse.write({ type: 'error', error: { code: 'UNAUTHORIZED', message: 'Authentication required' } });
      done();
      return;
    }

    const { fitnessLevel, frequency, equipment, conversationId } = req.body || {};
    if (!fitnessLevel || !frequency || !equipment || !conversationId) {
      sse.write({ type: 'error', error: { code: 'INVALID_PARAMS', message: 'fitnessLevel, frequency, equipment, and conversationId are required' } });
      done();
      return;
    }
    // Validate conversationId format — used as Firestore doc ID
    if (typeof conversationId !== 'string' || conversationId.length > 128 || !/^[a-zA-Z0-9_-]+$/.test(conversationId)) {
      sse.write({ type: 'error', error: { code: 'INVALID_PARAMS', message: 'Invalid conversationId format' } });
      done();
      return;
    }

    const validLevels = ['beginner', 'intermediate', 'advanced'];
    const validEquipment = ['full_gym', 'home_gym', 'bodyweight'];
    if (!validLevels.includes(fitnessLevel) || !validEquipment.includes(equipment)) {
      sse.write({ type: 'error', error: { code: 'INVALID_PARAMS', message: 'Invalid fitnessLevel or equipment value' } });
      done();
      return;
    }
    const freq = parseInt(frequency, 10);
    if (isNaN(freq) || freq < 2 || freq > 6) {
      sse.write({ type: 'error', error: { code: 'INVALID_PARAMS', message: 'frequency must be 2-6' } });
      done();
      return;
    }

    // Atomic one-time-use gate
    const userRef = db.doc(`users/${userId}`);
    const allowed = await db.runTransaction(async (tx) => {
      const userDoc = await tx.get(userRef);
      if (userDoc.data()?.usedOnboardingBypass) return false;
      tx.update(userRef, { usedOnboardingBypass: true });
      return true;
    });

    if (!allowed) {
      sse.write({ type: 'error', error: { code: 'ALREADY_USED', message: 'Onboarding routine already generated' } });
      done();
      return;
    }

    logger.info('[streamOnboardingRoutine] starting', { userId, fitnessLevel, frequency: freq, equipment });

    const convRef = db.collection('users').doc(userId)
      .collection('conversations').doc(conversationId);

    const userMessage = buildUserFacingMessage(freq, equipment);
    await convRef.set({
      status: 'active',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    await convRef.collection('messages').add({
      type: 'user_prompt',
      content: { text: userMessage },
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    const prompt = buildOnboardingPrompt(fitnessLevel, freq, equipment);
    const correlationId = uuidv4();
    const agentStream = await callAgentService(userId, conversationId, prompt, correlationId);

    await relayStream(agentStream, sse, conversationId, userId, freq);

    logger.info('[streamOnboardingRoutine] complete', { userId });
    done();
  } catch (err) {
    logger.error('[streamOnboardingRoutine] error', { error: err.message });
    done(err);
  }
}

module.exports = { streamOnboardingRoutineHandler };
