// mcp_server/src/clients-store.ts
import type { OAuthRegisteredClientsStore } from '@modelcontextprotocol/sdk/server/auth/clients.js';
import type { OAuthClientInformationFull } from '@modelcontextprotocol/sdk/shared/auth.js';

// Claude Desktop's redirect URI — determine exact scheme from Claude Desktop docs.
// Placeholder until confirmed. Common patterns: http://localhost:PORT/callback or custom scheme.
const REGISTERED_CLIENTS: Record<string, OAuthClientInformationFull> = {
  'claude-desktop': {
    client_id: 'claude-desktop',
    redirect_uris: ['http://localhost:0/callback'], // TODO: confirm from Claude Desktop docs
    token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
  },
};

export class PovverClientsStore implements OAuthRegisteredClientsStore {
  async getClient(clientId: string): Promise<OAuthClientInformationFull | undefined> {
    return REGISTERED_CLIENTS[clientId];
  }

  // No registerClient — dynamic registration not supported
}
