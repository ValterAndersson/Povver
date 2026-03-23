/**
 * =============================================================================
 * middleware.js - Authentication Middleware
 * =============================================================================
 *
 * PURPOSE:
 * Provides three auth middleware wrappers used by all Firebase Function endpoints.
 * Every endpoint in index.js is wrapped with one of these.
 *
 * AUTH LANES:
 *
 *   withApiKey(handler)
 *     - Service-to-service calls (agent system, scripts)
 *     - Validates X-API-Key header against VALID_API_KEYS env var
 *     - userId from req.body/query (trusted — caller is authenticated service)
 *     - Sets req.auth = { type: 'api_key', uid: userId }
 *
 *   requireFlexibleAuth(handler)
 *     - Endpoints called by BOTH iOS app and agent system
 *     - Tries Bearer token first, falls back to API key
 *     - SECURITY: When Bearer is used, userId comes from req.auth.uid (verified token)
 *       NOT from request params. This prevents cross-user data access.
 *     - Sets req.auth = decoded token (Bearer) or API key info (API key)
 *
 *   requireAuth(handler)
 *     - iOS-only endpoints (strict Firebase Auth)
 *     - userId ALWAYS from verified Firebase ID token
 *     - Sets req.user = decoded token
 *
 * SECURITY INVARIANT:
 * Bearer-lane endpoints NEVER trust client-provided userId in request body/query.
 * If they did, any authenticated user could access another user's data by passing
 * a different userId. The middleware enforces: Bearer → uid from token ONLY.
 *
 * CROSS-REFERENCES:
 * - All endpoint wrappers: index.js
 * - Auth patterns: docs/SYSTEM_ARCHITECTURE.md (Authentication Lanes)
 * - ARCHITECTURE.md in this directory for full details
 *
 * =============================================================================
 */

const admin = require('firebase-admin');
const { getAuth } = require('firebase-admin/auth');
const { logger } = require('firebase-functions');

// CORS: No browser clients exist (iOS native + server-to-server only).
// Restrict to localhost for local dev; deny all others.
const ALLOWED_ORIGINS = new Set([
  'http://localhost:3000',
  'http://localhost:5173',
  'http://127.0.0.1:3000',
  'http://127.0.0.1:5173',
]);

function setCorsHeaders(req, res) {
  const origin = req.get('Origin');
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    res.set('Access-Control-Allow-Origin', origin);
    res.set('Vary', 'Origin');
  }
  // No wildcard — unauthenticated browser requests from unknown origins are blocked
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-API-Key, X-User-Id');
}

// Security headers — defense-in-depth
function setSecurityHeaders(res) {
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('X-Frame-Options', 'DENY');
  res.set('Referrer-Policy', 'strict-origin-when-cross-origin');
}

/**
 * Middleware to verify Firebase ID token
 * @param {Object} req - Request object
 * @param {Object} res - Response object
 * @returns {Object|null} - Decoded token or null if authentication fails
 */
async function verifyAuth(req, res) {
  const authHeader = req.get('Authorization') || req.get('authorization');
  const idToken = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : null;

  if (!idToken) {
    res.status(401).json({ 
      success: false, 
      error: 'Missing or invalid Authorization header. Please provide Bearer token.' 
    });
    return null;
  }

  try {
    const decoded = await getAuth().verifyIdToken(idToken);
    return decoded;
  } catch (error) {
    logger.warn('[auth] token_verification_failed', {
      error_code: error.code || 'unknown',
      error_message: error.message,
      ip: req.ip,
      path: req.path,
      user_agent: req.get('user-agent'),
    });
    res.status(403).json({
      success: false,
      error: 'Invalid or expired token'
    });
    return null;
  }
}

/**
 * Middleware to verify API key for 3rd party access (AI agents)
 * @param {Object} req - Request object
 * @param {Object} res - Response object
 * @returns {Object|null} - API key info or null if authentication fails
 */
