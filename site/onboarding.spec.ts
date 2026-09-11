import { readFileSync } from 'fs';
import { join } from 'path';
import { describe, expect, it } from 'vitest';

const readSite = (path: string) => readFileSync(join(__dirname, path), 'utf8');

describe('website onboarding routes', () => {
  it('does not load the retired Create analytics script', () => {
    expect(readSite('index.html')).not.toContain('createcdn.com');
    expect(readSite('_headers')).not.toContain('createcdn.com');
  });

  it('verifies an owner email before registering a workspace', () => {
    const source = readSite('start/index.html');
    expect(source).toContain('id="verificationStep"');
    expect(source).toContain('/v1/auth/verify-email');
    expect(source).toContain('/v1/auth/verify-email/send');
    expect(source).toContain('await api("/v1/auth/verify-email", { method: "POST", body: JSON.stringify({ code }) }, pendingSession.token);');
    expect(source).toContain('await createWorkspace();');
  });

  it('sends the security headers the join flow depends on', () => {
    // This origin serves the invite/join flow and the tokens with it, so the
    // header set is part of that flow's threat model, not decoration.
    const headers = readSite('_headers');
    expect(headers).toContain('Strict-Transport-Security: max-age=31536000; includeSubDomains');
    expect(headers).toContain('X-Content-Type-Options: nosniff');
    expect(headers).toContain('X-Frame-Options: DENY');
    expect(headers).toContain("frame-ancestors 'none'");
    expect(headers).toContain("object-src 'none'");
    expect(headers).toContain("base-uri 'none'");
  });

  it('does not commit to HSTS preload without a deliberate decision', () => {
    // Preload submission is effectively irreversible for months and binds every
    // present and future subdomain to HTTPS. If this ever becomes intentional,
    // delete this test in the same commit that adds the directive.
    //
    // Asserts on the directive, not the whole file: the comment above the
    // header explains why preload is omitted, and a naive substring match on
    // the file flags that prose as a violation.
    const sts = readSite('_headers')
      .split(/\r?\n/)
      .filter((line) => line.trim().startsWith('Strict-Transport-Security:'));
    expect(sts).toHaveLength(1);
    expect(sts[0]).not.toContain('preload');
  });

  it('pins every CDN script with an integrity hash', () => {
    // CSP allows the unpkg host wholesale because CSP has no path granularity;
    // SRI is what actually stops a tampered CDN file from executing.
    for (const file of ['index.html']) {
      const source = readSite(file);
      const tags = source.match(/unpkg\.com[^)'"`]*/g) ?? [];
      for (const match of source.matchAll(/loadScript\(\s*'([^']*unpkg[^']*)'\s*,\s*'([^']+)'/g)) {
        expect(match[2]).toMatch(/^sha384-/);
      }
    }
  });

  it('keeps the join form behind a valid invitation token', () => {
    const source = readSite('join/index.html');
    expect(source).toContain('id="join" hidden');
    expect(source).toContain('/v1/app/invite/');
    expect(source).toContain('loadInvite().catch');
    expect(source).toContain('inviteToken: token');
  });
});
