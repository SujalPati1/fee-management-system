/**
 * GET /api/health  (anonymous)
 *
 * Returns no data, only whether the database answers. It is called directly on the Function, not
 * through API Management, so it can wait out a full database wake-up (about 60-75 seconds; the
 * Function's own limit is 230 seconds). Call it a minute before a demo.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from '@azure/functions';
import { HEALTH_RETRY_BUDGET_MS, withDatabase } from '../lib/db.ts';
import { HttpError } from '../lib/errors.ts';
import { ok, withErrorHandling } from '../lib/http.ts';
import { createLogger } from '../lib/logger.ts';

export async function healthHandler(_request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const log = createLogger(context);
  const started = Date.now();
  try {
    await withDatabase((pool) => pool.request().query('SELECT 1 AS ok'), { idempotent: true, budgetMs: HEALTH_RETRY_BUDGET_MS, log });
    return ok({ status: 'ok', database: 'ok', elapsedMs: Date.now() - started });
  } catch (error) {
    if (!(error instanceof HttpError) || error.status !== 503) throw error;
    return {
      status: 503,
      jsonBody: { status: 'degraded', database: 'unavailable', correlationId: context.invocationId },
      headers: { 'Retry-After': String(error.retryAfterSeconds) },
    };
  }
}

app.http('health', {
  methods: ['GET'],
  authLevel: 'anonymous',
  route: 'health',
  handler: withErrorHandling(healthHandler),
});
