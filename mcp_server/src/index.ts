// src/index.ts
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createServer } from 'http';
import { authenticateApiKey } from './auth.js';
import { registerTools } from './tools.js';

const PORT = parseInt(process.env.PORT || '8080');

const httpServer = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  // Extract API key from Authorization header
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing API key' }));
    return;
  }

  const apiKey = authHeader.slice(7);

  try {
    const auth = await authenticateApiKey(apiKey);

    const server = new McpServer({ name: 'povver', version: '1.0.0' });
    registerTools(server, auth.userId);

    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    await server.connect(transport);
    await transport.handleRequest(req, res);
  } catch (e: any) {
    res.writeHead(e.message === 'Premium subscription required for MCP access' ? 403 : 401);
    res.end(JSON.stringify({ error: e.message }));
  }
});

httpServer.listen(PORT, () => {
  console.log(`MCP server listening on port ${PORT}`);
});
