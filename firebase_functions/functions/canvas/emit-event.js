'use strict';

const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { logger } = require('firebase-functions');

async function emitEvent(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    // Service-only: API key required
    const auth = req.auth;
    if (!auth || auth.type !== 'api_key') {
      return fail(res, 'UNAUTHORIZED', 'Service-only endpoint', null, 401);
    }

    const uidHeader = req.get('X-User-Id');
    const body = typeof req.body === 'object' && req.body !== null ? req.body : {};
    const userId = body.userId || uidHeader;
    const canvasId = body.canvasId;
    const type = body.type;
    const payload = (body.payload && typeof body.payload === 'object') ? body.payload : {};
    const correlationId = req.get('X-Correlation-Id') || body.correlationId || null;
    if (!userId || !canvasId || !type) {
      return fail(res, 'INVALID_ARGUMENT', 'userId, canvasId, type are required', null, 400);
    }

    const { FieldValue } = require('firebase-admin/firestore');
    const now = FieldValue.serverTimestamp();
    const ref = admin.firestore().collection(`users/${userId}/canvases/${canvasId}/events`).doc();
    await ref.set({ type, payload: { ...payload, correlation_id: correlationId || payload.correlation_id || null }, created_at: now });

    return ok(res, { id: ref.id });
  } catch (e) {
    logger.error('[emitEvent] Failed', { error: e?.message });
    return fail(res, 'INTERNAL', 'Failed to emit event', null, 500);
  }
}

module.exports = { emitEvent };


