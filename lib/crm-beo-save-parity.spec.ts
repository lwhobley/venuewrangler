import { readFileSync } from 'fs';
import { join } from 'path';
import { describe, expect, it } from 'vitest';

/**
 * POST /v1/crm/beos rewrites every BEO column from the request body — it builds
 * one `fields` object where each column falls back to null — so a caller that
 * saves a BEO partially does not leave the omitted columns alone, it clears
 * them.
 *
 * The "Confirm BEO" button only wants to move the status, but it has to go
 * through that endpoint, so it resends the whole record. When it did not,
 * confirming a BEO permanently unlinked it from its lead, and the reservation
 * created moments later by syncBeoToReservation had no guest name, phone,
 * email or guest id.
 *
 * This asserts the two stay in step: every column saveBeo writes is a key
 * confirmBeo sends. It fails on a new column added to the API alone.
 */
const repoRoot = join(__dirname, '..');

function apiFieldKeys() {
  const source = readFileSync(join(repoRoot, 'packages/api/src/modules/crm/crm.controller.ts'), 'utf8');
  const start = source.indexOf('    const fields = {');
  expect(start, 'saveBeo `fields` object not found — update this guard').toBeGreaterThan(-1);
  const body = source.slice(start, source.indexOf('\n    };', start));
  return [...body.matchAll(/^\s{6}(\w+):/gm)].map((m) => m[1]);
}

function confirmBeoKeys() {
  const source = readFileSync(join(repoRoot, 'components/CrmSalesWorkspace.tsx'), 'utf8');
  const start = source.indexOf('  const confirmBeo =');
  expect(start, 'confirmBeo not found — update this guard').toBeGreaterThan(-1);
  const callStart = source.indexOf('await saveBeo({', start);
  const body = source.slice(callStart, source.indexOf('\n      });', callStart));
  return [...body.matchAll(/^\s{8}(\w+):/gm)].map((m) => m[1]);
}

describe('Confirm BEO resends every column saveBeo rewrites', () => {
  it('sends each field the API would otherwise null', () => {
    // updatedAt is stamped server-side; status is what confirming changes.
    const serverManaged = new Set(['updatedAt']);
    const required = apiFieldKeys().filter((key) => !serverManaged.has(key));
    const sent = new Set(confirmBeoKeys());

    expect(required.length).toBeGreaterThan(10);
    expect(required.filter((key) => !sent.has(key))).toEqual([]);
  });

  it('sends the status it is setting', () => {
    expect(confirmBeoKeys()).toContain('status');
  });
});
