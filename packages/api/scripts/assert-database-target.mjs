import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertAllowedHost, assertNotProduction, assertSameDatabaseTarget } from './database-target.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const API_DIR = resolve(HERE, '..');
const REPO_ROOT = resolve(API_DIR, '..', '..');

/**
 * Where the connection URL may come from, in the same precedence order
 * app.module.ts uses. The repository-root `.env.local` is deliberately absent:
 * it mirrors production, the API no longer loads it, and reading it here would
 * make the guard evaluate a URL the process is never going to connect to.
 */
const URL_ENV_FILES = [
  join(API_DIR, '.env.local'),
  join(API_DIR, '.env'),
  join(REPO_ROOT, '.env'),
];

/**
 * Where the guard's own settings may come from. This list DOES include the
 * root `.env.local`, because that file is the operator's mirror of the
 * production Cloud Run configuration and is the natural place to record which
 * database counts as production. Reading the fingerprint from there is safe in
 * a way that reading the URL from there is not: it can only ever cause a
 * refusal, never a connection.
 */
const SETTING_ENV_FILES = [
  join(API_DIR, '.env.local'),
  join(API_DIR, '.env'),
  join(REPO_ROOT, '.env.local'),
  join(REPO_ROOT, '.env'),
];

/** First value found for `key` across `files`, or undefined. */
function fromEnvFiles(key, files) {
  for (const file of files) {
    try {
      const line = readFileSync(file, 'utf8')
        .split(/\r?\n/)
        .find((candidate) => candidate.startsWith(`${key}=`));
      if (!line) continue;
      const value = line.slice(key.length + 1).trim().replace(/^"|"$/g, '');
      if (value) return value;
    } catch {
      // Missing or unreadable file — try the next candidate.
    }
  }
  return undefined;
}

const databaseUrl = process.env.DATABASE_URL ?? fromEnvFiles('DATABASE_URL', URL_ENV_FILES);
if (!databaseUrl) {
  throw new Error('DATABASE_URL is required for database commands.');
}

const directUrl = process.env.DATABASE_DIRECT_URL ?? fromEnvFiles('DATABASE_DIRECT_URL', URL_ENV_FILES);

// schema.prisma declares `directUrl = env("DATABASE_DIRECT_URL")`, and Prisma
// Migrate resolves it for every migrate/studio command. Serving instances
// deliberately do NOT carry that higher-privilege credential (see
// validate-env.ts), so only assert it for the commands that actually migrate —
// otherwise a missing value surfaces as an opaque Prisma P1012 from inside a
// Cloud Run job instead of a clear message here.
const MIGRATE_COMMANDS = new Set(['release', 'prisma:migrate:dev', 'prisma:migrate:deploy', 'prisma:migrate:status', 'prisma:studio']);
if (MIGRATE_COMMANDS.has(process.env.npm_lifecycle_event ?? '') && !directUrl) {
  throw new Error(
    'DATABASE_DIRECT_URL is required for migration commands. Prisma Migrate uses the direct ' +
      '(non-pooled) connection declared as `directUrl` in prisma/schema.prisma.',
  );
}
if (MIGRATE_COMMANDS.has(process.env.npm_lifecycle_event ?? '') && directUrl) {
  assertSameDatabaseTarget(databaseUrl, directUrl);
}

// Shell environment wins, so Cloud Run's configuration always overrides a file.
const guardEnv = {
  PRODUCTION_DB_FINGERPRINT:
    process.env.PRODUCTION_DB_FINGERPRINT ?? fromEnvFiles('PRODUCTION_DB_FINGERPRINT', SETTING_ENV_FILES),
  ALLOW_PRODUCTION_DB:
    process.env.ALLOW_PRODUCTION_DB ?? fromEnvFiles('ALLOW_PRODUCTION_DB', SETTING_ENV_FILES),
};

for (const [key, value] of [
  ['DATABASE_URL', databaseUrl],
  ['DATABASE_DIRECT_URL', directUrl],
]) {
  if (!value) continue;
  assertAllowedHost(key, value);
  assertNotProduction(key, value, guardEnv);
}
