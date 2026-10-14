/**
 * One shared SQL connection pool per Functions instance, signed in with the app's managed identity,
 * plus retry while a paused serverless database wakes up (about 60-75 seconds).
 *
 * The retry is bounded by a time budget, not a count. Calls through API Management must answer
 * within its 30-second limit (Consumption tier), so they give up after about 15 seconds and return
 * 503 with Retry-After: the database keeps resuming in the background and the caller's retry
 * succeeds. /api/health is called directly on the Function (230-second limit), so it waits longer.
 */
import { DefaultAzureCredential } from '@azure/identity';
import sql from 'mssql';
import { readSettings } from './config.ts';
import { databaseUnavailable } from './errors.ts';
import type { Logger } from './logger.ts';

export const API_RETRY_BUDGET_MS = 15_000;
export const HEALTH_RETRY_BUDGET_MS = 120_000;
const RETRY_AFTER_SECONDS = 30;

// Error numbers raised while Azure SQL is resuming, failing over or briefly overloaded.
// https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues
const TRANSIENT_SQL_ERRORS = new Set([10928, 10929, 40197, 40501, 40613, 49918, 49919, 49920]);
const TRANSIENT_CODES = new Set(['ESOCKET', 'ETIMEOUT', 'ECONNRESET', 'ECONNCLOSED']);
// Login failures lose their error number in the driver (40613 arrives as ELOGIN), so they are
// recognised by the server's wording instead.
const TRANSIENT_LOGIN = /not currently available|currently busy|try again|retry|limit .* has been reached|cannot process request/i;

export function isTransientDatabaseError(error: unknown): boolean {
  const { name, code, number, message } = (error ?? {}) as { name?: unknown; code?: unknown; number?: unknown; message?: unknown };
  if (typeof code === 'string' && TRANSIENT_CODES.has(code)) return true;
  if (typeof number === 'number' && TRANSIENT_SQL_ERRORS.has(number)) return true;
  return name === 'ConnectionError' && code === 'ELOGIN' && typeof message === 'string' && TRANSIENT_LOGIN.test(message);
}

/** True when the request never reached the database, so retrying cannot apply a change twice. */
function isConnectionError(error: unknown): boolean {
  return (error as { name?: unknown } | null)?.name === 'ConnectionError';
}

let poolPromise: Promise<sql.ConnectionPool> | undefined;

function getPool(): Promise<sql.ConnectionPool> {
  if (!poolPromise) {
    const settings = readSettings();
    const pool = new sql.ConnectionPool({
      server: settings.sqlServer,
      database: settings.sqlDatabase,
      port: 1433,
      options: { encrypt: true },
      // The managed identity in Azure (or your `az login` on a laptop). No password exists.
      authentication: { type: 'token-credential', options: { credential: new DefaultAzureCredential() } },
      // Kept small so that scaling out cannot exhaust a 1-vCore database's connections.
      pool: { max: 10, min: 0, idleTimeoutMillis: 30_000 },
      connectionTimeout: 8_000,
      requestTimeout: 15_000,
    });
    pool.on('error', () => undefined); // a broken idle connection is simply discarded
    poolPromise = pool.connect().catch((error: unknown) => {
      poolPromise = undefined; // let the next call try to connect again
      throw error;
    });
  }
  return poolPromise;
}

export interface DatabaseCallOptions {
  /** True when running the work twice has the same effect as once (reads, or updates to fixed values). */
  idempotent: boolean;
  budgetMs?: number;
  log?: Logger;
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Runs database work with retry on transient errors; throws a 503 HttpError when the budget runs out. */
export async function withDatabase<T>(work: (pool: sql.ConnectionPool) => Promise<T>, options: DatabaseCallOptions): Promise<T> {
  const budgetMs = options.budgetMs ?? API_RETRY_BUDGET_MS;
  const started = Date.now();
  for (let attempt = 1; ; attempt++) {
    try {
      return await work(await getPool());
    } catch (error) {
      const retryable = isTransientDatabaseError(error) && (options.idempotent || isConnectionError(error));
      if (!retryable) throw error;
      const delayMs = Math.min(1_000 * 2 ** (attempt - 1), 8_000); // 1, 2, 4, 8, 8 ... seconds
      const elapsedMs = Date.now() - started;
      if (elapsedMs + delayMs > budgetMs) {
        options.log?.warn('db.unavailable', { attempt, elapsedMs });
        throw databaseUnavailable(RETRY_AFTER_SECONDS);
      }
      options.log?.warn('db.retry', { attempt, delayMs, elapsedMs });
      await sleep(delayMs);
    }
  }
}

export { sql };
