/**
 * Request and response helpers shared by every endpoint, including the error wrapper that plays
 * the role of Express error-handling middleware (Azure Functions has none).
 */
import type { HttpRequest, HttpResponseInit, InvocationContext } from '@azure/functions';
import type { z } from 'zod';
import { badRequest, HttpError, internalError, unprocessable } from './errors.ts';
import { createLogger } from './logger.ts';

export type HttpHandler = (request: HttpRequest, context: InvocationContext) => Promise<HttpResponseInit>;

export function ok(body: unknown): HttpResponseInit {
  return { status: 200, jsonBody: body };
}

const SQL_CONSTRAINT_VIOLATION = 547;

function sqlErrorNumber(error: unknown): number | undefined {
  const number = (error as { number?: unknown } | null)?.number;
  return typeof number === 'number' ? number : undefined;
}

/** The constraint named in a 547 message such as: ...conflicted with the CHECK constraint "CK_x". */
function constraintName(error: unknown): string | undefined {
  const message = (error as { message?: unknown } | null)?.message;
  if (sqlErrorNumber(error) !== SQL_CONSTRAINT_VIOLATION || typeof message !== 'string') return undefined;
  return /constraint "([^"]+)"/.exec(message)?.[1];
}

/**
 * Turns anything thrown into an HttpError. Validation in the Function catches bad input first;
 * the database CHECK constraints are a safety net, so their violations become 422 rather than 500.
 */
export function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  const constraint = constraintName(error);
  if (constraint === 'CK_Students_PaidAmount') {
    return unprocessable('Overpayment', 'paidAmount must be between 0 and totalFee.', [
      { field: 'paidAmount', issue: 'must be between 0 and totalFee' },
    ]);
  }
  if (constraint === 'CK_Students_TotalFee') {
    return unprocessable('InvalidFee', 'totalFee must be 0 or more.', [{ field: 'totalFee', issue: 'must be 0 or more' }]);
  }
  return internalError();
}

/** The single error format of every endpoint. Never includes stack traces or driver messages. */
export function errorResponse(error: HttpError, correlationId: string): HttpResponseInit {
  return {
    status: error.status,
    jsonBody: {
      error: error.code,
      message: error.message,
      ...(error.details && { details: error.details }),
      correlationId,
    },
    headers: error.retryAfterSeconds !== undefined ? { 'Retry-After': String(error.retryAfterSeconds) } : undefined,
  };
}

/** Wraps a handler so every failure becomes the standard JSON error response plus a log entry. */
export function withErrorHandling(handler: HttpHandler): HttpHandler {
  return async (request, context) => {
    try {
      return await handler(request, context);
    } catch (error) {
      const httpError = toHttpError(error);
      // Only the error's type, number and constraint are logged: driver messages can echo submitted values.
      const fields = {
        status: httpError.status,
        errorCode: httpError.code,
        errorName: error instanceof Error ? error.name : typeof error,
        sqlErrorNumber: sqlErrorNumber(error),
        constraint: constraintName(error),
      };
      const log = createLogger(context);
      if (httpError.status >= 500) log.error('request.failed', fields);
      else log.warn('request.rejected', fields);
      return errorResponse(httpError, context.invocationId);
    }
  };
}

const MAX_SQL_INT = 2_147_483_647;

/** A route id: only whole numbers that fit SQL INT. */
export function parseId(value: string | undefined, field = 'id'): number {
  const id = value !== undefined && /^\d{1,10}$/.test(value) ? Number(value) : NaN;
  if (!Number.isInteger(id) || id < 1 || id > MAX_SQL_INT) {
    throw badRequest(`${field} must be a positive whole number.`, [{ field, issue: 'must be a positive whole number' }]);
  }
  return id;
}

/** The request body as JSON. An empty or malformed body is a 400, not a 500. */
export async function readJsonBody(request: HttpRequest): Promise<unknown> {
  const text = await request.text();
  if (text.trim() === '') throw badRequest('A JSON request body is required.');
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw badRequest('The request body is not valid JSON.');
  }
}

/** Validates data with a zod schema; on failure throws a 400 listing every problem. */
export function parseWith<S extends z.ZodType>(schema: S, data: unknown, what = 'request'): z.output<S> {
  const result = schema.safeParse(data);
  if (result.success) return result.data;
  throw badRequest(
    `The ${what} is invalid.`,
    result.error.issues.map((issue) => ({
      field: issue.path.length > 0 ? issue.path.join('.') : what,
      issue: issue.message,
    })),
  );
}
