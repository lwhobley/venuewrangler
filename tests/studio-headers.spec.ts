import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const worker = new Function(`return (${readFileSync('site/_worker.js', 'utf8').replace('export default', '').replace(/;\s*$/, '')});`)() as {
  fetch(request: Request, env: { ASSETS: { fetch(request: Request): Promise<Response> } }): Promise<Response>;
};
const env = { ASSETS: { async fetch() {
  return new Response('<html></html>', { headers: {
    'Content-Security-Policy': "default-src 'self'; frame-ancestors 'none'",
    'X-Frame-Options': 'DENY',
  } });
} } };

describe('3D scene embedding policy', () => {
  it('permits only same-origin framing of the actual scene asset', async () => {
    const response = await worker.fetch(new Request('https://example.test/app/assets/assets/three/scene.html?frame=1'), env);
    expect(response.headers.get('X-Frame-Options')).toBe('SAMEORIGIN');
    expect(response.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'self'");
    expect(response.headers.get('Content-Security-Policy')).toContain("script-src 'self' 'unsafe-inline'");
  });
  it('keeps anti-framing protection on other assets and the app shell', async () => {
    for (const path of ['/app/', '/app/assets/other.html', '/app/assets/assets/three/scene-other']) {
      const response = await worker.fetch(new Request(`https://example.test${path}`), env);
      expect(response.headers.get('X-Frame-Options')).toBe('DENY');
      expect(response.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'none'");
    }
  });
  it('preserves the scene policy after Pages canonicalizes the HTML URL', async () => {
    const pages = { ASSETS: { async fetch(request: Request) {
      if (new URL(request.url).pathname.endsWith('.html')) {
        return new Response(null, { status: 308, headers: { Location: '/app/assets/assets/three/scene' } });
      }
      return env.ASSETS.fetch();
    } } };
    const original = new Request('https://example.test/app/assets/assets/three/scene.html');
    const redirect = await worker.fetch(original, pages);
    expect(redirect.status).toBe(308);
    const response = await worker.fetch(new Request(new URL(redirect.headers.get('Location')!, original.url)), pages);
    expect(response.status).toBe(200);
    expect(response.headers.get('X-Frame-Options')).toBe('SAMEORIGIN');
    expect(response.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'self'");
  });
  it('pins the app CSP to the production Supabase project host instead of every *.supabase.co', async () => {
    const response = await worker.fetch(new Request('https://example.test/app/'), env);
    const csp = response.headers.get('Content-Security-Policy')!;
    const host = 'puttwjwmwrzmhpsjykuj.supabase.co';
    expect(csp).not.toContain('*.supabase.co');
    expect(csp).toContain(`connect-src 'self' https://${host} wss://${host}`);
    expect(csp).toContain(`img-src 'self' data: blob: https://${host}`);
    expect(csp).toContain(`media-src 'self' blob: https://${host}`);
    expect(csp).not.toMatch(/script-src[^;]*'unsafe-inline'/);
    expect(response.headers.get('Cross-Origin-Opener-Policy')).toBe('same-origin-allow-popups');
    expect(response.headers.get('Cross-Origin-Resource-Policy')).toBe('same-site');
  });
});
