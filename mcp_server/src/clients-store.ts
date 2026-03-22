// mcp_server/src/clients-store.ts
import type { OAuthRegisteredClientsStore } from '@modelcontextprotocol/sdk/server/auth/clients.js';
import type { OAuthClientInformationFull } from '@modelcontextprotocol/sdk/shared/auth.js';

// In-memory store for dynamically registered clients (e.g., Claude Desktop).
// Claude Desktop registers with a dynamic localhost port on each connection,
// so we must support dynamic registration. Entries are per-instance and
// ephemeral — acceptable because token validation doesn't need the client record.
const registeredClients = new Map<string, OAuthClientInformationFull>();

// Allowed redirect URI patterns for security — only localhost and claude.ai callback
function isAllowedRedirectUri(uri: string): boolean {
  try {
    const url = new URL(uri);
    if (url.hostname === '127.0.0.1' || url.hostname === 'localhost') return true;
    if (url.hostname === 'claude.ai' && url.pathname.startsWith('/api/mcp/')) return true;
    return false;
  } catch {
    return false;
  }
}

export class PovverClientsStore implements OAuthRegisteredClientsStore {
  async getClient(clientId: string): Promise<OAuthClientInformationFull | undefined> {
    return registeredClients.get(clientId);
  }

  async registerClient(client: OAuthClientInformationFull): Promise<OAuthClientInformationFull> {
    // Validate all redirect URIs are allowed
    for (const uri of client.redirect_uris) {
      if (!isAllowedRedirectUri(uri)) {
        throw new Error(`Redirect URI not allowed: ${uri}`);
      }
    }

    registeredClients.set(client.client_id, client);
    return client;
  }
}
