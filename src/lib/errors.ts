/**
 * Errors that carry an HTTP status. Handlers throw these; withErrorHandling (http.ts) turns any
 * thrown value into one of them and then into the standard JSON error body.
 */

export interface ErrorDetail {
  field: string;
  issue: string;
}

export class HttpError extends Error {
  override name = 'HttpError';
  readonly status: number;
  readonly code: string;
  readonly details: ErrorDetail[] | undefined;
  readonly retryAfterSeconds: number | undefined;

  constructor(status: number, code: string, message: string, options: { details?: ErrorDetail[]; retryAfterSeconds?: number } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = options.details;
    this.retryAfterSeconds = options.retryAfterSeconds;
  }
}

/** 400: the request is malformed (wrong types, unknown fields, invalid id). */
export const badRequest = (message: string, details?: ErrorDetail[]) =>
  new HttpError(400, 'ValidationError', message, { details });

/** 401: no valid Entra ID token. */
export const unauthorized = (message: string) => new HttpError(401, 'Unauthorized', message);

/** 403: a valid token, but its roles do not allow this. */
export const forbidden = (message: string) => new HttpError(403, 'Forbidden', message);

/** 404: the record does not exist (only ever told to administrators). */
export const notFound = (message: string) => new HttpError(404, 'NotFound', message);

/** 422: well-formed, but breaks a business rule (for example an overpayment). */
export const unprocessable = (code: string, message: string, details?: ErrorDetail[]) =>
  new HttpError(422, code, message, { details });

/** 503: the database is waking up from auto-pause. Callers should retry after the given seconds. */
export const databaseUnavailable = (retryAfterSeconds: number) =>
  new HttpError(503, 'DatabaseUnavailable', 'The database is starting up. Please retry shortly.', { retryAfterSeconds });

/** 500: anything unexpected. The message is deliberately generic; details go to the logs only. */
export const internalError = () => new HttpError(500, 'InternalError', 'An unexpected error occurred.');
