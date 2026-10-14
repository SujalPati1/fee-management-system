/**
 * App settings, read once from environment variables (set on the Function App by infra/main.bicep).
 * No secrets live here: the database and Entra ID are reached with the app's managed identity.
 */

export interface Settings {
  sqlServer: string;
  sqlDatabase: string;
  feeTimeZone: string;
  tenantId: string;
  apiClientId: string;
}

export class ConfigurationError extends Error {
  override name = 'ConfigurationError';
}

let cached: Settings | undefined;

export function readSettings(env: Record<string, string | undefined> = process.env): Settings {
  if (cached && env === process.env) return cached;

  const missing: string[] = [];
  const required = (key: string): string => {
    const value = env[key]?.trim();
    if (!value) missing.push(key);
    return value ?? '';
  };

  const settings: Settings = {
    sqlServer: required('SQL_SERVER'),
    sqlDatabase: required('SQL_DATABASE'),
    feeTimeZone: env.FEE_TIMEZONE?.trim() || 'Asia/Kolkata',
    tenantId: required('ENTRA_TENANT_ID'),
    apiClientId: required('ENTRA_API_CLIENT_ID'),
  };
  if (missing.length > 0) throw new ConfigurationError(`Missing app settings: ${missing.join(', ')}.`);

  if (env === process.env) cached = settings;
  return settings;
}
