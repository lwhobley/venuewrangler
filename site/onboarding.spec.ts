import { readFileSync } from 'fs';
import { join } from 'path';
import { describe, expect, it } from 'vitest';

const readSite = (path: string) => readFileSync(join(__dirname, path), 'utf8');

describe('website onboarding routes', () => {
  it('does not load the retired Create analytics script', () => {
    expect(readSite('index.html')).not.toContain('createcdn.com');
    expect(readSite('_headers')).not.toContain('createcdn.com');
  });

  it('routes every workspace entry point into the Flutter web app', () => {
    // Self-serve sign-up lives in the Flutter app (features/auth/sign_up_screen.dart),
    // which uses hash routing under /app/. The retired start/ page must not come back.
    expect(readSite('index.html')).toContain('href="app/#/sign-up"');
    expect(readSite('index.html')).not.toContain('href="start/"');
    expect(readSite('_redirects')).toMatch(/^\/start\/ \/app\/#\/sign-up 302$/m);
  });

  it('lets the Flutter web app reach Supabase without loosening script-src', () => {
    const worker = readSite('_worker.js');
    expect(worker).toContain("script-src 'self' 'wasm-unsafe-eval' https://browser.sentry-cdn.com;");
    expect(worker).toContain('connect-src \'self\' https://*.supabase.co wss://*.supabase.co');
    // Flutter's index.html relies on <base href="/app/">.
    expect(worker).toContain("base-uri 'self'");
    expect(worker).not.toContain("'unsafe-eval'");
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

  it('does not allow an unpinned third-party script host', () => {
    const headers = readSite('_headers');
    expect(headers).not.toContain('https://unpkg.com');
    for (const file of ['index.html', 'join/index.html', 'billing/index.html']) {
      const source = readSite(file);
      const externalScripts = [...source.matchAll(/<script\b[^>]*\bsrc=["']https?:\/\/[^>]*>/g)];
      for (const [tag] of externalScripts) {
        expect(tag).toMatch(/\bintegrity=["']sha384-/);
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
