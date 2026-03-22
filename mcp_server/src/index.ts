// src/index.ts
import express from 'express';
import rateLimit from 'express-rate-limit';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { mcpAuthRouter } from '@modelcontextprotocol/sdk/server/auth/router.js';
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js';
import { PovverOAuthProvider } from './oauth-provider.js';
import { consumeNonce } from './tokens.js';
import { registerTools } from './tools.js';

const PORT = parseInt(process.env.PORT || '8080');
const ISSUER_URL = new URL(process.env.MCP_ISSUER_URL || 'https://mcp.povver.ai');

const provider = new PovverOAuthProvider();

const app = express();
app.set('trust proxy', true);

// Security headers
app.use((_req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  next();
});

// Health check (unauthenticated)
app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

// Mount SDK OAuth router (handles /.well-known/*, /authorize, /token, /register)
app.use(mcpAuthRouter({
  provider,
  issuerUrl: ISSUER_URL,
}));

// Rate limiter for custom OAuth endpoints (10 requests per minute per IP)
const oauthEndpointLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'rate_limited', error_description: 'Too many requests' },
});

// Custom endpoint: consent page completion
app.post('/authorize/complete', oauthEndpointLimiter, express.json(), async (req, res) => {
  try {
    const { id_token, nonce } = req.body;
    if (!id_token || typeof id_token !== 'string' || id_token.length > 4096 || !nonce || typeof nonce !== 'string' || nonce.length > 64) {
      res.status(400).json({ error: 'invalid_request', error_description: 'Missing or invalid id_token or nonce' });
      return;
    }
    const result = await provider.completeAuthorization(id_token, nonce);
    res.json({ redirect_url: result.redirectUrl });
  } catch (e: any) {
    res.status(400).json({ error: 'access_denied', error_description: e.message });
  }
});

// Custom endpoint: consent page denial (redirects with error)
app.post('/authorize/deny', oauthEndpointLimiter, express.json(), async (req, res) => {
  try {
    const { nonce } = req.body;
    if (!nonce || typeof nonce !== 'string' || nonce.length > 64) {
      res.status(400).json({ error: 'invalid_request' });
      return;
    }
    const nonceData = await consumeNonce(nonce);
    if (!nonceData) {
      res.status(400).json({ error: 'invalid_request', error_description: 'Invalid or expired nonce' });
      return;
    }
    const redirectUrl = new URL(nonceData.redirect_uri);
    redirectUrl.searchParams.set('error', 'access_denied');
    if (nonceData.state) redirectUrl.searchParams.set('state', nonceData.state);
    res.json({ redirect_url: redirectUrl.toString() });
  } catch (e: any) {
    res.status(400).json({ error: 'server_error', error_description: e.message });
  }
});

// MCP endpoint (Bearer auth required)
const bearerAuth = requireBearerAuth({ verifier: provider });

app.all('/', bearerAuth, express.json(), async (req, res) => {
  const userId = req.auth?.extra?.userId as string | undefined;

  if (!userId) {
    res.status(401).json({ error: 'Authentication failed' });
    return;
  }

  const server = new McpServer({ name: 'povver', version: '1.0.0' });
  registerTools(server, userId);

  const transport = new StreamableHTTPServerTransport();
  await server.connect(transport);
  try {
    await transport.handleRequest(req, res, req.body);
  } finally {
    await transport.close();
    await server.close();
  }
});

app.listen(PORT, () => {
  console.log(`MCP server listening on port ${PORT}`);
});
