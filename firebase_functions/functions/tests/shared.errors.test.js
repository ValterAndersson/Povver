const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { ValidationError, NotFoundError, PermissionError, mapErrorToResponse } = require('../shared/errors');

describe('shared/errors', () => {
  test('ValidationError has correct code', () => {
    const err = new ValidationError('bad input');
    assert.equal(err.message, 'bad input');
    assert.equal(err.code, 'INVALID_ARGUMENT');
    assert.equal(err.httpStatus, 400);
  });

  test('NotFoundError has correct code', () => {
    const err = new NotFoundError('not found');
    assert.equal(err.code, 'NOT_FOUND');
    assert.equal(err.httpStatus, 404);
  });

  test('PermissionError has correct code', () => {
    const err = new PermissionError('forbidden');
    assert.equal(err.code, 'FORBIDDEN');
    assert.equal(err.httpStatus, 403);
  });

  test('mapErrorToResponse handles ValidationError', () => {
    const res = mockRes();
    const err = new ValidationError('routineId required');
    mapErrorToResponse(res, err);
    assert.equal(res._status, 400);
    assert.deepEqual(res._json, {
      success: false,
      error: { code: 'INVALID_ARGUMENT', message: 'routineId required', details: undefined }
    });
  });

  test('mapErrorToResponse handles unknown errors as INTERNAL', () => {
    const res = mockRes();
    mapErrorToResponse(res, new Error('kaboom'));
    assert.equal(res._status, 500);
    assert.equal(res._json.error.code, 'INTERNAL');
  });
});

function mockRes() {
  const r = { _status: null, _json: null };
  r.status = (s) => { r._status = s; return r; };
  r.json = (j) => { r._json = j; return r; };
  return r;
}
