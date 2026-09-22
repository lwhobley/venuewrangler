/**
 * Pure guards for which database a command is allowed to touch.
 *
 * Kept separate from assert-database-target.mjs because that script asserts at
 * import time — importing it from a test would trip the very check under test.
 */

/**
 * The production database and every dev branch share the `.supabase.co`
 * suffix, so a vendor check alone cannot tell them apart — it blocks the case
 * nobody was going to hit and permits the one that matters. `.env.local` is a
 * deliberate mirror of the production Cloud Run configuration, so an ordinary
 * `npm run api:dev` (or a stray `prisma migrate dev`) could point a developer's
 * machine at real customer data.
 *
 * Mirrors the triple opt-in the integration-test path already requires of
 * TEST_DATABASE_URL / ALLOW_REMOTE_TEST_DB_RESET / TEST_DATABASE_FINGERPRINT.
 * Set PRODUCTION_DB_FINGERPRINT to "host/database"; the Cloud Run migration job
 * sets ALLOW_PRODUCTION_DB=true so the intended path stays unblocked.
 */
export function assertNotProduction(key, value, env = process.env) {
  const fingerprint = env.PRODUCTION_DB_FINGERPRINT?.trim();
  if (!fingerprint) return;
  const url = new URL(value);
  const target = `${url.hostname.toLowerCase()}${url.pathname}`;
  if (target !== fingerprint.trim().toLowerCase()) return;
  if (env.ALLOW_PRODUCTION_DB === 'true') return;
  throw new Error(
    `Refusing database command: ${key} targets the production database (${target}). ` +
      'Set ALLOW_PRODUCTION_DB=true only for a deliberate production operation.',
  );
}

/** Reject anything that is neither Supabase nor a local Postgres. */
export function assertAllowedHost(key, value) {
  const hostname = new URL(value).hostname.toLowerCase();
  const isLocal = hostname === 'localhost' || hostname === '127.0.0.1';
  const isSupabase = hostname.endsWith('.supabase.co') || hostname.endsWith('.supabase.com');

  if (!isLocal && !isSupabase) {
    throw new Error(`Refusing database command: ${key} targets ${hostname}; expected Supabase or local Postgres.`);
  }
}

/** Pooler and direct credentials must address the same project/database/schema. */
export function databaseIdentity(value) {
  const url = new URL(value);
  const hostname = url.hostname.toLowerCase();
  const directProject = /^db\.([^.]+)\.supabase\.co$/.exec(hostname)?.[1];
  let project = directProject ?? hostname;
  if (hostname.endsWith('.pooler.supabase.com')) {
    const username = decodeURIComponent(url.username);
    if (!username.includes('.')) throw new Error('Supabase pooler credentials must identify their project in the username.');
    project = username.slice(username.lastIndexOf('.') + 1);
  } else if (hostname === 'localhost' || hostname === '127.0.0.1') {
    project = `loopback:${url.port || '5432'}`;
  }
  return JSON.stringify([project, decodeURIComponent(url.pathname), url.searchParams.get('schema') ?? 'public']);
}

export function assertSameDatabaseTarget(databaseUrl, directUrl) {
  if (databaseIdentity(databaseUrl) !== databaseIdentity(directUrl)) {
    throw new Error('DATABASE_URL and DATABASE_DIRECT_URL target different projects, databases, or schemas. Refusing migrations.');
  }
}
