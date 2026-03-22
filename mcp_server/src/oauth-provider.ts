// mcp_server/src/oauth-provider.ts
import type { Response } from 'express';
import type { OAuthServerProvider, AuthorizationParams } from '@modelcontextprotocol/sdk/server/auth/provider.js';
import type { OAuthRegisteredClientsStore } from '@modelcontextprotocol/sdk/server/auth/clients.js';
import type { OAuthClientInformationFull, OAuthTokens } from '@modelcontextprotocol/sdk/shared/auth.js';
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js';
import admin from 'firebase-admin';
import { PovverClientsStore } from './clients-store.js';
import {
  generateNonce, generateCode, storeNonce, consumeNonce,
  storeAuthCode, getCodeChallenge, exchangeCode,
  rotateRefreshToken, verifyAccessToken as verifyToken,
  revokeAllForUser,
} from './tokens.js';
import { renderConsentPage } from './consent.js';
import { authenticateApiKey } from './auth.js';

export class PovverOAuthProvider implements OAuthServerProvider {
  get clientsStore(): OAuthRegisteredClientsStore {
    return new PovverClientsStore();
  }

  /**
   * Called by SDK on GET /authorize.
   * Generates nonce, stores in Firestore, serves consent page.
   */
  async authorize(
    client: OAuthClientInformationFull,
    params: AuthorizationParams,
    res: Response,
  ): Promise<void> {
    const nonce = generateNonce();

    await storeNonce(nonce, {
      client_id: client.client_id,
      redirect_uri: params.redirectUri,
      state: params.state,
      code_challenge: params.codeChallenge,
      code_challenge_method: 'S256',
    });

    res.setHeader('Content-Type', 'text/html');
    res.end(renderConsentPage(nonce));
  }

  /**
   * Called by SDK to get PKCE challenge for a code.
   */
  async challengeForAuthorizationCode(
    _client: OAuthClientInformationFull,
    authorizationCode: string,
  ): Promise<string> {
    return getCodeChallenge(authorizationCode);
  }

  /**
   * Called by SDK on POST /token with grant_type=authorization_code.
   * SDK already validated PKCE.
   */
  async exchangeAuthorizationCode(
    _client: OAuthClientInformationFull,
    authorizationCode: string,
    _codeVerifier?: string,
    redirectUri?: string,
    _resource?: URL,
  ): Promise<OAuthTokens> {
    const result = await exchangeCode(authorizationCode, redirectUri || '');
    return {
      access_token: result.accessToken,
      token_type: 'bearer',
      expires_in: result.expiresIn,
      refresh_token: result.refreshToken,
    };
  }

  /**
   * Called by SDK on POST /token with grant_type=refresh_token.
   */
  async exchangeRefreshToken(
    _client: OAuthClientInformationFull,
    refreshToken: string,
    _scopes?: string[],
    _resource?: URL,
  ): Promise<OAuthTokens> {
    const result = await rotateRefreshToken(refreshToken);
    return {
      access_token: result.accessToken,
      token_type: 'bearer',
      expires_in: result.expiresIn,
      refresh_token: result.refreshToken,
    };
  }

  /**
   * Called by SDK on every MCP request via Bearer auth middleware.
   * Routes by token prefix: pvt_ -> OAuth, pvk_/none -> API key.
   */
  async verifyAccessToken(token: string): Promise<AuthInfo> {
    // OAuth token path
    if (token.startsWith('pvt_')) {
      const { userId, expiresAt } = await verifyToken(token);

      // Premium check
      const userDoc = await admin.firestore().doc(`users/${userId}`).get();
      if (!userDoc.exists) throw new Error('User not found');
      const userData = userDoc.data()!;
      const isPremium = userData.subscription_override === 'premium'
                     || userData.subscription_tier === 'premium';
      if (!isPremium) throw new Error('Premium subscription required for MCP access');

      return {
        token,
        clientId: 'claude-desktop',
        scopes: [],
        expiresAt,
        extra: { userId },
      };
    }

    // API key path (pvk_ prefix or no prefix = legacy)
    const auth = await authenticateApiKey(token);
    return {
      token,
      clientId: 'api-key',
      scopes: [],
      extra: { userId: auth.userId },
    };
  }

  /**
   * Called on POST /authorize/complete (custom endpoint, not SDK-routed).
   * Validates nonce + Firebase ID token, generates auth code, returns redirect URL.
   */
  async completeAuthorization(
    idToken: string,
    nonce: string,
  ): Promise<{ redirectUrl: string }> {
    // Validate nonce
    const nonceData = await consumeNonce(nonce);
    if (!nonceData) throw new Error('Invalid or expired nonce');

    // Validate Firebase ID token
    const decoded = await admin.auth().verifyIdToken(idToken);
    const userId = decoded.uid;

    // Revoke existing tokens (prevent accumulation)
    await revokeAllForUser(userId);

    // Generate auth code
    const code = generateCode();
    await storeAuthCode(code, userId, nonceData.code_challenge, nonceData.redirect_uri);

    // Build redirect URL
    const redirectUrl = new URL(nonceData.redirect_uri);
    redirectUrl.searchParams.set('code', code);
    if (nonceData.state) redirectUrl.searchParams.set('state', nonceData.state);

    return { redirectUrl: redirectUrl.toString() };
  }
}
