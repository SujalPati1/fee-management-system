// Builds the Function code and publishes it to Azure:
//   npm run deploy                       (defaults to func-feemgmt-k7x2pq)
//   npm run deploy -- <function-app-name>
//
// The package is assembled in a clean .deploy/ folder holding only what runs in Azure: host.json,
// package.json, the compiled JavaScript and production dependencies. Sources, tests, SQL, infra
// and any local files are never copied, so they cannot be uploaded.
import { execSync } from 'node:child_process';
import { cpSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const STAGING = join(ROOT, '.deploy');
const appName = process.argv[2] ?? 'func-feemgmt-k7x2pq';

// npm and func are .cmd shims on Windows, which only start through a shell, so each command is
// one fixed string. The only variable part is the app name, checked to be letters, digits and hyphens.
const run = (command, cwd) => execSync(command, { cwd, stdio: 'inherit' });

if (!/^[a-z0-9-]+$/i.test(appName)) throw new Error('Usage: npm run deploy -- <function-app-name>');

console.log('Building ...');
rmSync(join(ROOT, 'dist'), { recursive: true, force: true });
run('npm run build', ROOT);

console.log('Assembling .deploy/ ...');
rmSync(STAGING, { recursive: true, force: true });
mkdirSync(STAGING);
for (const file of ['host.json', 'package.json', 'package-lock.json']) cpSync(join(ROOT, file), join(STAGING, file));
cpSync(join(ROOT, 'dist', 'src'), join(STAGING, 'dist', 'src'), { recursive: true, filter: (source) => !source.endsWith('.map') });
// Core Tools needs to know the language. This holds no settings or secrets and is not uploaded.
writeFileSync(join(STAGING, 'local.settings.json'), JSON.stringify({ IsEncrypted: false, Values: { FUNCTIONS_WORKER_RUNTIME: 'node' } }));
writeFileSync(join(STAGING, '.funcignore'), 'local.settings.json\n');
run('npm ci --omit=dev --ignore-scripts --no-audit --no-fund', STAGING);

console.log(`Publishing to ${appName} ...`);
// --no-build: the package is complete, so Azure runs it as-is.
run(`func azure functionapp publish ${appName} --no-build`, STAGING);
