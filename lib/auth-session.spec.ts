import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function source(relativePath: string): string {
  return readFileSync(join(process.cwd(), relativePath), 'utf8');
}

/**
 * E01 (production review): the reviewed web build reloaded itself after sign-in
 * until the API rate-limited it, and a refresh or a second tab ended the
 * session. Both causes are structural — which storage the persist middleware
 * gets, and which store action the /me refresh calls — so they are asserted
 * against the source rather than through a DOM harness the app does not have.
 */
describe('web session persistence and identity refresh', () => {
  const authStore = source('lib/auth-store.ts');
  const gate = source('components/SubscriptionGate.tsx');

  it('persists the web session instead of holding it only in memory', () => {
    expect(authStore).toContain('webSessionStorage');
    expect(authStore).toContain('window.sessionStorage');
    // memoryStorage survives as the fallback for a browser that refuses
    // storage access, not as the default path.
    expect(authStore).toMatch(/\? webSessionStorage\s*\n\s*: memoryStorage/);
  });

  it('guards every web storage accessor so blocked site data cannot crash startup', () => {
    const start = authStore.indexOf('const webSessionStorage');
    const block = authStore.slice(start, authStore.indexOf('};', start));
    // getItem, setItem and removeItem each have to tolerate a throwing
    // sessionStorage (Safari private mode, "block site data").
    expect((block.match(/try \{/g) ?? []).length).toBe(3);
  });

  it('refreshes profile detail without bumping the cache-scope epoch', () => {
    expect(authStore).toContain('syncProfile:');
    // The epoch only moves when the account or venue actually changes.
    expect(authStore).toContain('const scopeChanged =');
    expect(authStore).toMatch(/scopeChanged \? \{ authEpoch: state\.authEpoch \+ 1 \} : \{\}/);
  });

  it('does not bump the cache-scope epoch when setVenue receives the same venue', () => {
    // E02: auth-readiness calls setVenue on every getMe response with a freshly
    // built venue object (venueFromApi always returns a new reference), so an
    // unconditional epoch bump here reran that same query, produced another new
    // venue object, and bumped again -- the same reload loop as E01, through a
    // different store action.
    const start = authStore.lastIndexOf('setVenue:');
    const block = authStore.slice(start, authStore.indexOf('setVenues:', start));
    expect(block).toMatch(/state\.venue\?\.id !== venue\.id \? \{ authEpoch: state\.authEpoch \+ 1 \} : \{\}/);
  });

  it('routes the /me identity refresh through syncProfile, not setSession', () => {
    expect(gate).toContain('syncProfile({');
    expect(gate).not.toContain('setSession({');
  });

  it('compares the normalized values it would write, so the refresh settles', () => {
    expect(gate).toContain("const nextJobTitle = p.jobTitle ?? '';");
    expect(gate).toContain('user.job_title === nextJobTitle');
  });
});
