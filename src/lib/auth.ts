/**
 * Checks the caller's Microsoft Entra ID token inside the Function.
 *
 * API Management already validates every token, but the Function checks it again (signature,
 * issuer, audience, expiry) so that a leaked function key alone can never be used with a
 * home-made token. Microsoft's guidance: the API itself should validate the tokens it accepts.
 */
import type { HttpRequest } from '@azure/functions';
import { createRemoteJWKSet, errors as joseErrors, jwtVerify } from 'jose';
import { readSettings } from './config.ts';
import { forbidden, HttpError, unauthorized } from './errors.ts';

export type Role = 'FeeAdmin' | 'Student' | 'Reminders.Read';

export interface Caller {
  /** The caller's object ID in this tenant (a person, or the Logic App's managed identity). */
  oid: string;
  roles: string[];
}

// Microsoft's signing keys, downloaded on first use and cached by jose.
let jwks: ReturnType<typeof createRemoteJWKSet> | undefined;

export async function authenticate(request: HttpRequest): Promise<Caller> {
  const match = /^Bearer\s+(\S+)$/i.exec(request.headers.get('authorization') ?? '');
  if (!match?.[1]) throw unauthorized('An Entra ID bearer token is required.');

  const { tenantId, apiClientId } = readSettings();
  jwks ??= createRemoteJWKSet(new URL(`https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`));
  try {
    const { payload } = await jwtVerify(match[1], jwks, {
      issuer: `https://login.microsoftonline.com/${tenantId}/v2.0`, // only this tenant
      audience: apiClientId, // only tokens issued for the Fee API
      algorithms: ['RS256'],
    });
    const oid = typeof payload.oid === 'string' ? payload.oid.toLowerCase() : '';
    if (!oid) throw unauthorized('The token has no object ID.');
    const roles = Array.isArray(payload.roles) ? payload.roles.filter((r): r is string => typeof r === 'string') : [];
    return { oid, roles };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    if (error instanceof joseErrors.JOSEError) throw unauthorized('The token is invalid or has expired.');
    throw error;
  }
}

/** 403 unless the token carries at least one of the roles. */
export function requireAnyRole(caller: Caller, ...roles: Role[]): void {
  if (!roles.some((role) => caller.roles.includes(role))) {
    throw forbidden(`This needs the ${roles.join(' or ')} role.`);
  }
}
