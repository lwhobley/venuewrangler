import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
// @ts-expect-error plain ESM script without type declarations
import { checkHeaderHashes, collectInlineScripts, headerScriptSrc, listHtml } from '../scripts/csp-hashes.mjs';

/**
 * The marketing/join site CSP must not allow arbitrary inline script (audit F-06). Instead each
 * inline <script> is allowed by hash, and these tests make drift between the pages and
 * site/_headers a CI failure instead of a silent production outage (or a silent re-opening).
 */
const headers = readFileSync('site/_headers', 'utf8');

describe('marketing site CSP', () => {
  it("does not allow 'unsafe-inline' scripts", () => {
    const { directive } = headerScriptSrc(headers);
    expect(directive.startsWith('script-src ')).toBe(true);
    expect(directive).not.toContain("'unsafe-inline'");
    expect(directive).not.toContain("'unsafe-eval'");
    expect(directive).toContain("'self'");
  });

  it('lists exactly the hashes of the inline scripts present in site/**/*.html', () => {
    const { missing, stale, unsafeInline } = checkHeaderHashes();
    expect(unsafeInline).toBe(false);
    expect({ missing, stale }).toEqual({ missing: [], stale: [] });
  });

  it('finds the known inline scripts, so the hash check is not vacuous', () => {
    const files = collectInlineScripts().map((s: { file: string }) => s.file).sort();
    expect(files).toContain('billing/index.html');
    expect(files).toContain('faq/index.html');
  });

  it('does not use inline event-handler attributes, which hashes cannot cover', () => {
    const pages: string[] = listHtml();
    expect(pages.length).toBeGreaterThan(3);
    for (const page of pages) {
      expect(readFileSync(page, 'utf8'), page).not.toMatch(/\son[a-z]+\s*=\s*["']/i);
    }
  });

  it('sets cross-origin isolation headers', () => {
    expect(headers).toMatch(/Cross-Origin-Opener-Policy:\s*same-origin-allow-popups/);
    expect(headers).toMatch(/Cross-Origin-Resource-Policy:\s*same-site/);
  });

  it('keeps framing, object and base protections', () => {
    const { csp } = headerScriptSrc(headers);
    for (const directive of ["object-src 'none'", "base-uri 'none'", "frame-ancestors 'none'", "default-src 'self'"]) {
      expect(csp).toContain(directive);
    }
  });
});
