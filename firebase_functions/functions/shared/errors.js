'use strict';

class AppError extends Error {
  constructor(message, code, httpStatus) {
    super(message);
    this.name = this.constructor.name;
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

class ValidationError extends AppError {
  constructor(message, details) {
    super(message, 'INVALID_ARGUMENT', 400);
    this.details = details;
  }
}

class NotFoundError extends AppError {
  constructor(message) {
    super(message, 'NOT_FOUND', 404);
  }
}

class PermissionError extends AppError {
  constructor(message) {
    super(message, 'FORBIDDEN', 403);
  }
}

function mapErrorToResponse(res, err) {
  if (err instanceof AppError) {
    return res.status(err.httpStatus).json({
      success: false,
      error: { code: err.code, message: err.message, details: err.details }
    });
  }
  console.error('Unhandled error:', err);
  return res.status(500).json({
    success: false,
    error: { code: 'INTERNAL', message: 'Internal server error', details: undefined }
  });
}

module.exports = { AppError, ValidationError, NotFoundError, PermissionError, mapErrorToResponse };