async function verifyApiKey(req, res) {
  const apiKey = req.get('X-API-Key');

  if (!apiKey) {
    res.status(401).json({
      success: false,
      error: 'Missing API key. Please provide X-API-Key header.'
    });
    return null;
  }

  try {
    const apiKeysString = process.env.VALID_API_KEYS || process.env.MYON_API_KEY;
    if (!apiKeysString) {
      logger.error('[middleware] FATAL: No API keys configured. Set VALID_API_KEYS env var.');
      res.status(500).json({ success: false, error: 'Server configuration error' });
      return null;
    }
    const validApiKeys = apiKeysString.split(',').map(key => key.trim()).filter(Boolean);

    if (validApiKeys.length === 0) {
      logger.error('[middleware] FATAL: VALID_API_KEYS is set but contains no valid keys');
      res.status(500).json({ success: false, error: 'Server configuration error' });
      return null;
    }
    if (!validApiKeys.includes(apiKey)) {
      logger.warn('[auth] invalid_api_key', {
        key_prefix: apiKey.substring(0, 4) + '***',
        ip: req.ip,
        path: req.path,
        user_agent: req.get('user-agent'),
      });
      res.status(403).json({ success: false, error: 'Invalid API key' });
      return null;
    }
    const uidHeader = req.get('X-User-Id');
    return { type: 'api_key', key: apiKey, uid: uidHeader || undefined, source: 'third_party_agent' };
  } catch (error) {
    logger.error('[auth] api_key_verification_error', {
      error_message: error.message,
      ip: req.ip,
      path: req.path,
    });
    res.status(500).json({ success: false, error: 'API key verification failed' });
    return null;
  }
}

/**
 * Flexible auth middleware that supports both Firebase Auth and API keys
 * @param {Object} req - Request object
 * @param {Object} res - Response object
 * @returns {Object|null} - Auth info or null if authentication fails
 */
async function verifyFlexibleAuth(req, res) {
  // Try Firebase Auth first
  const authHeader = req.get('Authorization') || req.get('authorization');
  if (authHeader?.startsWith('Bearer ')) {
    return await verifyAuth(req, res);
  }
  
  // Try API key authentication
  const apiKey = req.get('X-API-Key');
  if (apiKey) {
    return await verifyApiKey(req, res);
  }
  
  res.status(401).json({ 
    success: false, 
    error: 'Authentication required. Provide either Bearer token or X-API-Key header.' 
  });
  return null;
}

/**
 * Middleware wrapper for functions that require authentication
 * @param {Function} handler - The function handler to wrap
 * @returns {Function} - Wrapped function with auth verification
 */
function requireAuth(handler) {
  return async (req, res) => {
    const decoded = await verifyAuth(req, res);
    if (!decoded) {
      return; // Response already sent by verifyAuth
    }
    
    // Add the decoded token to request for use in handler
    req.user = decoded;
    return handler(req, res);
  };
}

/**
 * Middleware wrapper for functions that support flexible authentication
 * @param {Function} handler - The function handler to wrap
 * @returns {Function} - Wrapped function with flexible auth verification
 */
function requireFlexibleAuth(handler) {
  return async (req, res) => {
    setCorsHeaders(req, res);
    setSecurityHeaders(res);

    // Handle preflight requests
    if (req.method === 'OPTIONS') {
      return res.status(204).send();
    }
    
    const authInfo = await verifyFlexibleAuth(req, res);
    if (!authInfo) {
      return; // Response already sent by verifyFlexibleAuth
    }
    
    // Add auth info to request for use in handler
    req.auth = authInfo;
    return handler(req, res);
  };
}

const withApiKey = (handler) => {
  return async (req, res) => {
    setCorsHeaders(req, res);
    setSecurityHeaders(res);

    if (req.method === 'OPTIONS') {
      return res.status(204).send('');
    }

    const authInfo = await verifyApiKey(req, res);
    if (!authInfo) return; // response already sent
    req.auth = authInfo;
    return handler(req, res);
  };
};

module.exports = {
  verifyAuth,
  verifyApiKey,
  verifyFlexibleAuth,
  requireAuth,
  requireFlexibleAuth,
  withApiKey
}; 