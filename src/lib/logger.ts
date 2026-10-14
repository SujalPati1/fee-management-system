/**
 * Structured logging that cannot leak personal data.
 *
 * Only the keys in SafeLogFields can be logged. Names, emails, fee amounts, tokens and keys have
 * no field here, so the compiler rejects any attempt to log them.
 */
import type { InvocationContext } from '@azure/functions';

export interface SafeLogFields {
  studentId?: number;
  status?: number;
  errorCode?: string;
  errorName?: string;
  sqlErrorNumber?: number;
  constraint?: string;
  attempt?: number;
  delayMs?: number;
  elapsedMs?: number;
  count?: number;
}

export interface Logger {
  info(event: string, fields?: SafeLogFields): void;
  warn(event: string, fields?: SafeLogFields): void;
  error(event: string, fields?: SafeLogFields): void;
}

function format(event: string, fields: SafeLogFields = {}): string {
  const pairs = Object.entries(fields)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${value}`);
  return [event, ...pairs].join(' ');
}

/** Logs through the invocation context, so each entry is tied to its request in Application Insights. */
export function createLogger(context: InvocationContext): Logger {
  return {
    info: (event, fields) => context.log(format(event, fields)),
    warn: (event, fields) => context.warn(format(event, fields)),
    error: (event, fields) => context.error(format(event, fields)),
  };
}
