const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

describe('getAuthenticatedUserId', () => {
  test('Bearer lane: returns uid from decoded token', () => {
    const req = {
      auth: { uid: 'token-user-123' },
      body: { userId: 'attacker-user-456' },
      query: { userId: 'attacker-user-789' },
    };
    assert.equal(getAuthenticatedUserId(req), 'token-user-123');
  });

  test('Bearer lane via req.user: returns uid from decoded token', () => {
    const req = {
      user: { uid: 'token-user-123' },
      body: { userId: 'attacker-user-456' },
    };
    assert.equal(getAuthenticatedUserId(req), 'token-user-123');
  });

  test('API key lane: returns userId from body', () => {
    const req = {
      auth: { type: 'api_key', uid: undefined },
      body: { userId: 'agent-target-user' },
      query: {},
    };
    assert.equal(getAuthenticatedUserId(req), 'agent-target-user');
  });

  test('API key lane: returns uid from X-User-Id header (via auth.uid)', () => {
    const req = {
      auth: { type: 'api_key', uid: 'header-user-123' },
      body: {},
      query: {},
    };
    assert.equal(getAuthenticatedUserId(req), 'header-user-123');
  });

  test('API key lane: ignores userId from query params (security: prevents log leakage)', () => {
    const req = {
      auth: { type: 'api_key', uid: undefined },
      body: {},
      query: { userId: 'query-user-123' },
    };
    assert.equal(getAuthenticatedUserId(req), null);
  });

  test('No auth: returns null', () => {
    const req = { body: { userId: 'attacker' }, query: {} };
    assert.equal(getAuthenticatedUserId(req), null);
  });

  test('Bearer lane: ignores query userId', () => {
    const req = {
      auth: { uid: 'real-user' },
      query: { userId: 'fake-user' },
      body: {},
    };
    assert.equal(getAuthenticatedUserId(req), 'real-user');
  });

  test('API key lane: empty string userId returns null', () => {
    const req = {
      auth: { type: 'api_key', uid: undefined },
      body: { userId: '' },
      query: {},
    };
    assert.equal(getAuthenticatedUserId(req), null);
  });

  test('API key lane: whitespace-only userId returns null', () => {
    const req = {
      auth: { type: 'api_key', uid: undefined },
      body: { userId: '   ' },
      query: {},
    };
    assert.equal(getAuthenticatedUserId(req), null);
  });
});
